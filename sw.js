const V="od-v18-20261119-r53-commercial",SHELL=["/","/index.html","/shop.html","/customer-account.html","/marketplace.html","/growth-studio.html","/manifest.webmanifest","/brand-mark.svg","/icon-192.png","/icon-512.png"];
self.addEventListener("install",e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(SHELL)).catch(()=>{}));self.skipWaiting()});
self.addEventListener("activate",e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==V).map(x=>caches.delete(x)))));self.clients.claim()});
self.addEventListener("fetch",e=>{const r=e.request,u=new URL(r.url);
 if(r.method!=="GET"||u.hostname.endsWith("supabase.co")||u.pathname.startsWith("/.netlify/"))return;
 if(r.mode==="navigate"){e.respondWith(fetch(r).then(x=>{const cp=x.clone();caches.open(V).then(c=>c.put(r,cp));return x}).catch(()=>caches.match(r).then(m=>m||caches.match(u.pathname.startsWith("/shop/")?"/shop.html":"/index.html"))));return}
 if(u.origin===location.origin||u.hostname==="cdn.jsdelivr.net"){e.respondWith(caches.match(r).then(m=>{const n=fetch(r).then(x=>{const cp=x.clone();caches.open(V).then(c=>c.put(r,cp));return x}).catch(()=>m);return m||n}))}});
