// Daily scheduled subscription reminders. Requires server-side service-role and Brevo secrets.
const SB_URL=process.env.SUPABASE_URL||"https://gmuzqcuovlsacsgjxlts.supabase.co";
const SERVICE_KEY=process.env.SUPABASE_SERVICE_ROLE_KEY;
const BREVO_KEY=process.env.BREVO_API_KEY;
const SENDER=process.env.BREVO_SENDER_EMAIL;
const SENDER_NAME=process.env.BREVO_SENDER_NAME||"OrderDesk NG";
const json=async r=>{try{return await r.json()}catch(_){return {}}};
async function rest(path,method="GET",body){const r=await fetch(SB_URL+"/rest/v1/"+path,{method,headers:{apikey:SERVICE_KEY,Authorization:"Bearer "+SERVICE_KEY,"Content-Type":"application/json",Prefer:method==="GET"?"":"return=representation"},...(body?{body:JSON.stringify(body)}:{})});const d=await json(r);if(!r.ok)throw new Error(d.message||"Supabase reminder query failed");return d}
async function sendEmail(to,name,subject,html){const r=await fetch("https://api.brevo.com/v3/smtp/email",{method:"POST",headers:{"api-key":BREVO_KEY,"Content-Type":"application/json"},body:JSON.stringify({sender:{name:SENDER_NAME,email:SENDER},to:[{email:to,name:name||"Business owner"}],subject,htmlContent:html})});const d=await json(r);if(!r.ok)throw new Error(d.message||"Brevo email failed");return d}
exports.handler=async()=>{
 if(!SERVICE_KEY||!BREVO_KEY||!SENDER)return {statusCode:503,body:"Configure SUPABASE_SERVICE_ROLE_KEY, BREVO_API_KEY and BREVO_SENDER_EMAIL."};
 try{
  const now=new Date(),dayStart=new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth(),now.getUTCDate())),until=new Date(dayStart.getTime()+8*864e5);
  const rows=await rest("subscriptions?select=id,business_id,plan,status,started_at,ends_at&status=eq.active&plan=in.(essentials,standard,monthly,growth)&started_at=lte."+encodeURIComponent(now.toISOString())+"&ends_at=gte."+encodeURIComponent(dayStart.toISOString())+"&ends_at=lte."+encodeURIComponent(until.toISOString()));
  const ids=[...new Set((rows||[]).map(x=>x.business_id))];if(!ids.length)return {statusCode:200,body:JSON.stringify({sent:0})};
  const businesses=await rest("businesses?select=id,name,owner_name,email&id=in.("+ids.join(",")+")");
  const byId=new Map((businesses||[]).map(x=>[x.id,x]));let sent=0,skipped=0,failed=0;
  for(const sub of rows||[]){const b=byId.get(sub.business_id);if(!b?.email){skipped++;continue}const end=new Date(sub.ends_at),endDay=new Date(Date.UTC(end.getUTCFullYear(),end.getUTCMonth(),end.getUTCDate())),days=Math.round((endDay-dayStart)/864e5);const target=[7,3,1,0].find(n=>days===n);if(target===undefined){skipped++;continue}
   const prior=await rest("orderdesk_subscription_reminder_logs?select=id&subscription_id=eq."+sub.id+"&days_remaining=eq."+target);
   if(prior?.length){skipped++;continue}
   const when=target===0?"today":`in ${target} day${target===1?"":"s"}`;
   const subject=target===0?"Your OrderDesk subscription expires today":"OrderDesk subscription renewal reminder";
   const html=`<div style="font-family:Arial,sans-serif;line-height:1.6;color:#173326"><h2 style="color:#087848">OrderDesk NG</h2><p>Hello ${String(b.owner_name||b.name||"there").replace(/[<>]/g,"")},</p><p>Your <b>${String(sub.plan||"OrderDesk").replace(/[<>]/g,"")}</b> subscription expires ${when} (${end.toLocaleDateString("en-NG")}).</p><p>To avoid interruption to your online store and paid features, sign in to OrderDesk NG and renew from <b>Settings → Subscription &amp; billing</b>.</p><p>Thank you for using OrderDesk NG.</p></div>`;
   try{await sendEmail(b.email,b.owner_name,subject,html);await rest("orderdesk_subscription_reminder_logs", "POST",{subscription_id:sub.id,business_id:sub.business_id,days_remaining:target});sent++}catch(e){failed++;console.error("Subscription reminder failed",sub.id,String(e.message||e).slice(0,140))}
  }
  return {statusCode:200,body:JSON.stringify({sent,skipped,failed})};
 }catch(e){console.error("Subscription reminder job failed",String(e.message||e).slice(0,180));return {statusCode:500,body:"Subscription reminder job failed."}}
};
