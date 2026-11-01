import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyFiveStages({db,rpc,admin,anon,expectError}) {
 await db.exec('reset role;begin;update public.farmer_inventory set available_grams=1000000;');
 const bad=async(fn,text)=>{await db.exec('savepoint negative_stage');try{await expectError(fn,text);}finally{await db.exec('rollback to savepoint negative_stage;release savepoint negative_stage;');}};
 const summary=()=>rpc('select public.farmer_admin_summary() as result');
 const list=(stage='',kind='')=>rpc('select public.farmer_admin_order_list($1,$2,0,$3) as result',[stage,'다섯단계검증',kind]);
 const change=(o,status,id=randomUUID())=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,status,o.version,id,'한진',JSON.stringify(Array.from({length:o.quantity},(_,i)=>'STAGE-'+i))]);
 await anon();await bad(()=>list('confirmed_waiting_address'),'permission denied');
 const buy=await rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,$8) as result',[randomUUID(),'다섯단계검증','01012345678','보내는이',JSON.stringify([{product_id:'hopungmi-5kg',quantity:2,recipient_label:'주소대기하나',message:''},{product_id:'hopungmi-2kg',quantity:1,recipient_label:'주소대기둘',message:''}]),'',56000,true]);
 await admin();const before=await summary();
 for(const o of (await list('pending')).orders)await change(o,'confirmed');
 const waiting=await list('confirmed_waiting_address'),ready=await list('confirmed_ready');
 assert.equal(waiting.total,2);assert.equal(ready.total,0);assert.ok(waiting.orders.every(o=>o.status==='confirmed'&&o.awaiting_address));
 let s=await summary();assert.equal(s.confirmed_waiting_address-before.confirmed_waiting_address,2);assert.equal(s.confirmed_waiting_address_kg-before.confirmed_waiting_address_kg,12);assert.equal(s.confirmed_waiting_address_boxes-before.confirmed_waiting_address_boxes,3);assert.equal(s.confirmed_waiting_address_5kg_boxes-before.confirmed_waiting_address_5kg_boxes,2);assert.equal(s.confirmed_waiting_address_2kg_boxes-before.confirmed_waiting_address_2kg_boxes,1);
 for(const stage of ['confirmed_waiting_address','confirmed_ready']){const exported=await rpc('select public.farmer_admin_export_orders($1,$2,$3) as result',[stage,'다섯단계검증','sale']);assert.equal(exported.total,(await list(stage,'sale')).total);}
 const unclaimed=waiting.orders.find(o=>o.quantity===2);await bad(()=>change(unclaimed,'shipped'),'배송지');await bad(()=>change(unclaimed,'confirmed_ready'),'변경할 수 없는');
 await bad(()=>change(unclaimed,'shipped_unpaid'),'더 이상 사용하지 않는');
 await bad(()=>rpc('select public.farmer_admin_bulk_status($1,$2) as result',[JSON.stringify([{order_id:unclaimed.id,expected_version:unclaimed.version,request_id:randomUUID()}]),'shipped_unpaid']),'일괄 변경할 수 없는');
 const stock=s.available_kg;await anon();await rpc('select public.farmer_claim_gift($1,$2,$3,$4,$5,$6,$7,$8) as result',[buy.gifts.find(g=>g.quantity===2).token,randomUUID(),'배송지등록완료','01098765432','04524','서울 중구 세종대로 110','101호',true]);
 await admin();s=await summary();assert.equal(s.available_kg,stock);assert.equal((await list('confirmed_waiting_address')).total,1);assert.equal((await list('confirmed_ready')).total,1);assert.equal(s.confirmed_ready-before.confirmed_ready,1);assert.equal(s.confirmed_ready_boxes-before.confirmed_ready_boxes,2);assert.equal(s.confirmed_ready_kg-before.confirmed_ready_kg,10);assert.equal(s.confirmed,s.confirmed_ready+s.confirmed_waiting_address);
 const shippable=(await list('confirmed_ready')).orders[0],request=randomUUID();await change(shippable,'shipped',request);await change(shippable,'shipped',request);assert.equal((await summary()).available_kg,stock);assert.equal((await list('shipped')).total,1);assert.equal((await list('confirmed_ready')).total,0);
 await change((await list('shipped')).orders[0],'delivered');assert.equal((await list('delivered')).total,1);assert.equal((await summary()).available_kg,stock);
 await db.exec('reset role;rollback;');
 console.log('PASS: five disjoint admin stages, waiting/ready filters and exports, box/size/weight totals, claim auto-move without stock changes, address shipping guard, removed unpaid transitions and idempotent shipping.');
}
