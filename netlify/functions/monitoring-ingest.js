const crypto = require('crypto');
const SB_URL = String(process.env.SUPABASE_URL || 'https://gmuzqcuovlsacsgjxlts.supabase.co').replace(/\/$/, '');
const SB_SERVICE = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const json = (statusCode, body) => ({ statusCode, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }, body: JSON.stringify(body) });
const clean = (v, n) => String(v || '').replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, '$1[redacted]').replace(/(api[_-]?key|password|token|secret|authorization)(\s*[:=]\s*)[^\s,;]+/gi, '$1$2[redacted]').replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, '[email]').slice(0, n);
exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return json(204, {});
  if (event.httpMethod !== 'POST') return json(405, { error: 'Use POST.' });
  if (!SB_SERVICE) return json(503, { error: 'Monitoring storage is not configured.' });
  try {
    const b = JSON.parse(event.body || '{}');
    const allowed = ['browser_error', 'unhandled_rejection', 'resource_error', 'web_vital'];
    if (!allowed.includes(b.event_type)) return json(400, { error: 'Unsupported event type.' });
    const message = clean(b.message || b.metric_name || 'Browser event', 1200);
    const source = clean(b.source || 'browser', 120);
    const fingerprint = crypto.createHash('sha256').update(`${b.event_type}|${source}|${message}`).digest('hex').slice(0, 32);
    const ip = String(event.headers?.['x-nf-client-connection-ip'] || event.headers?.['x-forwarded-for'] || 'unknown').split(',')[0].trim();
    const ipHash = crypto.createHash('sha256').update(`${process.env.MONITORING_IP_SALT || SB_SERVICE.slice(0,24)}|${ip}`).digest('hex');
    const countUrl = `${SB_URL}/rest/v1/orderdesk_monitoring_events?client_ip_hash=eq.${ipHash}&created_at=gte.${encodeURIComponent(new Date(Date.now()-3600000).toISOString())}&select=id&limit=61`;
    const countRes = await fetch(countUrl,{headers:{apikey:SB_SERVICE,Authorization:`Bearer ${SB_SERVICE}`}});
    if(countRes.ok){const recent=await countRes.json();if(recent.length>=60)return json(429,{error:'Monitoring rate limit reached.'});}
    const payload = { client_ip_hash: ipHash, event_type: b.event_type, severity: b.severity === 'warning' ? 'warning' : 'error', source, page_path: clean(b.page_path || '/', 300), message, stack: clean(b.stack || '', 5000), fingerprint, user_agent: clean(event.headers?.['user-agent'] || '', 500), metric_name: b.event_type === 'web_vital' ? clean(b.metric_name, 30) : null, metric_value: b.event_type === 'web_vital' && Number.isFinite(Number(b.metric_value)) ? Number(b.metric_value) : null, metric_rating: ['good','needs-improvement','poor'].includes(b.metric_rating) ? b.metric_rating : null, metadata: b.metadata && typeof b.metadata === 'object' ? b.metadata : {} };
    const r = await fetch(`${SB_URL}/rest/v1/orderdesk_monitoring_events`, { method: 'POST', headers: { apikey: SB_SERVICE, Authorization: `Bearer ${SB_SERVICE}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: JSON.stringify(payload) });
    if (!r.ok) return json(502, { error: 'Could not store monitoring event.' });
    return json(202, { accepted: true });
  } catch (_) { return json(400, { error: 'Invalid monitoring event.' }); }
};
