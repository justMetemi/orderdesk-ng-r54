// Writes a short WhatsApp follow-up message with Groq. Only signed-in OrderDesk users can call it.
const SB_URL="https://gmuzqcuovlsacsgjxlts.supabase.co",SB_KEY="sb_publishable_8Y4r9YNW2AlMnNfcXZsdsQ_aYTfJeFV";
const J=(c,b)=>({statusCode:c,headers:{"Content-Type":"application/json","Cache-Control":"no-store"},body:JSON.stringify(b)});
const LANG={en:"English",yo:"Yoruba, with correct tone marks",pcm:"Nigerian Pidgin English"};
exports.handler=async e=>{
  if(e.httpMethod!=="POST")return J(405,{error:"Use POST."});
  const key=String(process.env.GROQ_API_KEY||process.env.TEMI_WEBSITE_ASSISTANT||"").trim().replace(/^["']+|["']+$/g,"").trim();
  if(!key)return J(503,{error:"AI is not set up yet. Add GROQ_API_KEY in Netlify and deploy again."});
  const tok=String(e.headers.authorization||e.headers.Authorization||"").replace(/^Bearer\s+/i,"");
  if(!tok)return J(401,{error:"Please sign in."});
  const who=await fetch(SB_URL+"/auth/v1/user",{headers:{apikey:SB_KEY,Authorization:"Bearer "+tok}}).catch(()=>null);
  if(!who||!who.ok)return J(401,{error:"Please sign in again."});
  let b;try{b=JSON.parse(e.body||"{}")}catch(_){return J(400,{error:"Bad request."})}
  const t=(v,n)=>String(v==null?"":v).replace(/[\r\n]+/g," ").slice(0,n);
  const facts={business:t(b.business,60),customer_first_name:t(b.name,30),message_goal:t(b.goal,40),product:t(b.product,60),amount_owed:t(b.owed,20),days_since_last_order:Number(b.days)||0};
  const sys="You write one short WhatsApp message from a small business owner in Nigeria to one customer. Use ONLY the facts given. Never invent discounts, prices, dates, promises or links. Be warm, polite and respectful. Maximum 60 words. No hashtags. Reply with the message text only. Write it in "+(LANG[b.lang]||LANG.en)+".";
  for(const model of ["openai/gpt-oss-120b","llama-3.3-70b-versatile","llama-3.1-8b-instant"]){
    const body={model,messages:[{role:"system",content:sys},{role:"user",content:JSON.stringify(facts)}],max_completion_tokens:300,temperature:0.6,stream:false};
    if(model.startsWith("openai/gpt-oss")){body.max_completion_tokens=1000;body.reasoning_effort="low"}
    let r,d;try{r=await fetch("https://api.groq.com/openai/v1/chat/completions",{method:"POST",headers:{Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify(body)});d=await r.json().catch(()=>({}))}catch(_){return J(502,{error:"The AI service could not be reached."})}
    if(r.ok){const x=d.choices&&d.choices[0]&&d.choices[0].message&&d.choices[0].message.content;if(x&&x.trim())return J(200,{reply:x.trim()});continue}
    console.error("OrderDesk AI error:",model,r.status,(d.error&&d.error.code)||"");
    if(r.status===404||(r.status===400&&/model/i.test((d.error&&(d.error.code||d.error.message))||"")))continue;
    if(r.status===401)return J(502,{error:"The AI key was not accepted. Check GROQ_API_KEY in Netlify."});
    if(r.status===429)return J(502,{error:"The AI has reached its free limit for now. Try again later."});
    return J(502,{error:"The AI is unavailable right now."});
  }
  return J(502,{error:"The AI could not write a message right now."});
};
