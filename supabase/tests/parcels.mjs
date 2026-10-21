import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyParcels({db,rpc,admin,anon,expectError}){
 const base={product_id:'hopungmi-5kg',quantity:4,gift_sponsor:'윤가희',recipient_name:'상자별 송장 검증',recipient_phone:'01012345678',postal_code:'04524',address:'서울 중구 세종대로 110',address_detail:'101호',memo:'문 앞'};
 await db.exec('reset role;update public.farmer_inventory set available_grams=1000000;');await admin();
 const saved=await rpc('select public.farmer_admin_create_gifts($1,$2) as result',[randomUUID(),JSON.stringify([base])]);
 const list=()=>rpc('select public.farmer_admin_order_list($1,$2,$3,$4) as result',['','상자별 송장 검증',0,'gift']);
 let order=(await list()).orders.find(o=>o.order_number===saved.orders[0].order_number);assert.deepEqual(order.tracking_numbers,[]);
 const stock=async()=>Number((await rpc('select public.farmer_admin_summary() as result')).available_kg),before=await stock();
 const body={recipient_name:base.recipient_name,recipient_phone:base.recipient_phone,postal_code:base.postal_code,address:base.address,address_detail:base.address_detail,memo:base.memo,carrier:'우체국택배',tracking_number:JSON.stringify(['001111','','003333','004444'])};
 const edit=(d,id=randomUUID(),version=order.version)=>rpc('select public.farmer_admin_update_delivery($1,$2,$3,$4) as result',[order.id,version,id,JSON.stringify(d)]);
 await anon();await expectError(()=>edit(body),'permission denied');await expectError(()=>db.query("select farmer_private.parcel_tracking_numbers('[]',4)"),'permission denied');await admin();
 const req=randomUUID();let receipt=await edit(body,req);assert.equal(receipt.saved,true);assert.deepEqual(await edit(body,req),receipt);
 await expectError(()=>edit({...body,tracking_number:'["CHANGED"]'},req),'이미 사용');
 order=(await list()).orders.find(o=>o.id===order.id);assert.deepEqual(order.tracking_numbers,['001111','','003333','004444']);assert.equal(order.tracking_number,'001111');
 await expectError(()=>edit({...body,tracking_number:'["1","2","3","4","5"]'}),'상자 수');
 await expectError(()=>edit({...body,tracking_number:'["DUP","DUP"]'}),'중복');
 await expectError(()=>edit({...body,tracking_number:'[1]'}),'상자 수');
 await expectError(()=>edit({...body,tracking_number:JSON.stringify(['a'.repeat(101)])}),'100자');
 const legacy={...body,tracking_number:'001111',memo:'구버전에서도 송장 보존'};await edit(legacy);order=(await list()).orders.find(o=>o.id===order.id);assert.deepEqual(order.tracking_numbers,['001111','','003333','004444']);
 const numbers=['001111','002222','003333','004444'],payload={p_orders:[{order_id:order.id,expected_version:order.version,request_id:randomUUID(),carrier:'우체국택배',tracking_number:JSON.stringify(numbers)}],p_status:'shipped'};
 const bulk=()=>rpc('select public.farmer_admin_bulk_status($1,$2) as result',[JSON.stringify(payload.p_orders),payload.p_status]);await bulk();await bulk();
 order=(await list()).orders.find(o=>o.id===order.id);assert.equal(order.status,'shipped');assert.deepEqual(order.tracking_numbers,numbers);assert.equal(await stock(),before,'parcel records must not deduct stock again');
 payload.p_orders[0].tracking_number='["CHANGED"]';await expectError(bulk,'이미 사용');
 const exported=await rpc('select public.farmer_admin_export_orders($1,$2,$3) as result',['','상자별 송장 검증','gift']);const e=exported.orders.find(o=>o.id===order.id);assert.equal(e.quantity,4);assert.deepEqual(e.tracking_numbers,numbers);
 const done=await rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[order.id,'delivered',order.version,randomUUID(),'','']);assert.equal(done.status,'delivered');
 order=(await list()).orders.find(o=>o.id===order.id);assert.deepEqual(order.tracking_numbers,numbers);
 console.log('PASS: four parcel slots per order, partial/leading-zero numbers, legacy edits, atomic bulk shipping, retries, duplicate/count/length validation, export preservation and unchanged stock.');
}
