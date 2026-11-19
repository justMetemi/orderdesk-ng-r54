const SB_URL = String(process.env.SUPABASE_URL || 'https://gmuzqcuovlsacsgjxlts.supabase.co').replace(/\/$/, '');
const SB_SERVICE = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const BREVO_KEY = String(process.env.BREVO_API_KEY || '').trim();
const SENDER_EMAIL = String(process.env.BREVO_SENDER_EMAIL || '').trim();
const SENDER_NAME = String(process.env.BREVO_SENDER_NAME || 'OrderDesk NG').trim();

async function db(path, options = {}) {
  if (!SB_SERVICE) throw new Error('Missing SUPABASE_SERVICE_ROLE_KEY.');
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { ...options, headers: { apikey: SB_SERVICE, Authorization: `Bearer ${SB_SERVICE}`, 'Content-Type': 'application/json', ...(options.headers || {}) } });
  const body = await r.text(); let data = null; try { data = body ? JSON.parse(body) : null; } catch (_) { data = body; }
  if (!r.ok) throw new Error(data?.message || `Supabase request failed (${r.status}).`);
  return data;
}
const esc = value => String(value == null ? '' : value).replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
const validEmail = value => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(value || '').trim());
const money = value => 'NGN ' + Number(value || 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

async function sendEmail(to, subject, textContent, htmlContent) {
  if (!BREVO_KEY || !SENDER_EMAIL) return { sent: false, skipped: true, reason: 'Brevo email is not configured.' };
  if (!validEmail(to)) return { sent: false, skipped: true, reason: 'Recipient email is missing or invalid.' };
  const response = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': BREVO_KEY, 'Content-Type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({ sender: { email: SENDER_EMAIL, name: SENDER_NAME }, to: [{ email: String(to).trim() }], subject, textContent, htmlContent })
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.message || `Brevo email request failed (${response.status}).`);
  return { sent: true, message_id: result.messageId || null };
}

async function sendLoggedEmail(order, business, eventType, recipientType, recipient) {
  if (!validEmail(recipient)) return { sent: false, skipped: true, reason: 'Recipient email is missing or invalid.' };
  const prior = await db(`store_order_email_logs?store_order_id=eq.${encodeURIComponent(order.id)}&event_type=eq.${encodeURIComponent(eventType)}&recipient_type=eq.${encodeURIComponent(recipientType)}&status=eq.sent&select=id&limit=1`);
  if (prior?.length) return { sent: true, already_sent: true };
  const shop = business.shop_name || business.name || 'Your store';
  const amount = money(order.total);
  const subjects = {
    new_order: recipientType === 'merchant' ? `New online order ${order.order_ref}` : `Order received — ${order.order_ref}`,
    receipt_submitted: `Transfer receipt submitted — ${order.order_ref}`,
    payment_success: recipientType === 'merchant' ? `Payment confirmed — ${order.order_ref}` : `Payment confirmed for order ${order.order_ref}`
  };
  let heading, detail;
  if (eventType === 'new_order') {
    heading = recipientType === 'merchant' ? 'You have a new online order' : 'We have received your order';
    detail = recipientType === 'merchant' ? 'A customer has placed an order in your online store.' : `Your order with ${shop} has been received. Keep this reference for tracking.`;
  } else if (eventType === 'receipt_submitted') {
    heading = 'A bank-transfer receipt was submitted';
    detail = 'The customer uploaded a transfer receipt. Please check your bank account independently before confirming payment.';
  } else {
    heading = 'Payment confirmed';
    detail = recipientType === 'merchant' ? 'The order payment has been marked as confirmed in OrderDesk NG.' : `Your payment for the order with ${shop} has been confirmed.`;
  }
  const lines = [heading, '', `Store: ${shop}`, `Order reference: ${order.order_ref}`, `Customer: ${order.customer_name || 'Customer'}`, `Total: ${amount}`, `Payment status: ${order.payment_status || 'Pending'}`, '', detail, '', 'OrderDesk NG'];
  const html = `<div style="font-family:Arial,sans-serif;max-width:600px;margin:auto;color:#17211b"><div style="background:#0d5b37;color:#fff;padding:20px 24px;border-radius:12px 12px 0 0"><strong style="font-size:20px">OrderDesk NG</strong></div><div style="padding:24px;border:1px solid #e1e9e4;border-top:0;border-radius:0 0 12px 12px"><h2 style="margin:0 0 12px">${esc(heading)}</h2><p>${esc(detail)}</p><div style="background:#f3f8f5;padding:16px;border-radius:10px"><p><b>Store:</b> ${esc(shop)}</p><p><b>Order reference:</b> ${esc(order.order_ref)}</p><p><b>Customer:</b> ${esc(order.customer_name || 'Customer')}</p><p><b>Total:</b> ${esc(amount)}</p><p><b>Payment status:</b> ${esc(order.payment_status || 'Pending')}</p></div>${eventType === 'receipt_submitted' ? '<p style="color:#9a4b00"><b>Important:</b> A receipt upload is not proof that funds have arrived. Verify your bank account before confirming payment.</p>' : ''}<p style="color:#68756d;font-size:12px;margin-top:24px">This is an automated OrderDesk NG notification.</p></div></div>`;
  const result = await sendEmail(recipient, subjects[eventType], lines.join('\n'), html);
  if (!result.sent) return result;
  await db('store_order_email_logs', { method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' }, body: JSON.stringify({ store_order_id: order.id, event_type: eventType, recipient_type: recipientType, recipient_email: String(recipient).trim(), status: 'sent', provider_message_id: result.message_id }) });
  return result;
}

async function notifyStoreOrderEmail(orderId, eventType) {
  if (!['new_order', 'payment_success', 'receipt_submitted'].includes(eventType)) throw new Error('Unsupported email notification event.');
  if (!BREVO_KEY || !SENDER_EMAIL) return { skipped: true, reason: 'Brevo email is not configured.' };
  const orders = await db(`store_orders?id=eq.${encodeURIComponent(orderId)}&select=id,business_id,order_ref,customer_name,customer_email,total,payment_status,payment_method,status&limit=1`);
  const order = orders?.[0]; if (!order) throw new Error('Order not found.');
  const businesses = await db(`businesses?id=eq.${encodeURIComponent(order.business_id)}&select=name,shop_name,email&limit=1`);
  const business = businesses?.[0] || {};
  const results = {};
  if (validEmail(business.email)) results.merchant = await sendLoggedEmail(order, business, eventType, 'merchant', business.email);
  if (eventType !== 'receipt_submitted' && validEmail(order.customer_email)) results.customer = await sendLoggedEmail(order, business, eventType, 'customer', order.customer_email);
  return { results };
}

module.exports = { sendEmail, notifyStoreOrderEmail };
