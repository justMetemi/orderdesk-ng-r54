const SB_URL = String(process.env.SUPABASE_URL || 'https://gmuzqcuovlsacsgjxlts.supabase.co').replace(/\/$/, '');
const SB_SERVICE = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const WA_TOKEN = String(process.env.WHATSAPP_ACCESS_TOKEN || '').trim();
const WA_PHONE_ID = String(process.env.WHATSAPP_PHONE_NUMBER_ID || '').trim();
const GRAPH_VERSION = String(process.env.WHATSAPP_GRAPH_VERSION || 'v22.0').trim();

async function db(path, options = {}) {
  if (!SB_SERVICE) throw new Error('Missing SUPABASE_SERVICE_ROLE_KEY.');
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { ...options, headers: { apikey: SB_SERVICE, Authorization: `Bearer ${SB_SERVICE}`, 'Content-Type': 'application/json', ...(options.headers || {}) } });
  const body = await r.text(); let data = null; try { data = body ? JSON.parse(body) : null; } catch (_) { data = body; }
  if (!r.ok) throw new Error(data?.message || `Supabase request failed (${r.status}).`);
  return data;
}
function normalisePhone(v) { let p = String(v || '').replace(/\D/g, ''); if (p.startsWith('0')) p = '234' + p.slice(1); if (p.startsWith('234')) return p; return p; }
async function notifyStoreOrder(orderId, eventType) {
  if (!['new_order', 'payment_success', 'receipt_submitted'].includes(eventType)) throw new Error('Unsupported notification event.');
  if (!WA_TOKEN || !WA_PHONE_ID) return { sent: false, skipped: true, reason: 'WhatsApp Cloud API is not configured.' };
  const orders = await db(`store_orders?id=eq.${encodeURIComponent(orderId)}&select=id,business_id,order_ref,customer_name,total,payment_status,payment_method,status&limit=1`);
  const order = orders?.[0]; if (!order) throw new Error('Order not found.');
  const businesses = await db(`businesses?id=eq.${encodeURIComponent(order.business_id)}&select=name,shop_name,store_notification_whatsapp&limit=1`);
  const business = businesses?.[0]; const recipient = normalisePhone(business?.store_notification_whatsapp);
  if (!recipient || recipient.length < 10) return { sent: false, skipped: true, reason: 'Merchant alert WhatsApp number is not configured.' };
  const prior = await db(`store_order_notification_logs?store_order_id=eq.${encodeURIComponent(order.id)}&event_type=eq.${encodeURIComponent(eventType)}&status=eq.sent&select=id&limit=1`);
  if (prior?.length) return { sent: true, already_sent: true };
  const templates = {
    new_order: String(process.env.WHATSAPP_NEW_ORDER_TEMPLATE || 'orderdesk_new_order').trim(),
    payment_success: String(process.env.WHATSAPP_PAYMENT_SUCCESS_TEMPLATE || 'orderdesk_payment_success').trim(),
    receipt_submitted: String(process.env.WHATSAPP_RECEIPT_SUBMITTED_TEMPLATE || 'orderdesk_receipt_submitted').trim()
  };
  const language = String(process.env.WHATSAPP_TEMPLATE_LANGUAGE || 'en_US').trim();
  const amount = 'NGN ' + Number(order.total || 0).toLocaleString('en-NG', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const params = [business.shop_name || business.name || 'Your store', order.order_ref, order.customer_name, amount, order.payment_status];
  const payload = { messaging_product: 'whatsapp', recipient_type: 'individual', to: recipient, type: 'template', template: { name: templates[eventType], language: { code: language }, components: [{ type: 'body', parameters: params.map(text => ({ type: 'text', text: String(text || '-') })) }] } };
  const response = await fetch(`https://graph.facebook.com/${GRAPH_VERSION}/${encodeURIComponent(WA_PHONE_ID)}/messages`, { method: 'POST', headers: { Authorization: `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error?.message || `WhatsApp API request failed (${response.status}).`);
  await db('store_order_notification_logs', { method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' }, body: JSON.stringify({ store_order_id: order.id, event_type: eventType, status: 'sent', provider_message_id: result.messages?.[0]?.id || null }) });
  return { sent: true, message_id: result.messages?.[0]?.id || null };
}
module.exports = { notifyStoreOrder };
