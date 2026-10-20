import assert from 'node:assert/strict';
export async function verifyOrderTools({db,rpc,admin,anon,expectError}){
 const id=n=>`e0000000-0000-4000-8000-${String(n).padStart(12,'0')}`,list=(status='',search='정리검증',kind='')=>rpc('select public.farmer_admin_order_list($1,$2,0,$3) as result',[status,search,kind]);
 const archive=(orders,restore=false,req=id(101))=>rpc('select public.farmer_admin_archive_orders($1,$2,$3) as result',[JSON.stringify(orders.map(o=>({order_id:o.id,expected_version:o.version}))),restore,req]);
 const stock=async()=>Number((await rpc('select public.farmer_admin_summary() as result')).available_kg),change=(o,status,n)=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[o.id,status,o.version,id(n),'우체국택배','012345678901']);
 const exp=(s='',search='정리검증',kind='')=>rpc('select public.farmer_admin_export_orders($1,$2,$3) as result',[s,search,kind]);
 await anon();await expectError(()=>archive([]),'permission denied');await expectError(()=>exp(),'permission denied');
 for(let i=1;i<=3;i++)await rpc('select public.farmer_submit_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as result',[id(i),'hopungmi-5kg',1,'','정리검증','01033335555','서울 중구 세종대로 110','','',22000,true]);
 await db.exec("reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;");await expectError(()=>archive([]),'관리자 권한');await expectError(()=>exp(),'관리자 권한');
 await admin();let orders=(await list()).orders;const pending=orders[0],confirmed=orders[1],shipped=orders[2];
 await change(confirmed,'confirmed',11);await change(shipped,'confirmed',12);let sh=(await list()).orders.find(o=>o.id===shipped.id);await change(sh,'shipped',13);
 orders=(await list()).orders;const current=orders.find(o=>o.id===confirmed.id),before=await stock();
 await expectError(()=>archive([pending,{...current,version:0}],false,id(90)),'다른 화면');assert.equal((await list()).total,3);assert.equal(await stock(),before);
 await expectError(()=>archive([pending,orders.find(o=>o.id===shipped.id)],false,id(91)),'삭제할 수 없습니다');assert.equal((await list()).total,3);assert.equal(await stock(),before);
 const payload=[pending,current],r=await archive(payload);assert.equal(r.count,2);assert.equal(r.returned_kg,5);assert.deepEqual(await archive(payload),r);assert.equal(await stock(),before+5);
 await expectError(()=>archive([pending],false,id(101)),'이미 사용');assert.equal((await list()).total,1);
 const deleted=(await list('deleted')).orders;assert.equal(deleted.length,2);assert.ok(deleted.every(o=>o.deleted_at&&o.status==='cancelled'));
 const exported=await exp();assert.equal(exported.total,1);assert.equal(exported.orders[0].id,shipped.id);assert.equal((await exp('deleted')).total,2);assert.equal((await exp('','정리검증','gift')).total,0);
 for(const o of [...exported.orders,...(await exp('deleted')).orders])for(const key of ['token','request_fingerprint','privacy_consented_at','created_by'])assert.equal(o[key],undefined);
 await anon();const lookup=await rpc('select public.farmer_lookup_orders($1,$2) as result',['정리검증','01033335555']);assert.equal(lookup.total_count,1);
 await admin();let delivered=(await list()).orders.find(o=>o.id===shipped.id);await change(delivered,'delivered',14);delivered=(await list()).orders.find(o=>o.id===shipped.id);await expectError(()=>archive([delivered],false,id(92)),'삭제할 수 없습니다');const oldStock=await stock();await archive(deleted,true,id(102));assert.equal((await list()).total,3);assert.equal((await list('deleted')).total,0);assert.equal(await stock(),oldStock);assert.deepEqual(await archive(payload),r);assert.equal((await list()).total,3,'Old retry must not re-archive restored orders');
 const cancelled=(await list()).orders.find(o=>o.id===pending.id);await archive([cancelled],false,id(103));assert.equal(await stock(),oldStock);
 // Paid gift links are disabled by cancellation; histories stay linked to stock events.
 await anon();const gift=await rpc('select public.farmer_buy_gifts($1,$2,$3,$4,$5,$6,$7,$8) as result',[id(20),'정리검증 선물','01033335555','보내는 분',JSON.stringify([{product_id:'hopungmi-5kg',quantity:1,recipient_label:'친구',message:'고마워요'}]),'',22000,true]);
 await admin();let go=(await list()).orders.find(o=>o.order_number===gift.gifts[0].order_number);await change(go,'confirmed',21);go=(await list()).orders.find(o=>o.id===go.id);const gs=await stock();await archive([go],false,id(104));assert.equal(await stock(),gs+5);assert.ok(!(await rpc('select public.farmer_admin_gift_links() as result')).gifts.some(o=>o.id===go.id));
 await anon();assert.equal((await rpc('select public.farmer_lookup_gifts($1,$2) as result',['정리검증 선물','01033335555'])).found,false);assert.equal((await rpc('select public.farmer_gift_view($1) as result',[gift.gifts[0].token])).state,'cancelled');
 await expectError(()=>db.query('select * from farmer_private.order_archive_requests'),'permission denied');await expectError(()=>db.query('select * from farmer_private.admin_order_rows'),'permission denied');
 await admin();await expectError(()=>archive([cancelled,cancelled],false,id(105)),'선택 정보');
 // Export includes all matching rows, beyond the 50-row list page.
 await db.exec(`reset role;insert into public.farmer_orders(request_id,request_fingerprint,product_id,product_name,quantity,weight_grams,unit_price,subtotal,total,customer_name,phone,address) select gen_random_uuid(),'fixture','hopungmi-2kg','호풍미 2kg',1,2000,12000,12000,12000,'내보내기검증','01000001111','서울 중구 세종대로 110' from generate_series(1,53);`);
 await admin();assert.equal((await list('','내보내기검증')).orders.length,50);assert.equal((await exp('','내보내기검증')).total,53);
 console.log('PASS: safe archive/restore, stock exactly once, atomic rollback, shipped guard, authorization, gift invalidation, masked lookups and complete filtered exports beyond one page.');
}
