const { sendEmail } = require('./_brevo-email');
const { logServerError } = require('./_monitoring');
const json = (statusCode, body) => ({ statusCode, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, body: JSON.stringify(body) });
exports.handler = async event => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Use POST.' });
  const expected = String(process.env.ORDERDESK_EMAIL_TEST_TOKEN || '').trim();
  const supplied = String(event.headers?.authorization || event.headers?.Authorization || '').replace(/^Bearer\s+/i, '').trim();
  if (!expected || !supplied || supplied !== expected) return json(401, { error: 'Not authorised.' });
  const recipient = String(process.env.ORDERDESK_EMAIL_TEST_TO || '').trim();
  if (!recipient) return json(503, { error: 'Set ORDERDESK_EMAIL_TEST_TO to the email address that should receive the test.' });
  try {
    const result = await sendEmail(recipient, 'OrderDesk NG — Brevo email test', 'This is a test email from OrderDesk NG. If you received it, the Brevo API connection is working.', '<div style="font-family:Arial,sans-serif;padding:20px"><h2>OrderDesk NG email test</h2><p>If you received this message, the Brevo email connection is working.</p></div>');
    return json(result.sent ? 200 : 503, result);
  } catch (error) { await logServerError('test-order-email', error); return json(502, { error: error.message || 'Test email failed.' }); }
};
