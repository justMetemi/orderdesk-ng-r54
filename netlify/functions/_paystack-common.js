const crypto = require('crypto');
const SB_URL = String(process.env.SUPABASE_URL || 'https://gmuzqcuovlsacsgjxlts.supabase.co').replace(/\/$/, '');
const SB_SERVICE = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const PAYSTACK_SECRET = String(process.env.PAYSTACK_SECRET_KEY || '').trim();
const json = (statusCode, body) => ({
  statusCode,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  body: JSON.stringify(body)
});
function requireSecrets() {
  if (!SB_SERVICE) throw new Error('Missing SUPABASE_SERVICE_ROLE_KEY in Netlify environment variables.');
  if (!PAYSTACK_SECRET) throw new Error('Missing PAYSTACK_SECRET_KEY in Netlify environment variables.');
}
async function sb(path, options = {}) {
  requireSecrets();
  const response = await fetch(`${SB_URL}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: SB_SERVICE,
      Authorization: `Bearer ${SB_SERVICE}`,
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  });
  const raw = await response.text();
  let data = null;
  try { data = raw ? JSON.parse(raw) : null; } catch (_) { data = raw; }
  if (!response.ok) {
    const message = data && (data.message || data.error_description || data.hint) || `Supabase request failed (${response.status}).`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return data;
}
async function paystack(path, options = {}) {
  requireSecrets();
  const response = await fetch(`https://api.paystack.co${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${PAYSTACK_SECRET}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.status === false) {
    const error = new Error(data.message || `Paystack request failed (${response.status}).`);
    error.status = response.status;
    throw error;
  }
  return data.data;
}
function parseBody(event) {
  try { return JSON.parse(event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '{}')); }
  catch (_) { throw new Error('Invalid JSON request.'); }
}
function safeEqualHex(a, b) {
  try {
    const aa = Buffer.from(String(a || ''), 'hex');
    const bb = Buffer.from(String(b || ''), 'hex');
    return aa.length === bb.length && aa.length > 0 && crypto.timingSafeEqual(aa, bb);
  } catch (_) { return false; }
}
async function verifyAndSettle(reference) {
  if (!reference || typeof reference !== 'string' || reference.length > 120) throw new Error('Invalid payment reference.');
  const rows = await sb(`store_orders?paystack_reference=eq.${encodeURIComponent(reference)}&select=id,business_id,order_ref,customer_name,customer_phone,total,subtotal,delivery_fee,payment_method,payment_status,status,paystack_subaccount_code,platform_commission_rate&limit=1`);
  const order = rows && rows[0];
  if (!order || order.payment_method !== 'Paystack') throw new Error('Order/payment reference not found.');
  const tx = await paystack(`/transaction/verify/${encodeURIComponent(reference)}`, { method: 'GET' });
  const meta = tx.metadata || {};
  const metaOrderId = String(meta.order_id || meta.orderId || '');
  const expectedKobo = Math.round(Number(order.total) * 100);
  if (String(tx.reference || '') !== reference || tx.status !== 'success' || String(tx.currency || '').toUpperCase() !== 'NGN' || Number(tx.amount) !== expectedKobo || metaOrderId !== order.id) {
    throw new Error('Paystack has not confirmed the exact amount for this order.');
  }
  if (!order.paystack_subaccount_code || !tx.subaccount || tx.subaccount.subaccount_code !== order.paystack_subaccount_code) {
    throw new Error('Payment settlement account does not match this order.');
  }
  const paidAt = tx.paid_at || new Date().toISOString();
  await sb(`store_orders?id=eq.${encodeURIComponent(order.id)}&payment_method=eq.Paystack`, {
    method: 'PATCH',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ payment_status: 'Confirmed', status: order.status === 'Pending' ? 'Confirmed' : order.status, paystack_paid_at: paidAt })
  });
  const rate = Number(order.platform_commission_rate || 5);
  const base = Number(order.subtotal);
  const commission = Math.round(base * rate) / 100;
  await sb('platform_commissions?on_conflict=store_order_id', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({ store_order_id: order.id, business_id: order.business_id, commission_rate: rate, commission_base: base, commission_amount: commission, collection_method: 'Paystack split', collection_status: 'Collected', paystack_reference: reference })
  });
  try { const { notifyStoreOrder } = require('./_whatsapp-notify'); await notifyStoreOrder(order.id, 'payment_success'); } catch (notifyError) { console.warn('OrderDesk payment WhatsApp alert was not sent:', notifyError.message); }
  try { const { notifyStoreOrderEmail } = require('./_brevo-email'); await notifyStoreOrderEmail(order.id, 'payment_success'); } catch (notifyError) { console.warn('OrderDesk payment email was not sent:', notifyError.message); }
  return { order_ref: order.order_ref, order_id: order.id, customer_name: order.customer_name, customer_phone: order.customer_phone, total: Number(order.total), payment_method: 'Paystack', payment_status: 'Confirmed', status: order.status === 'Pending' ? 'Confirmed' : order.status };
}
module.exports = { SB_URL, SB_SERVICE, PAYSTACK_SECRET, json, sb, paystack, parseBody, safeEqualHex, verifyAndSettle };
