// OrderDesk NG: authenticated Cloudinary upload signature. Never expose API secret in browser code.
const crypto=require("crypto");
const reply=(statusCode,body)=>({statusCode,headers:{"Content-Type":"application/json","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"},body:JSON.stringify(body)});
exports.handler=async event=>{
 if(event.httpMethod!=="POST")return reply(405,{error:"Use POST."});
 const token=String(event.headers.authorization||event.headers.Authorization||"").replace(/^Bearer\s+/i,"");
 if(!token)return reply(401,{error:"Sign in to save images."});
 const url=process.env.SUPABASE_URL||"https://gmuzqcuovlsacsgjxlts.supabase.co";
 const anon=process.env.SUPABASE_ANON_KEY||"sb_publishable_8Y4r9YNW2AlMnNfcXZsdsQ_aYTfJeFV";
 const auth=await fetch(url+"/auth/v1/user",{headers:{apikey:anon,Authorization:"Bearer "+token}});
 if(!auth.ok)return reply(401,{error:"Your session has expired. Sign in again."});
 const cloud=String(process.env.CLOUDINARY_CLOUD_NAME||"").trim();
 const key=String(process.env.CLOUDINARY_API_KEY||"").trim();
 const secret=String(process.env.CLOUDINARY_API_SECRET||"").trim();
 if(!cloud||!key||!secret)return reply(503,{error:"Cloudinary is not configured. Add CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY and CLOUDINARY_API_SECRET in Netlify."});
 const timestamp=Math.floor(Date.now()/1000);
 const folder="orderdesk/products";
 const params=`folder=${folder}&timestamp=${timestamp}`;
 const signature=crypto.createHash("sha1").update(params+secret).digest("hex");
 return reply(200,{cloud_name:cloud,api_key:key,timestamp,folder,signature});
};
