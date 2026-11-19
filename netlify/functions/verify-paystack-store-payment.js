const { json, parseBody, verifyAndSettle } = require('./_paystack-common');
const { logServerError } = require('./_monitoring');
exports.handler = async event => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Use POST.' });
  try {
    const body = parseBody(event);
    const result = await verifyAndSettle(String(body.reference || '').trim());
    return json(200, { success: true, order: result });
  } catch (error) {
    if (!error.status || Number(error.status) >= 500) await logServerError('verify-paystack-store-payment', error);
    return json(Number(error.status) || 400, { success: false, error: error.message || 'Payment verification failed.' });
  }
};
