import assert from 'node:assert/strict';
export async function verifySentGifts({db,rpc,admin,anon}){
 await db.exec("reset role;delete from farmer_private.order_lookup_limits;");await anon();
 const lookup=(name='구매자',phone='010-1234-5678',offset=0)=>rpc('select public.farmer_lookup_gifts($1,$2,$3) as result',[name,phone,offset]);
 let r=await lookup();assert.equal(r.found,true);assert.equal(r.total_count,2);assert.equal(r.gifts.length,2);
 assert.ok(r.gifts.every(g=>g.recipient_label.includes('*')));assert.ok(r.gifts.some(g=>g.status==='delivered'&&g.state==='claimed'));assert.ok(r.gifts.some(g=>g.status==='pending'&&g.state==='pending'));
 for(const g of r.gifts)for(const k of ['token','message','phone','customer_name','address','recipient_phone','order_id','claim_request_id','batch_id'])assert.equal(g[k],undefined,k);
 assert.deepEqual(await lookup('구매자','01099999999'),{found:false});assert.deepEqual(await lookup('다른 이름'),{found:false});assert.deepEqual(await lookup('', 'bad'),{found:false});assert.deepEqual(await lookup('구매자','01012345678',-1),{found:false});
 // Additional purchases paginate; administrative free gifts and normal sales stay excluded.
 const items=JSON.stringify(Array.from({length:20},(_,i)=>({product_id:'hopungmi-2kg',quantity:1,recipient_label:'친구'+i,message:'개인 메시지'})));
 await rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,$8) as result',['b0000000-0000-4000-8000-000000000001','구매자','01012345678','보내는이',items,'',240000,true]);
 r=await lookup();assert.equal(r.total_count,22);assert.equal(r.gifts.length,20);assert.equal(r.next_offset,20);const old=await lookup('구매자','01012345678',20);assert.equal(old.gifts.length,2);assert.equal(old.next_offset,null);assert.equal(new Set([...r.gifts,...old.gifts].map(g=>g.order_number)).size,22);
 await db.exec("reset role;update farmer_private.order_lookup_limits set attempts=20 where bucket='phone:'||md5('01012345678');");await anon();r=await lookup();assert.equal(r.found,false);assert.ok(r.retry_after>0);const ordinary=await rpc('select public.farmer_lookup_orders($1,$2,$3) as result',['구매자','01012345678',0]);assert.ok(ordinary.retry_after>0);
 await db.exec('reset role;');const flags=(await db.query("select has_table_privilege('anon','farmer_private.gift_links','select') as direct,has_function_privilege('anon','public.farmer_lookup_gifts(text,text,integer)','execute') as lookup")).rows[0];assert.deepEqual(flags,{direct:false,lookup:true});
 console.log('PASS: sent gift receipts, exact identity match, masked data, no tokens/addresses/messages, multiple purchases, pagination, shared rate limit and private table permissions.');
}
