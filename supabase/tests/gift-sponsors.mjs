import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyGiftSponsors({db,rpc,admin,anon,expectError}){
 const summary=year=>rpc('select public.farmer_admin_free_gift_summary($1) as result',[year]);
 const data=(sponsor,quantity=1,product_id='hopungmi-5kg')=>({product_id,quantity,gift_sponsor:sponsor,recipient_name:'무상선물검증',recipient_phone:'01012345678',postal_code:'04524',address:'서울 중구 세종대로 110',address_detail:'',memo:''});
 const gift=(items,id=randomUUID())=>rpc('select public.farmer_admin_create_gifts($1,$2) as result',[id,JSON.stringify(items)]);
 await anon();await expectError(()=>summary(2026),'permission denied');await db.exec("reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;");await expectError(()=>summary(2026),'관리자 권한');
 await db.exec('reset role;update public.farmer_inventory set available_grams=3000000;');await admin();await expectError(()=>summary(null),'연도');await expectError(()=>summary(2101),'연도');
 const before=await summary(2026),person=(s,n)=>s.people.find(p=>p.sponsor===n),hong='고구맙습니다홍세환선물용',yoon='고구맙습니다윤가희선물용';
 await expectError(()=>gift([data('다른 사람')]),'선물하는 사람');
 const id=randomUUID(),items=[data('홍세환',2),data('윤가희',3),data('윤가희',2,'hopungmi-2kg')];const saved=await gift(items,id);assert.deepEqual(await gift(items,id),saved);await expectError(()=>gift([data('윤가희',2)],id),'이미 사용');
 let s=await summary(2026);assert.equal(s.totals.qty5,before.totals.qty5+5);assert.equal(s.totals.qty2,before.totals.qty2+2);assert.equal(person(s,'홍세환').qty5,person(before,'홍세환').qty5+2);assert.equal(person(s,'윤가희').qty5,person(before,'윤가희').qty5+3);
 const saveCode=(code,extra={})=>rpc('select public.farmer_admin_discount_save($1,$2,$3) as result',[randomUUID(),JSON.stringify({id:randomUUID(),code,mode:'product_unit',amount:22000,percent:0,product_id:'hopungmi-5kg',usage_limit:null,active:true,...extra}),null]);
 await saveCode(hong);await saveCode(yoon);await saveCode('다른전액할인',{mode:'percent',amount:0,percent:100,product_id:null});
 const buy=(code,qty=1,total=0,id=randomUUID())=>rpc('select public.farmer_submit_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as result',[id,'hopungmi-5kg',qty,code,'무상코드검증','01022224444','서울 중구 세종대로 110','','',total,true]);
 await anon();const buyId=randomUUID(),single=await buy(hong,1,0,buyId);assert.deepEqual(await buy(hong,1,0,buyId),single);await buy(hong,2,22000);await buy('다른전액할인');
 const paid=await rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,$8) as result',[randomUUID(),'유료선물검증','01022224444','홍세환',JSON.stringify([{product_id:'hopungmi-5kg',quantity:2,recipient_label:'친구',message:''}]),'',44000,true]);
 const free=await rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,$8) as result',[randomUUID(),'무상코드검증','01022224444','보내는 분',JSON.stringify([{product_id:'hopungmi-5kg',quantity:1,recipient_label:'친구',message:''}]),yoon,0,true]);
 await admin();s=await summary(2026);assert.equal(s.totals.qty5,before.totals.qty5+8);assert.equal(person(s,'홍세환').qty5,person(before,'홍세환').qty5+4);assert.equal(person(s,'윤가희').qty5,person(before,'윤가희').qty5+4);assert.equal(s.totals.pending_boxes,before.totals.pending_boxes+3);
 const orders=()=>rpc('select public.farmer_admin_order_list($1,$2,$3,$4) as result',['','',0,'']);
 let list=(await orders()).orders;const find=no=>list.find(o=>o.order_number===no),change=(o,status)=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,status,o.version,randomUUID(),'우체국택배','123']);
 const stock=(await rpc('select public.farmer_admin_summary() as result')).available_kg;await summary(2026);assert.equal((await rpc('select public.farmer_admin_summary() as result')).available_kg,stock,'Read-only counts must not change inventory');
 let order=find(single.order_number);await change(order,'confirmed');list=(await orders()).orders;order=find(single.order_number);await change(order,'shipped');list=(await orders()).orders;order=find(single.order_number);await change(order,'delivered');assert.equal((await summary(2026)).totals.qty5,s.totals.qty5,'Fulfillment counted twice');
 list=(await orders()).orders;await change(find(free.gifts[0].order_number),'confirmed');await anon();await rpc('select public.farmer_claim_gift($1,$2,$3,$4,$5,$6,$7,$8) as result',[free.gifts[0].token,randomUUID(),'친구','01012345678','04524','서울 중구 세종대로 110','',true]);await admin();assert.equal((await summary(2026)).totals.qty5,s.totals.qty5,'Link claim counted twice');
 list=(await orders()).orders;let manual=find(saved.orders[0].order_number);assert.equal(manual.gift_sponsor,'홍세환');await change(manual,'cancelled');assert.equal((await summary(2026)).totals.qty5,s.totals.qty5-2);
 list=(await orders()).orders;const g=find(saved.orders[1].order_number);await rpc('select public.farmer_admin_archive_orders($1,$2,$3) as result',[JSON.stringify([{order_id:g.id,expected_version:g.version}]),false,randomUUID()]);assert.equal((await summary(2026)).totals.qty5,s.totals.qty5-5);
 // Korea registration-year boundary; existing ambiguous gifts stay unassigned.
 await db.exec("reset role;");const target=find(paid.gifts[0].order_number);assert.ok(target);
 const moved=find(saved.orders[2].order_number);await db.query("update public.farmer_orders set created_at='2025-12-31 14:59:59+00' where id=$1",[moved.id]);await admin();assert.equal(person(await summary(2025),'윤가희').qty2,2);
 const exported=await rpc('select public.farmer_admin_export_orders($1,$2,$3) as result',['deleted','','']);assert.equal(exported.orders.find(o=>o.id===g.id).gift_sponsor,'윤가희');
 console.log('PASS: explicit gift sponsors, zero-unit coupon counts, paid customer gift exclusion, partial-cart free-unit allocation, exact retries, status/claim deduplication, cancellation/archive exclusion, private read-only totals and Korea year boundary.');
}
