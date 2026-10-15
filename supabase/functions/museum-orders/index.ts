import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.76.1';
const ORIGIN='https://bootstrap-bba.pages.dev';
const cors={'Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Cache-Control':'no-store'};
Deno.serve(async req=>{
if(req.method==='OPTIONS')return new Response(null,{headers:cors});
const reply=(data,status=200)=>Response.json(data,{status,headers:cors});
if(req.method!=='POST')return reply({error:'Method not allowed'},405);
const auth=req.headers.get('Authorization')||'';if(!auth.startsWith('Bearer '))return reply({error:'Sign in first.'},401);
const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!;
const client=createClient(url,anon,{global:{headers:{Authorization:auth}},auth:{persistSession:false}});
const {data:{user},error:authError}=await client.auth.getUser();if(authError||!user||!user.email_confirmed_at)return reply({error:'Sign in with a confirmed account.'},401);
let body;try{body=await req.json();}catch{return reply({error:'Invalid request'},400);}
if(!/^[a-f0-9]{64}$/.test(body.token||''))return reply({error:'Invalid order token'},400);
try{
const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(body.token))),b=>b.toString(16).padStart(2,'0')).join('');
const {data:checkout,error}=await client.from('checkout_sessions').select('user_id,created_at').eq('token_hash',hash).maybeSingle();
if(error||!checkout||checkout.user_id!==user.id||Date.now()-Date.parse(checkout.created_at)>7*86400000)return reply({error:'This checkout does not belong to your account or has expired.'},403);
const verified=await fetch(ORIGIN+'/api/order-confirmation',{method:'POST',headers:{Origin:ORIGIN,'Content-Type':'application/json'},body:JSON.stringify({token:body.token}),signal:AbortSignal.timeout(20000)});
const order=await verified.json();if(!verified.ok)return reply({error:order.error||'Complete your order form first.'},verified.status);
const admin=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false}});
const {data:existing}=await admin.from('orders').select('user_id').eq('jotform_submission_id',order.reference).maybeSingle();
if(existing&&existing.user_id!==user.id)return reply({error:'Order is already linked to another account.'},403);
if(!existing){const {error:saveError}=await admin.rpc('museum_finalize_order',{owner_id:user.id,checkout_hash:hash,submission_id:order.reference,order_summary:order.summary,delivery_method:order.delivery});if(saveError)return reply({error:saveError.message||'Unable to finalise stock for this order.'},409);}
return reply({success:true});
}catch{return reply({error:'Unable to save the order. Please try again.'},503);}
});
