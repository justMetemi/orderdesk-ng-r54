// Public list of Nigerian banks supported by Paystack. Secret key remains server-side.
const { logServerError } = require('./_monitoring');
const J=(statusCode,body)=>({statusCode,headers:{"Content-Type":"application/json","Cache-Control":"no-store"},body:JSON.stringify(body)});
exports.handler=async event=>{
  if(event.httpMethod!=="GET")return J(405,{error:"Use GET."});
  const key=String(process.env.PAYSTACK_SECRET_KEY||"").trim();
  if(!key)return J(503,{error:"Bank services are not configured yet. Add PAYSTACK_SECRET_KEY in Netlify environment variables, then redeploy."});
  try{
    const response=await fetch("https://api.paystack.co/bank?country=nigeria&perPage=100",{headers:{Authorization:"Bearer "+key,Accept:"application/json"}});
    const data=await response.json();
    if(!response.ok||!data.status) return J(response.status||502,{error:data.message||"Paystack could not return the bank list."});
    const banks=(data.data||[]).filter(x=>x.name&&x.code).map(x=>({name:x.name,code:String(x.code)})).sort((a,b)=>a.name.localeCompare(b.name));
    return J(200,{banks});
  }catch(error){await logServerError('bank-list',error);return J(502,{error:"Unable to contact the bank directory. Please try again."})}
};
