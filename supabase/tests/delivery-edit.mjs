import assert from 'node:assert/strict';
export async function verifyDeliveryEdit({db,rpc,admin,anon,expectError}) {
 const id=n=>`d0000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
 const delivery={recipient_name:'수정 받는분',recipient_phone:'010-9876-5432',postal_code:'04524',address:'서울 중구 세종대로 110',address_detail:'101호',memo:'문 앞에 놓아 주세요 <script>',carrier:'우체국택배',tracking_number:'TRACK-EDIT'};
 const edit=(order,request=id(2),data=delivery,version=order.version)=>rpc('select public.farmer_admin_update_delivery($1,$2,$3,$4) as result',[order.id,version,request,JSON.stringify(data)]);
 await anon();await expectError(()=>edit({id:id(1),version:1}),'permission denied');
 await rpc('select public.farmer_submit_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as result',[id(1),'hopungmi-5kg',1,'','배송수정검증','01011113333','서울 중구 기존주소 123','','',22000,true]);
 await db.exec("reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;");await expectError(()=>edit({id:id(1),version:1}),'관리자 권한');
 await admin();const list=()=>rpc('select public.farmer_admin_order_list($1,$2,$3,$4) as result',['','배송수정검증',0,'']);let order=(await list()).orders[0];assert.ok(order);
 const snapshot=async()=>{await db.exec('reset role;');return(await db.query('select to_jsonb(o) as data from public.farmer_orders o where id=$1',[order.id])).rows[0].data;};
 const stock=async()=>Number((await rpc('select public.farmer_admin_summary() as result')).available_kg);
 const before=await snapshot();await admin();const beforeStock=await stock();
 for(const [patch,error] of [[{recipient_phone:'bad'},'받는 분'],[{postal_code:'abc'},'우편번호'],[{total:'0'},'수정할 수 없는'],[{address:'짧음'},'우편번호'],[{memo:'x'.repeat(301)},'배송 정보']])await expectError(()=>edit(order,id(30),{...delivery,...patch}),error);
 const saved=await edit(order);assert.equal(saved.saved,true);assert.equal(saved.version,2);assert.deepEqual(await edit(order),saved);
 await expectError(()=>edit(order,id(2),{...delivery,memo:'바꿈'}),'이미 사용');await expectError(()=>edit(order,id(3)),'다른 화면');
 const after=await snapshot();assert.equal(after.recipient_phone,'01098765432');assert.equal(after.memo,delivery.memo);assert.equal(after.postal_code,'04524');
 for(const key of Object.keys(before).filter(k=>!Object.keys(delivery).includes(k)&&!['version','updated_at'].includes(k)))assert.deepEqual(after[key],before[key],key+' unexpectedly changed');
 await admin();assert.equal(await stock(),beforeStock);order=(await list()).orders[0];
 await edit(order,id(4),{...delivery,memo:'두 번째 수정'});assert.deepEqual(await edit({...order,version:1},id(2)),saved);let latest=(await list()).orders[0];assert.equal(latest.memo,'두 번째 수정');assert.equal(latest.version,3);
 const status=(o,state,n)=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,state,o.version,id(n),'우체국택배','TRACK']);
 await status(latest,'confirmed',5);latest=(await list()).orders[0];await status(latest,'shipped',6);latest=(await list()).orders[0];const shippedStock=await stock();
 await expectError(()=>edit(latest,id(7),{...delivery,carrier:''}),'택배사');await edit(latest,id(8),{...delivery,tracking_number:'CORRECTED'});latest=(await list()).orders[0];assert.equal(latest.status,'shipped');assert.equal(latest.tracking_number,'CORRECTED');assert.equal(await stock(),shippedStock);
 // Pickup remains pickup, without demanding a postal address or changing its location.
 await anon();const p=await rpc('select public.farmer_submit_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as result',[id(9),'hopungmi-5kg-pickup',1,'','배송수정검증 수령','01011113333','','','',18000,true]);
 await admin();const po=(await list()).orders.find(o=>o.order_number===p.order_number);await edit(po,id(10),{...delivery,postal_code:'',address:'',address_detail:'',memo:'오후 방문'});const pickup=(await list()).orders.find(o=>o.id===po.id);assert.equal(pickup.product_id,'hopungmi-5kg-pickup');assert.equal(pickup.address,po.address);assert.equal(pickup.carrier,po.carrier);assert.equal(pickup.total,18000);
 // Manual registration of an unclaimed gift requires payment confirmation.
 await anon();const gift=await rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,$8) as result',[id(11),'배송수정검증 선물','01011113333','보내는이',JSON.stringify([{product_id:'hopungmi-5kg',quantity:1,recipient_label:'친구',message:'고마워요'}]),'',22000,true]);
 await admin();let go=(await list()).orders.find(o=>o.order_number===gift.gifts[0].order_number);await expectError(()=>edit(go,id(12)),'입금 확인 후');await status(go,'confirmed',13);go=(await list()).orders.find(o=>o.id===go.id);const gs=await stock();await edit(go,id(14));go=(await list()).orders.find(o=>o.id===go.id);assert.equal(go.awaiting_address,false);assert.equal(await stock(),gs);await status(go,'shipped',15);
 await anon();assert.equal((await rpc('select public.farmer_gift_view($1) as result',[gift.gifts[0].token])).state,'claimed');await expectError(()=>rpc('select public.farmer_claim_gift($1,$2,$3,$4,$5,$6,$7,$8) as result',[gift.gifts[0].token,id(16),'다른 사람','01011112222','04524','서울 중구 다른 주소','','true']),'이미 배송지');await expectError(()=>db.query('select * from farmer_private.delivery_edit_requests'),'permission denied');
 console.log('PASS: admin delivery edits, authorization, validation, exact retries, stale protection, unchanged money/status/stock, tracking corrections, pickup invariants and paid gift manual registration.');
}
