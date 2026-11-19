/* OrderDesk NG privacy-conscious client monitoring. No session replay or form capture. */
(() => {
  if (window.__odMonitoringStarted) return; window.__odMonitoringStarted = true;
  const endpoint = '/.netlify/functions/monitoring-ingest';
  let sessionId=''; try { sessionId=sessionStorage.getItem('od_mon_sid')||''; if(!sessionId){sessionId=(crypto.randomUUID?crypto.randomUUID():String(Date.now())+'-'+Math.random().toString(36).slice(2));sessionStorage.setItem('od_mon_sid',sessionId);} } catch (_) {}
  const recent = new Map(); let sent = 0;
  const safe = (v, n=1200) => String(v || '').replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, '$1[redacted]').replace(/(api[_-]?key|password|token|secret|authorization)(\s*[:=]\s*)[^\s,;]+/gi, '$1$2[redacted]').replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, '[email]').slice(0,n);
  function send(data) {
    if (sent >= 30) return;
    const key = `${data.event_type}|${data.message}|${data.page_path}`; const now = Date.now();
    if (recent.has(key) && now - recent.get(key) < 60000) return;
    recent.set(key, now); sent++;
    const body = JSON.stringify({...data, metadata:{...(data.metadata||{}),session_id:sessionId}, page_path: location.pathname.slice(0,300), source:'browser'});
    try { fetch(endpoint, {method:'POST',headers:{'Content-Type':'application/json'},body,keepalive:true,credentials:'omit'}).catch(()=>{}); } catch (_) {}
  }
  addEventListener('error', e => {
    if (e.target && e.target !== window) { send({event_type:'resource_error',severity:'warning',message:'Resource failed to load: '+safe(e.target.tagName||'resource',80),metadata:{resource_type:safe(e.target.tagName||'',40)}}); return; }
    send({event_type:'browser_error',message:safe(e.message||'JavaScript error'),stack:safe(e.error?.stack||'',5000),metadata:{file:safe(e.filename||'',300),line:Number(e.lineno)||null,column:Number(e.colno)||null}});
  }, true);
  addEventListener('unhandledrejection', e => send({event_type:'unhandled_rejection',message:safe(e.reason?.message||e.reason||'Unhandled promise rejection'),stack:safe(e.reason?.stack||'',5000)}));
  const vital = (name, value, rating) => send({event_type:'web_vital',severity:rating==='poor'?'warning':'error',metric_name:name,metric_value:Math.round(value*1000)/1000,metric_rating:rating,message:name});
  try {
    let cls=0, lcp=0, inp=0;
    const rating=(name,v)=>name==='CLS'?(v<=.1?'good':v<=.25?'needs-improvement':'poor'):name==='LCP'?(v<=2500?'good':v<=4000?'needs-improvement':'poor'):(v<=200?'good':v<=500?'needs-improvement':'poor');
    new PerformanceObserver(list=>{for(const e of list.getEntries()){if(!e.hadRecentInput)cls+=e.value;}}).observe({type:'layout-shift',buffered:true});
    new PerformanceObserver(list=>{const e=list.getEntries().at(-1);if(e)lcp=e.startTime;}).observe({type:'largest-contentful-paint',buffered:true});
    new PerformanceObserver(list=>{for(const e of list.getEntries())if(e.interactionId)inp=Math.max(inp,e.duration);}).observe({type:'event',buffered:true,durationThreshold:40});
    const flush=()=>{if(lcp)vital('LCP',lcp,rating('LCP',lcp));vital('CLS',cls,rating('CLS',cls));if(inp)vital('INP',inp,rating('INP',inp));};
    addEventListener('pagehide',flush,{once:true});
  } catch (_) {}
  addEventListener('load',()=>{const nav=performance.getEntriesByType('navigation')[0];if(nav){const t=Math.max(0,nav.responseStart-nav.requestStart);send({event_type:'web_vital',metric_name:'TTFB',metric_value:Math.round(t),metric_rating:t<800?'good':t<1800?'needs-improvement':'poor',message:'TTFB'});}}, {once:true});
})();
