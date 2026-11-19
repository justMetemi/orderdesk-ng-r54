// OrderDesk NG Product Studio: Cloudflare Workers AI image generation.
// Cloudflare credentials remain server-side. Free-plan usage is capped by Cloudflare.
const SB_URL=process.env.SUPABASE_URL||"https://gmuzqcuovlsacsgjxlts.supabase.co";
const SB_KEY=process.env.SUPABASE_ANON_KEY||"sb_publishable_8Y4r9YNW2AlMnNfcXZsdsQ_aYTfJeFV";
const MODEL="@cf/black-forest-labs/flux-2-klein-4b";
const reply=(statusCode,body)=>({statusCode,headers:{"Content-Type":"application/json","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"},body:JSON.stringify(body)});
const json=async r=>{try{return await r.json()}catch(_){return {}}};
async function rpc(name,token,args){const r=await fetch(SB_URL+"/rest/v1/rpc/"+name,{method:"POST",headers:{apikey:SB_KEY,Authorization:"Bearer "+token,"Content-Type":"application/json"},body:JSON.stringify(args)});const data=await json(r);if(!r.ok)throw new Error(data.message||data.error||"Usage control failed.");return data}
exports.handler=async event=>{
 if(event.httpMethod!=="POST")return reply(405,{error:"Use POST."});
 const token=String(event.headers.authorization||event.headers.Authorization||"").replace(/^Bearer\s+/i,"");
 if(!token)return reply(401,{error:"Sign in to use the Product Studio."});
 const auth=await fetch(SB_URL+"/auth/v1/user",{headers:{apikey:SB_KEY,Authorization:"Bearer "+token}});
 if(!auth.ok)return reply(401,{error:"Your session has expired. Sign in again."});
 const account=String(process.env.CLOUDFLARE_ACCOUNT_ID||"").trim();
 const apiToken=String(process.env.CLOUDFLARE_API_TOKEN||"").trim();
 if(!account||!apiToken)return reply(503,{error:"Cloudflare image generation is not configured. Add CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN in Netlify."});
 let body;try{body=JSON.parse(event.body||"{}")}catch(_){return reply(400,{error:"Invalid request."})}
 const prompt=String(body.prompt||"").trim().slice(0,1800);
 if(prompt.length<12)return reply(400,{error:"Describe the image change you want in at least 12 characters."});
 let raw="",mime="image/jpeg";
 if(body.image_base64){
  mime=String(body.mime_type||"");
  if(!["image/jpeg","image/png","image/webp"].includes(mime))return reply(400,{error:"Reference image must be JPEG, PNG or WebP."});
  raw=String(body.image_base64).replace(/^data:image\/[a-zA-Z0-9.+-]+;base64,/,"");
  if(raw.length>2_000_000)return reply(413,{error:"Reference image is too large. Try a smaller image."});
  if(!/^[A-Za-z0-9+/=]+$/.test(raw))return reply(400,{error:"Invalid image data."});
 }
 let usage;try{usage=await rpc("consume_orderdesk_ai_usage",token,{p_provider:"gemini_image",p_units:1})}catch(e){return reply(503,{error:"AI usage controls are not ready. Apply the r5_3_commercial_upgrade.sql migration included in this package."})}
 if(!usage.allowed)return reply(429,{error:usage.reason==="not_included"?"AI image generation is included in Standard only.":"Your image allowance is used up for this paid service period. It will renew when the next covered period begins.",usage});
 try{
  const form=new FormData();
  const instruction="Create or edit a commercial product photograph for a small business. Keep the real product identity, shape, material, colour, quantity, condition, packaging and functional features as accurate as possible. Do not invent brand marks, labels, certifications, ingredients, accessories or product features. Improve lighting, composition, background cleanliness and presentation only. User direction: "+prompt;
  form.append("prompt",instruction);
  form.append("width","1024");form.append("height","1024");
  if(raw){const bytes=Buffer.from(raw,"base64");form.append("input_image_0",new Blob([bytes],{type:mime}),mime==="image/png"?"reference.png":"reference.jpg");}
  const response=await fetch("https://api.cloudflare.com/client/v4/accounts/"+encodeURIComponent(account)+"/ai/run/"+MODEL,{method:"POST",headers:{Authorization:"Bearer "+apiToken},body:form});
  const ct=String(response.headers.get("content-type")||"");
  let imageBase64="";
  if(ct.includes("application/json")){
   const data=await json(response);imageBase64=data.result?.image||data.image||"";
   if(!response.ok||!imageBase64){await rpc("refund_orderdesk_ai_usage",token,{p_reservation_id:usage.reservation_id}).catch(()=>{});const msg=String(data.errors?.[0]?.message||data.error||"");return reply(response.status===429?429:502,{error:response.status===429?"Cloudflare's free daily AI allowance or rate limit has been reached. Your OrderDesk image credit was restored. Try again after the daily reset.":response.status===403?"Cloudflare rejected the request. Check that your API token has Workers AI permission and that this model is available on your Free plan.":"Cloudflare could not generate the image. Your OrderDesk image credit was restored. "+msg.slice(0,160)});}
  }else{
   const bytes=Buffer.from(await response.arrayBuffer());
   if(!response.ok||!bytes.length){await rpc("refund_orderdesk_ai_usage",token,{p_reservation_id:usage.reservation_id}).catch(()=>{});return reply(response.status===429?429:502,{error:"Cloudflare could not generate the image. Your OrderDesk image credit was restored."});}
   imageBase64=bytes.toString("base64");
  }
  const outBytes=Buffer.from(imageBase64,"base64");
  const outputMime=outBytes.length>8&&outBytes[0]===0x89&&outBytes[1]===0x50?"image/png":"image/jpeg";
  await rpc("commit_orderdesk_ai_usage",token,{p_reservation_id:usage.reservation_id});
  return reply(200,{image_base64:imageBase64,mime_type:outputMime,model:MODEL,usage,provider:"cloudflare_workers_ai"});
 }catch(e){await rpc("refund_orderdesk_ai_usage",token,{p_reservation_id:usage.reservation_id}).catch(()=>{});console.error("Cloudflare image function error",String(e.message||e).slice(0,180));return reply(502,{error:"Image generation could not connect. Your OrderDesk image credit was restored."})}
};
