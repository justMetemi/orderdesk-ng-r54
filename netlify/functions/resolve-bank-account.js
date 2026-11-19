// Authenticated account-name resolution. PAYSTACK_SECRET_KEY is never sent to the browser.
const { logServerError } = require('./_monitoring');
const SB_URL="https://gmuzqcuovlsacsgjxlts.supabase.co";
const SB_KEY="sb_publishable_8Y4r9YNW2AlMnNfcXZsdsQ_aYTfJeFV";
const J=(statusCode,body)=>({statusCode,headers:{"Content-Type":"application/json","Cache-Control":"no-store"},body:JSON.stringify(body)});
exports.handler=async event=>{
  if(event.httpMethod!=="POST")return J(405,{error:"Use POST."});
  const secret=String(process.env.PAYSTACK_SECRET_KEY||"").trim();
  if(!secret)return J(503,{error:"Account verification is not configured. Add PAYSTACK_SECRET_KEY in Netlify and redeploy."});
  const token=String(event.headers.authorization||event.headers.Authorization||"").replace(/^Bearer\s+/i,"").trim();
  if(!token)return J(401,{error:"Please sign in to verify a merchant bank account."});
  try{
    const auth=await fetch(SB_URL+"/auth/v1/user",{headers:{apikey:SB_KEY,Authorization:"Bearer "+token}});
    if(!auth.ok)return J(401,{error:"Your session has expired. Sign in again."});
    let body;try{body=JSON.parse(event.body||"{}")}catch(_){return J(400,{error:"Invalid request."})}
    const account=String(body.account_number||"").replace(/\s/g,"");
    const code=String(body.bank_code||"").trim();
    if(!/^\d{10}$/.test(account)||!code||code.length>20)return J(400,{error:"Enter a valid 10-digit account number and choose a bank."});
    const url="https://api.paystack.co/bank/resolve?account_number="+encodeURIComponent(account)+"&bank_code="+encodeURIComponent(code);
    const response=await fetch(url,{headers:{Authorization:"Bearer "+secret,Accept:"application/json"}});
    const data=await response.json();
    if(!response.ok||!data.status)return J(response.status||422,{error:data.message||"The bank could not verify these details."});
    return J(200,{account_name:String(data.data?.account_name||"").trim(),account_number:String(data.data?.account_number||account),bank_id:data.data?.bank_id||null});
  }catch(error){await logServerError('resolve-bank-account',error);return J(502,{error:"Account verification service is temporarily unavailable."})}
};
