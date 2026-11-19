const { json, sb, paystack, parseBody } = require('./_paystack-common');
const { notifyStoreOrder } = require('./_whatsapp-notify');
const { notifyStoreOrderEmail } = require('./_brevo-email');
const { logServerError } = require('./_monitoring');
const normal = value => String(value || '').trim().toLowerCase().replace(/\s+/g, ' ');
exports.handler = async event => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Use POST.' });
  try {
    const body = parseBody(event);
    const slug = String(body.slug || '').trim().toLowerCase();
    const name = String(body.customer_name || '').trim();
    const phone = String(body.customer_phone || '').trim();
    const email = String(body.customer_email || '').trim().toLowerCase();
    const address = String(body.delivery_address || '').trim();
    const note = String(body.customer_note || '').trim();
    const items = Array.isArray(body.items) ? body.items : [];
    const key = String(body.idempotency_key || '').trim();
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) return json(400, { error: 'Invalid shop link.' });
    if (name.length < 2 || phone.replace(/\D/g, '').length < 7 || address.length < 5 || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json(400, { error: 'Enter your name, valid phone number, email address and delivery address.' });
    if (!items.length || items.length > 30 || key.length < 16 || key.length > 120) return json(400, { error: 'Your cart or checkout session is invalid. Refresh and try again.' });

    const businesses = await sb(`businesses?shop_slug=eq.${encodeURIComponent(slug)}&store_enabled=eq.true&select=id,owner_id,plan,trial_ends,name,shop_name,store_bank_code,store_bank_name,store_account_number,store_account_name,paystack_subaccount_code,paystack_subaccount_bank_code_snapshot,paystack_subaccount_account_snapshot,paystack_subaccount_commission_snapshot&limit=1`);
    const business = businesses && businesses[0];
    if (!business) return json(404, { error: 'This shop is unavailable.' });

    // Checkout is server-gated even while expired stores remain publicly browsable.
    const platformOwnerId = '327738f9-ad95-4b8e-89c7-6a4847fa1a63';
    const ownerExempt = String(business.owner_id || '').toLowerCase() === platformOwnerId;
    const trialActive = String(business.plan || 'free').toLowerCase() === 'free'
      && business.trial_ends && new Date(business.trial_ends).getTime() > Date.now();
    let paidSubscriptionActive = false;
    if (!ownerExempt && !trialActive) {
      const subs = await sb(`subscriptions?business_id=eq.${encodeURIComponent(business.id)}&status=eq.active&ends_at=gt.${encodeURIComponent(new Date().toISOString())}&select=id&limit=1`);
      paidSubscriptionActive = Array.isArray(subs) && subs.length > 0;
    }
    if (!ownerExempt && !trialActive && !paidSubscriptionActive) {
      return json(403, { error: 'This store is currently in browse-only mode because its trial or subscription has expired. The store owner must upgrade to accept new orders.' });
    }

    const bankCode = String(business.store_bank_code || '').trim();
    const accountNumber = String(business.store_account_number || '').replace(/\D/g, '');
    const accountName = String(business.store_account_name || '').trim();
    if (!bankCode || !/^\d{10}$/.test(accountNumber) || !accountName) return json(409, { error: 'This seller has not completed bank verification for Paystack payments yet. Choose bank transfer or contact the store owner.' });

    const settings = await sb('platform_payment_settings?id=eq.1&select=commission_percent&limit=1');
    const commissionRate = Number(settings?.[0]?.commission_percent ?? 5);
    if (!(commissionRate >= 0 && commissionRate <= 30)) throw new Error('Platform commission setting is invalid.');

    // Re-resolve the seller's account immediately before enabling settlement.
    const resolved = await paystack(`/bank/resolve?account_number=${encodeURIComponent(accountNumber)}&bank_code=${encodeURIComponent(bankCode)}`, { method: 'GET' });
    if (String(resolved.account_number || '').replace(/\D/g, '') !== accountNumber || normal(resolved.account_name) !== normal(accountName)) {
      return json(409, { error: 'The seller bank details no longer match Paystack verification. Ask the seller to verify and save the bank account again.' });
    }

    let subaccountCode = String(business.paystack_subaccount_code || '').trim();
    const snapshotMatches = subaccountCode && business.paystack_subaccount_bank_code_snapshot === bankCode && String(business.paystack_subaccount_account_snapshot || '') === accountNumber && Number(business.paystack_subaccount_commission_snapshot) === commissionRate;
    if (!snapshotMatches) {
      const sub = await paystack('/subaccount', {
        method: 'POST',
        body: JSON.stringify({
          business_name: String(business.shop_name || business.name || 'OrderDesk NG Seller').slice(0, 100),
          bank_code: bankCode,
          account_number: accountNumber,
          percentage_charge: commissionRate,
          description: `OrderDesk NG seller settlement for ${slug}`
        })
      });
      subaccountCode = String(sub.subaccount_code || '').trim();
      if (!/^ACCT_/.test(subaccountCode)) throw new Error('Paystack did not return a valid seller settlement account.');
      await sb(`businesses?id=eq.${encodeURIComponent(business.id)}`, {
        method: 'PATCH', headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({ paystack_subaccount_code: subaccountCode, paystack_subaccount_bank_code_snapshot: bankCode, paystack_subaccount_account_snapshot: accountNumber, paystack_subaccount_commission_snapshot: commissionRate })
      });
    }

    const orderResult = await sb('rpc/place_store_order_catalog', {
      method: 'POST',
      body: JSON.stringify({ p_slug: slug, p_customer_name: name, p_customer_phone: phone, p_customer_email: email, p_delivery_address: address, p_customer_note: note || null, p_payment_method: 'Paystack', p_items: items, p_idempotency_key: key, p_delivery_zone_id: body.delivery_zone_id || null })
    });
    if (!orderResult || !orderResult.order_id || !orderResult.order_ref) throw new Error('Order could not be created. Please retry.');
    if (!(Number(orderResult.total) > 0)) throw new Error('This order total is not valid for online payment. Choose another payment method or contact the store.');
    if (orderResult.paystack_authorization_url && orderResult.paystack_reference) {
      return json(200, { authorization_url: orderResult.paystack_authorization_url, reference: orderResult.paystack_reference, order_ref: orderResult.order_ref, total: orderResult.total });
    }

    const reference = `ODNG_${orderResult.order_id.replace(/-/g, '').slice(0, 18)}_${Date.now()}`;
    const callbackUrl = `https://orderdeskng.netlify.app/shop/${encodeURIComponent(slug)}?paystack_return=1`;
    const tx = await paystack('/transaction/initialize', {
      method: 'POST',
      body: JSON.stringify({
        email,
        amount: Math.round(Number(orderResult.total) * 100),
        currency: 'NGN',
        reference,
        callback_url: callbackUrl,
        subaccount: subaccountCode,
        transaction_charge: Math.round(Number(orderResult.subtotal) * commissionRate),
        bearer: 'subaccount',
        metadata: { order_id: orderResult.order_id, order_ref: orderResult.order_ref, business_id: business.id, commission_rate: commissionRate, custom_fields: [{ display_name: 'Order reference', variable_name: 'order_ref', value: orderResult.order_ref }] }
      })
    });
    if (!tx.authorization_url || !tx.reference) throw new Error('Paystack did not return a checkout link.');
    const base = Number(orderResult.subtotal);
    const commission = Math.round(base * commissionRate) / 100;
    await sb(`store_orders?id=eq.${encodeURIComponent(orderResult.order_id)}`, {
      method: 'PATCH', headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ paystack_reference: tx.reference, paystack_authorization_url: tx.authorization_url, paystack_subaccount_code: subaccountCode, platform_commission_rate: commissionRate, platform_commission_amount: commission })
    });
    try { await notifyStoreOrder(orderResult.order_id, 'new_order'); } catch (notifyError) { console.warn('OrderDesk merchant WhatsApp alert was not sent:', notifyError.message); }
    try { await notifyStoreOrderEmail(orderResult.order_id, 'new_order'); } catch (notifyError) { console.warn('OrderDesk new-order email was not sent:', notifyError.message); }
    return json(200, { authorization_url: tx.authorization_url, reference: tx.reference, order_ref: orderResult.order_ref, total: orderResult.total });
  } catch (error) {
    if (!error.status || Number(error.status) >= 500) await logServerError('initialize-paystack-store-order', error);
    const status = Number(error.status) >= 400 && Number(error.status) < 600 ? Number(error.status) : 500;
    return json(status, { error: error.message || 'Unable to start Paystack checkout.' });
  }
};
