import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyUnpaidShipment({db,rpc,admin,anon,expectError}){
 await db.exec('reset role;begin;update public.farmer_inventory set available_grams=1000000;');
 const bad=async(fn,text)=>{await db.exec('savepoint negative_unpaid');try{await expectError(fn,text);}finally{await db.exec('rollback to savepoint negative_unpaid;release savepoint negative_unpaid;');}};
 await anon();const catalog=await rpc('select public.farmer_catalog() as result');assert.equal(catalog.products.find(p=>p.id==='hopungmi-5kg-pickup').price,22000);
 const d={product_id:'hopungmi-5kg',quantity:2,recipient_name:'미수 검증',recipient_phone:'01000000000',postal_code:'12345',address:'검증 배송 주소',address_detail:'',memo:''};
 const submit=async(items)=>rpc('select public.farmer_submit_batch($1,$2,$3,$4,$5,$6,true) as result',[randomUUID(),'미수 상태 검증','01000000000',JSON.stringify(items),'',items.reduce((n,d)=>n+22000*d.quantity,0)]);
 const receipt=await submit([d,{...d,quantity:1}]);await admin();
 const list=()=>rpc("select public.farmer_admin_order_list('','미수 상태 검증',0,'') as result");
 const a=(await list()).orders.find(o=>o.quantity===2),b=(await list()).orders.find(o=>o.quantity===1);
 const change=(o,status,version,id=randomUUID(),carrier='한진',tracking='["11111","22222"]')=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,status,version,id,carrier,tracking]);
 const summary=()=>rpc('select public.farmer_admin_summary() as result');
 const finance=()=>rpc('select public.farmer_admin_finance_report(2026) as result');
 const costs=()=>rpc('select public.farmer_admin_fulfillment_costs(2026) as result');
 const stock0=(await summary()).available_kg,finance0=(await finance()).summary,costs0=await costs();
 await bad(()=>change(a,'shipped_unpaid',1,randomUUID(),''),'택배사');
 const request=randomUUID();await change(a,'shipped_unpaid',1,request);await change(a,'shipped_unpaid',1,request);
 let row=(await list()).orders.find(o=>o.id===a.id);assert.equal(row.status,'shipped_unpaid');assert.equal(row.confirmed_at,null);assert.ok(row.shipped_at);assert.deepEqual(row.tracking_numbers,['11111','22222']);
 const shippedAt=row.shipped_at;assert.equal((await summary()).available_kg,stock0-10);assert.equal((await finance()).summary.order_income,finance0.order_income);assert.equal((await finance()).summary.outstanding_income,(finance0.outstanding_income||0)+44000);assert.equal((await costs()).shipping_boxes,costs0.shipping_boxes+2);
 assert.ok((await rpc("select public.farmer_admin_export_orders('shipped_unpaid','','') as result")).orders.some(o=>o.id===a.id));
 await bad(()=>change(a,'delivered',2),'변경할 수 없는');
 await bad(()=>change(a,'shipped',1),'다른 화면');
 await anon();const lookup=await rpc('select public.farmer_lookup_orders($1,$2,0) as result',['미수 상태 검증','01000000000']);assert.ok(lookup.orders.some(o=>o.status==='shipped_unpaid'));assert.ok(lookup.orders.every(o=>!('address' in o)));
 await bad(()=>change(a,'shipped',2),'permission denied');await admin();
 const paidRequest=randomUUID();await change(a,'shipped',2,paidRequest,'','');await change(a,'shipped',2,paidRequest,'','');
 row=(await list()).orders.find(o=>o.id===a.id);assert.equal(row.status,'shipped');assert.equal(row.shipped_at,shippedAt);assert.ok(row.confirmed_at);assert.deepEqual(row.tracking_numbers,['11111','22222']);assert.equal(row.carrier,'한진');assert.equal((await summary()).available_kg,stock0-10);assert.equal((await finance()).summary.order_income,finance0.order_income+44000);
 await change(a,'shipped_unpaid',3);assert.equal((await finance()).summary.order_income,finance0.order_income);assert.equal((await summary()).available_kg,stock0-10);
 const bulk=await rpc('select public.farmer_admin_bulk_status($1,$2) as result',[JSON.stringify([{order_id:a.id,expected_version:4,request_id:randomUUID()}]),'shipped']);assert.equal(bulk.processed_count,1);
 await change(a,'delivered',5);assert.equal((await summary()).available_kg,stock0-10);
 // Confirmed orders already reserved inventory: correcting payment must not allocate again.
 await change(b,'confirmed',1);const afterConfirmed=(await summary()).available_kg;await change(b,'shipped_unpaid',2,randomUUID(),'한진','["33333"]');assert.equal((await summary()).available_kg,afterConfirmed);
 await bad(()=>rpc('select public.farmer_admin_archive_orders($1,false,$2) as result',[JSON.stringify([{order_id:b.id,expected_version:3}]),randomUUID()]),'삭제할 수 없습니다');
 const pickups=await submit([{...d,quantity:1,product_id:'hopungmi-5kg-pickup',postal_code:'',address:''}]);let p=(await list()).orders.find(o=>o.order_number===pickups.orders[0].order_number);const costBeforePickup=await costs();await change(p,'shipped_unpaid',1,randomUUID(),'','');const costAfterPickup=await costs();assert.equal(costAfterPickup.shipping_boxes,costBeforePickup.shipping_boxes);assert.equal(costAfterPickup.pickup_boxes,costBeforePickup.pickup_boxes+1);
 await db.exec('reset role;rollback;');
 console.log('PASS: unpaid shipment state, shared stock exactly once, paid correction, per-box tracking preservation, income exclusion and fulfillment costs, pickup, customer lookup, export, bulk payment, authorization and retry.');
}
