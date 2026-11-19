const crypto = require('crypto');
const { json, PAYSTACK_SECRET, safeEqualHex, verifyAndSettle } = require('./_paystack-common');
const { logServerError } = require('./_monitoring');
exports.handler = async event => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Use POST.' });
  if (!PAYSTACK_SECRET) return json(503, { error: 'Webhook is not configured.' });
  const raw = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
  const signature = event.headers['x-paystack-signature'] || event.headers['X-Paystack-Signature'] || '';
  const expected = crypto.createHmac('sha512', PAYSTACK_SECRET).update(raw).digest('hex');
  if (!safeEqualHex(signature, expected)) return json(401, { error: 'Invalid webhook signature.' });
  let payload;
  try { payload = JSON.parse(raw); } catch (_) { return json(400, { error: 'Invalid webhook payload.' }); }
  if (payload.event === 'charge.success' && payload.data?.reference) {
    try { await verifyAndSettle(String(payload.data.reference)); }
    catch (error) { await logServerError('paystack-webhook', error); return json(500, { received: true, processed: false, reason: error.message || 'Verification pending.' }); }
  }
  return json(200, { received: true });
};
