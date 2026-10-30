import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyFulfillmentCosts({db,rpc,admin,anon,expectError}){
 const report=(year=2050)=>rpc('select public.farmer_admin_fulfillment_costs($1) as result',[year]);
 const save=(s,p,v)=>rpc('select public.farmer_admin_save_fulfillment_costs($1,$2,$3) as result',[s,p,v]);
 await anon();await expectError(()=>report(),'permission denied');await expectError(()=>save(1,1,1),'permission denied');
 await db.exec(`reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;`);
 await expectError(()=>report(),'관리자 권한');await expectError(()=>save(1,1,1),'관리자 권한');
 await admin();await expectError(()=>db.query('select * from farmer_private.fulfillment_cost_settings'),'permission denied');
 let r=await report();assert.deepEqual(r.settings,{shipping:4000,packing:1500,version:1});assert.equal(r.shipping_boxes,0);
 const saved=await save(4100,1600,1);assert.equal(saved.version,2);assert.deepEqual(await save(4100,1600,1),saved);
 await expectError(()=>save(4200,1700,1),'다른 화면');await expectError(()=>save(-1,1000,2),'0 이상의');await expectError(()=>report(1999),'연도');
 await save(4000,1500,2);
 // Create legitimate multi-quantity sales and free gifts. Confirm and group them in a synthetic Korea year.
 await db.exec('reset role;update public.farmer_inventory set available_grams=1000000;');await anon();
 const base={recipient_name:'비용 검증',recipient_phone:'01012345678',postal_code:'04524',address:'서울 중구 세종대로 110',address_detail:'',memo:''};
 const deliveries=[{...base,product_id:'hopungmi-2kg',quantity:3},{...base,product_id:'hopungmi-5kg-pickup',quantity:2}];
 const batch=randomUUID();await rpc('select public.farmer_submit_batch($1,$2,$3,$4,$5,$6,$7) as result',[batch,'비용 검증','01012345678',JSON.stringify(deliveries),'',80000,true]);
 await admin();const orders=(await rpc('select public.farmer_admin_order_list($1,$2,$3,$4) as result',['','비용 검증',0,'sale'])).orders.filter(o=>o.batch_id===batch);
 for(const o of orders)await rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,'confirmed',1,randomUUID(),'','']);
 const gifts=await rpc('select public.farmer_admin_create_gifts($1,$2) as result',[randomUUID(),JSON.stringify([{...base,product_id:'hopungmi-5kg',quantity:2,gift_sponsor:'윤가희'},{...base,product_id:'hopungmi-5kg-pickup',quantity:4,gift_sponsor:'홍세환'}])]);
 const giftNumbers=gifts.orders.map(o=>Number(o.order_number.slice(3)));
 await db.exec('reset role;');
 await db.query("update public.farmer_orders set confirmed_at='2049-12-31T15:01:00Z' where batch_id=$1 or order_no=any($2::bigint[])",[batch,giftNumbers]);
 // Pending/cancelled/archived records must not inflate expected fulfillment cost.
 await db.query("update public.farmer_orders set status='cancelled' where batch_id=$1 and product_id='hopungmi-5kg-pickup'",[batch]);
 await admin();r=await report();assert.equal(r.shipping_boxes,5);assert.equal(r.pickup_boxes,4);assert.equal((await report(2049)).shipping_boxes,0);
 await db.exec('reset role;');
 await db.query("update public.farmer_orders set deleted_at=now(),status='cancelled' where order_no=$1",[giftNumbers[0]]);
 await db.query("update public.farmer_orders set status='pending' where batch_id=$1 and product_id='hopungmi-2kg'",[batch]);
 await admin();r=await report();assert.equal(r.shipping_boxes,0);assert.equal(r.pickup_boxes,4);
 const entry={id:randomUUID(),occurred_on:'2050-01-01',direction:'expense',category:'배송비',title:'실제 택배비',counterparty:'',note:'',amount:8000,quantity:null,unit_price:null};
 await rpc('select public.farmer_admin_finance_save($1,$2,$3) as result',[randomUUID(),JSON.stringify(entry),null]);
 await rpc('select public.farmer_admin_finance_save($1,$2,$3) as result',[randomUUID(),JSON.stringify({...entry,id:randomUUID(),category:'포장비',amount:9000}),null]);
 r=await report();assert.equal(r.recorded_shipping,8000);assert.equal(r.recorded_packing,9000);
 console.log('PASS: shared default costs, admin-only access, version/retry safety, per-box quantities, free gift and pickup inclusion, cancellation/archive/pending exclusion, Korea year and recorded-cost reconciliation.');
}
