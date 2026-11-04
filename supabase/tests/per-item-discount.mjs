import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyPerItemDiscount({db,rpc,admin,anon,expectError}){
 await db.exec('reset role;begin;update public.farmer_inventory set available_grams=1000000;');
 const bad=async(fn,text)=>{await db.exec('savepoint negative_item');try{await expectError(fn,text);}finally{await db.exec('rollback to savepoint negative_item;release savepoint negative_item;');}};
 const entry=(code,extra={})=>({id:randomUUID(),code,mode:'per_item',amount:2000,percent:0,product_id:null,usage_limit:null,active:true,...extra});
 const save=(e,v=null,id=randomUUID())=>rpc('select public.farmer_admin_discount_save($1,$2,$3) as result',[id,JSON.stringify(e),v]);
 const list=()=>rpc("select public.farmer_admin_discount_list('개당검증','',0) as result");
 const quote=(ds,code)=>rpc('select public.farmer_quote_batch($1,$2) as result',[JSON.stringify(ds),code]);
 const d=(product_id='hopungmi-3kg',quantity=3,fulfillment_method='shipping')=>({product_id,quantity,fulfillment_method,recipient_name:'상품당할인검증',recipient_phone:'01022223333',postal_code:'04524',address:'서울 중구 세종대로 110',address_detail:'101호',memo:''});
 const e=entry('개당검증2000'),limited=entry('개당검증한번',{usage_limit:1}),capped=entry('개당검증상한',{amount:20000});
 await anon();await bad(()=>save(e),'permission denied');await admin();const id=randomUUID(),saved=await save(e,null,id);assert.deepEqual(await save(e,null,id),saved);await save(limited);await save(capped);
 assert.equal((await list()).codes.find(c=>c.id===e.id).mode,'per_item');await bad(()=>save(entry('개당검증오류',{amount:0})),'할인 금액');await bad(()=>save(entry('개당검증오류율',{percent:10})),'할인 금액');await bad(()=>save({...e,amount:3000},99),'다른 화면');
 await anon();let q=await quote([d()],e.code);assert.equal(q.discount_amount,6000);assert.equal(q.total,42000);assert.equal(q.shipping_fee,0);
 q=await quote([d('hopungmi-2kg',2),d(),d('hopungmi-5kg',1)],e.code);assert.equal(q.subtotal,94000);assert.equal(q.discount_amount,12000);assert.equal(q.total,82000);assert.deepEqual(q.deliveries.map(d=>d.discount_amount),[4000,6000,2000]);
 q=await quote([d('hopungmi-3kg',2,'pickup')],e.code);assert.equal(q.discount_amount,4000);assert.equal(q.total,28000);assert.equal(q.deliveries[0].fulfillment_method,'pickup');
 q=await quote([d('hopungmi-2kg',2),d('hopungmi-5kg',1)],capped.code);assert.equal(q.total,2000);assert.deepEqual(q.deliveries.map(d=>d.discount_amount),[24000,20000]);
 const request=randomUUID(),submit=()=>rpc('select public.farmer_submit_batch($1,$2,$3,$4,$5,$6,true) as result',[request,'개당할인주문자','01011112222',JSON.stringify([d()]),limited.code,42000]);const receipt=await submit();assert.deepEqual(await submit(),receipt);
 await bad(()=>rpc('select public.farmer_submit_batch($1,$2,$3,$4,$5,$6,true) as result',[randomUUID(),'개당할인주문자','01011112222',JSON.stringify([d()]),limited.code,42000]),'소진');
 await admin();assert.equal((await list()).codes.find(c=>c.id===limited.id).used_count,1);await anon();
 const giftItems=[{product_id:'hopungmi-3kg',quantity:3,recipient_label:'친구하나',message:''},{product_id:'hopungmi-5kg',quantity:2,recipient_label:'친구둘',message:''}],giftRequest=randomUUID();
 const buy=()=>rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,true) as result',[giftRequest,'개당할인선물','01033334444','보내는이',JSON.stringify(giftItems),e.code,82000]);const gifts=await buy();assert.equal(gifts.total,82000);assert.deepEqual(await buy(),gifts);
 await admin();assert.equal((await list()).codes.find(c=>c.id===e.id).used_count,2);
 const orders=await rpc("select public.farmer_admin_order_list('','개당할인선물',0,'') as result");assert.equal(orders.total,2);const first=orders.orders[0];await rpc('select public.farmer_admin_change_status($1,$2,$3,$4) as result',[first.id,'cancelled',first.version,randomUUID()]);assert.equal((await list()).codes.find(c=>c.id===e.id).used_count,1);
 const changed=await save({...e,amount:3000},1);assert.equal(changed.version,2);await anon();assert.equal((await quote([d()],e.code)).discount_amount,9000);assert.deepEqual(await buy(),gifts);await admin();assert.equal((await list()).codes.find(c=>c.id===e.id).amount,3000);
 await db.exec('reset role;rollback;');console.log('PASS: per-item coupon CRUD/auth/retries, mixed weights/quantities, pickup, per-unit price caps, ordinary checkout use once, per-recipient gift usage/cancellation, and edits preserving past receipts.');
}
