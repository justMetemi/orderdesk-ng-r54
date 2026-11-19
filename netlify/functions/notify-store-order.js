const { notifyStoreOrder } = require('./_whatsapp-notify');
const { notifyStoreOrderEmail } = require('./_brevo-email');
const { logServerError } = require('./_monitoring');
const json = (statusCode, body) => ({ statusCode, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, body: JSON.stringify(body) });
exports.handler = async event => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Use POST.' });
  try {
    const body = JSON.parse(event.body || '{}');
    const orderId = String(body.order_id || '').trim();
    const eventType = String(body.event_type || '').trim();
    if (!/^[0-9a-f-]{36}$/i.test(orderId)) return json(400, { error: 'Invalid order reference.' });
    const results = {};
    // Each channel is best-effort and independent: an email failure must not block WhatsApp or checkout.
    try { results.whatsapp = await notifyStoreOrder(orderId, eventType); }
    catch (error) { results.whatsapp = { sent: false, error: error.message || 'Notification request failed.' }; }
    try { results.email = await notifyStoreOrderEmail(orderId, eventType); }
    catch (error) { results.email = { sent: false, error: error.message || 'Email notification failed.' }; }
    return json(200, { success: true, ...results });
  } catch (error) { await logServerError('notify-store-order', error); return json(502, { success: false, error: error.message || 'Notification request failed.' }); }
};
