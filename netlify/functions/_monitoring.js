const crypto = require('crypto');
const SB_URL = String(process.env.SUPABASE_URL || 'https://gmuzqcuovlsacsgjxlts.supabase.co').replace(/\/$/, '');
const SB_SERVICE = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
function clean(value, max = 1200) {
  return String(value || '').replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, '$1[redacted]')
    .replace(/(api[_-]?key|password|token|secret|authorization)(\s*[:=]\s*)[^\s,;]+/gi, '$1$2[redacted]')
    .replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, '[email]')
    .slice(0, max);
}
async function logServerError(source, error, context = {}) {
  if (!SB_SERVICE) return;
  const message = clean(error?.message || error || 'Unknown server error', 1200);
  const fingerprint = crypto.createHash('sha256').update(`${source}|${message}`).digest('hex').slice(0, 32);
  const payload = { event_type: 'server_error', severity: 'error', source: clean(source, 120), page_path: '/.netlify/functions/' + clean(source, 100), message, stack: clean(error?.stack || '', 5000), fingerprint, metadata: context && typeof context === 'object' ? context : {} };
  try {
    await fetch(`${SB_URL}/rest/v1/orderdesk_monitoring_events`, { method: 'POST', headers: { apikey: SB_SERVICE, Authorization: `Bearer ${SB_SERVICE}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: JSON.stringify(payload) });
  } catch (_) { /* Monitoring must never interrupt the primary function. */ }
}
module.exports = { logServerError };
