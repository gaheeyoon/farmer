import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyGiftPickup({db,rpc,admin,anon,expectError}){
 const pickup={product_id:'hopungmi-5kg-pickup',quantity:2,gift_sponsor:'홍세환',recipient_name:'방문선물검증',recipient_phone:'01012345678',memo:'오후 방문'};
 const shipping={product_id:'hopungmi-2kg',quantity:1,gift_sponsor:'윤가희',recipient_name:'방문선물검증 택배',recipient_phone:'01012345678',postal_code:'04524',address:'서울 중구 세종대로 110',address_detail:'101호',memo:'문 앞'};
 const create=(ds,id=randomUUID())=>rpc('select public.farmer_admin_create_gifts($1,$2) as result',[id,JSON.stringify(ds)]);
 await anon();await expectError(()=>create([pickup]),'permission denied');await admin();
 const stock=async()=>Number((await rpc('select public.farmer_admin_summary() as result')).available_kg),stats=()=>rpc('select public.farmer_admin_free_gift_summary(2026) as result');
 const before=await stock(),counts=await stats();
 await expectError(()=>create([pickup,{...shipping,postal_code:''}]),'우편번호');assert.equal(await stock(),before);
 await expectError(()=>create([{...pickup,recipient_phone:''}]),'연락처');
 await expectError(()=>create([{...pickup,memo:'x'.repeat(301)}]),'배송 정보');
 const id=randomUUID(),items=[{...pickup,address:'임의의 장소',address_detail:'무시할 상세',postal_code:'wrong'},shipping];const saved=await create(items,id);assert.equal(saved.weight_grams,12000);assert.deepEqual(await create(items,id),saved);assert.equal(await stock(),before-12);
 const list=()=>rpc('select public.farmer_admin_order_list($1,$2,$3,$4) as result',['','방문선물검증',0,'gift']);let orders=(await list()).orders;
 let p=orders.find(o=>o.product_id===pickup.product_id),s=orders.find(o=>o.product_id===shipping.product_id);assert.ok(p&&s);assert.equal(p.address,'원북면 원이로 804-59');assert.equal(p.address_detail,'홍세환 소셜라운지');assert.equal(p.postal_code,'');assert.equal(p.total,0);assert.equal(p.subtotal,0);assert.equal(p.shipping_fee,0);assert.equal(p.fulfillment_method,'pickup');assert.equal(p.gift_sponsor,'홍세환');assert.equal(p.memo,'오후 방문');assert.equal(s.postal_code,'04524');assert.equal(s.address,shipping.address);
 const after=await stats();assert.equal(after.totals.qty5,counts.totals.qty5+2);assert.equal(after.people.find(o=>o.sponsor==='홍세환').qty5,counts.people.find(o=>o.sponsor==='홍세환').qty5+2);
 const change=(o,status)=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,status,o.version,randomUUID(),'','']);
 await change(p,'shipped');p=(await list()).orders.find(o=>o.id===p.id);assert.equal(p.carrier,'방문 수령');await change(p,'delivered');assert.equal(await stock(),before-12);assert.equal((await stats()).totals.qty5,after.totals.qty5);
 const next=await create([{...pickup,quantity:1}]);p=(await list()).orders.find(o=>o.order_number===next.orders[0].order_number);const allocated=await stock();await change(p,'shipped');p=(await list()).orders.find(o=>o.id===p.id);await change(p,'cancelled');assert.equal(await stock(),allocated+5);assert.equal((await stats()).totals.qty5,after.totals.qty5);
 const exported=await rpc('select public.farmer_admin_export_orders($1,$2,$3) as result',['','방문선물검증','gift']);assert.ok(exported.orders.some(o=>o.fulfillment_method==='pickup'&&o.total===0));
 console.log('PASS: free pickup gifts, canonical address without postcode, mixed-shipping atomic validation, zero payment, sponsor 5kg totals, exact replay, shared inventory and pickup handover/cancellation.');
}
