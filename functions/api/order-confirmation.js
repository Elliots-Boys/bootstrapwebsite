export async function onRequestPost({request,env}) {
const reply=(data,status=200)=>Response.json(data,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
if(request.headers.get('Origin')!==new URL(request.url).origin)return reply({error:'Access denied.'},403);
let body;try{body=await request.json();}catch{return reply({error:'Invalid request.'},400);}
if(!/^[a-f0-9]{64}$/.test(body.token||''))return reply({error:'No valid order access token.'},403);
if(!env.JOTFORM_API_KEY)return reply({error:'Order verification is unavailable.'},503);
try {
const url=new URL('https://api.jotform.com/form/262843406756060/submissions');url.searchParams.set('limit','1000');url.searchParams.set('orderby','created_at');url.searchParams.set('filter',JSON.stringify({'created_at:gt':new Date(Date.now()-7*86400000).toISOString().slice(0,19).replace('T',' ')}));
const response=await fetch(url,{headers:{apiKey:env.JOTFORM_API_KEY},signal:AbortSignal.timeout(15000)});
const data=await response.json();if(!response.ok||data.responseCode!==200||!Array.isArray(data.content))return reply({error:'Unable to verify the order. Please try again later.'},503);
const order=data.content.find(s=>s.form_id==='262843406756060'&&s.status!=='DELETED'&&Object.values(s.answers||{}).some(a=>a.text?.toLowerCase()==='order access token'&&a.answer===body.token));
if(!order)return reply({error:'No completed order was found. Complete the order form from your basket first.'},404);
const answers=Object.values(order.answers||{});const value=label=>answers.find(a=>a.text?.toLowerCase()===label)?.answer;
const name=value('full name');
return reply({reference:order.id,date:order.created_at,name:typeof name==='object'?[name.first,name.last].filter(Boolean).join(' '):String(name||''),summary:String(value('order summary')||''),delivery:String(value('delivery or museum collection')||''),notes:String(value('order notes (optional)')||'')});
}catch{return reply({error:'Unable to verify the order. Please try again later.'},503);}
}
export function onRequestGet(){return Response.json({error:'Use the confirmation page to view your order.'},{status:405,headers:{'Cache-Control':'no-store'}});}
