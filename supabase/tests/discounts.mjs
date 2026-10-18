import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyDiscounts({db,rpc,admin,anon,expectError}){
 const list=(search='',status='',offset=0)=>rpc('select public.farmer_admin_discount_list($1,$2,$3) as result',[search,status,offset]);
 const save=(e,v=null,id=randomUUID())=>rpc('select public.farmer_admin_discount_save($1,$2,$3) as result',[id,JSON.stringify(e),v]);
 const del=(id,v,r=randomUUID())=>rpc('select public.farmer_admin_discount_delete($1,$2,$3) as result',[id,v,r]);
 const history=(id,offset=0)=>rpc('select public.farmer_admin_discount_history($1,$2) as result',[id,offset]);
 const entry=(code,extra={})=>({id:randomUUID(),code,mode:'fixed',amount:2000,percent:0,product_id:null,usage_limit:null,active:true,...extra});
 const delivery=(product_id='hopungmi-5kg',quantity=1)=>({product_id,quantity,recipient_name:'검증',recipient_phone:'01012345678',postal_code:'12345',address:'테스트 배송 주소',address_detail:'',memo:''});
 const quote=(ds,code)=>rpc('select public.farmer_quote_batch($1,$2) as result',[JSON.stringify(ds),code]);
 const submit=(id,ds,code,total)=>rpc('select public.farmer_submit_batch($1,$2,$3,$4,$5,$6,$7) as result',[id,'쿠폰 검증','01055556666',JSON.stringify(ds),code,total,true]);
 await anon();await expectError(()=>list(),'permission denied');await expectError(()=>save(entry('DENIED')),'permission denied');await expectError(()=>history(randomUUID()),'permission denied');await expectError(()=>del(randomUUID(),1),'permission denied');
 await db.exec("reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;");
 await expectError(()=>list(),'관리자 권한');await expectError(()=>save(entry('DENIED')),'관리자 권한');await expectError(()=>del(randomUUID(),1),'관리자 권한');await expectError(()=>history(randomUUID()),'관리자 권한');
 await db.exec('reset role;update public.farmer_inventory set available_grams=3000000;');await admin();
 const fixed=entry('정액 검증'),one=entry('한번 검증',{mode:'product_unit',amount:22000,product_id:'hopungmi-5kg',usage_limit:1});
 const rid=randomUUID();const saved=await save(fixed,null,rid);assert.deepEqual(await save(fixed,null,rid),saved);
 await expectError(()=>save({...fixed,amount:3000},null,rid),'이미 사용');await save(one);
 await expectError(()=>save(entry('  정액 검증  ')),'이미 등록');
 await expectError(()=>save(entry('금액오류',{amount:0})),'할인 금액');await expectError(()=>save(entry('수량오류',{usage_limit:0})),'발급 수량');
 await expectError(()=>save(entry('상품오류',{mode:'product_unit',product_id:'none'})),'대상 상품');
 await expectError(()=>save({...fixed,amount:4000},9),'다른 화면');
 await anon();
 const ds=[delivery('hopungmi-2kg',1),delivery('hopungmi-5kg',3)];
 let q=await quote(ds,fixed.code);assert.equal(q.discount_amount,2000);assert.equal(q.total,76000);assert.deepEqual(q.deliveries.map(d=>d.discount_amount),[2000,0]);
 q=await quote(ds,one.code);assert.equal(q.discount_amount,22000);assert.equal(q.total,56000);assert.deepEqual(q.deliveries.map(d=>d.discount_amount),[0,22000]);
 await expectError(()=>quote([delivery('hopungmi-2kg')],one.code),'指定'.replace('指定','지정'));
 const bid=randomUUID();await expectError(()=>submit(bid,[ds[0],{...ds[1],postal_code:''}],one.code,q.total),'우편번호');
 assert.equal((await quote(ds,one.code)).discount_amount,22000); // Failed checkout consumes nothing.
 await expectError(()=>submit(bid,ds,one.code,1),'판매 금액');
 const receipt=await submit(bid,ds,one.code,q.total);assert.deepEqual(await submit(bid,ds,one.code,q.total),receipt);
 await expectError(()=>quote(ds,one.code),'소진');await expectError(()=>submit(randomUUID(),ds,one.code,q.total),'소진');
 await admin();let item=(await list(one.code)).codes[0];assert.equal(item.used_count,1);assert.equal(item.status,'exhausted');
 let h=await history(one.id);assert.equal(h.total,1);assert.equal(h.entries[0].orders.length,2);assert.equal(h.entries[0].discount_amount,22000);assert.equal(h.entries[0].released,false);
 for(const o of h.entries[0].orders)for(const key of ['phone','address','customer_name','recipient_name'])assert.equal(o[key],undefined);
 let rows=(await db.query('reset role;')).rows;
 rows=(await db.query('select id,version from public.farmer_orders where batch_id=$1 order by delivery_index',[bid])).rows;await admin();
 const cancel=o=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4) as result',[o.id,'cancelled',o.version,randomUUID()]);
 await cancel(rows[0]);assert.equal((await list(one.code)).codes[0].used_count,1);
 await cancel(rows[1]);assert.equal((await list(one.code)).codes[0].used_count,0);assert.equal((await history(one.id)).entries[0].released,true);
 await anon();const reused=await submit(randomUUID(),ds,one.code,q.total);assert.equal(reused.orders.length,2);
 // Disabled/deleted/renamed definitions never change saved receipts or usage identity.
 await admin();await save({...one,active:false},1);await anon();await expectError(()=>quote(ds,one.code),'사용할 수 없는');assert.deepEqual(await submit(bid,ds,one.code,q.total),receipt);
 await admin();await save({...one,code:'변경한 코드',active:true,usage_limit:2},2);
 assert.equal((await list('변경한 코드')).codes[0].used_count,1);
 await anon();await expectError(()=>quote(ds,one.code),'사용할 수 없는');await submit(randomUUID(),ds,'변경한 코드',q.total);
 await admin();await expectError(()=>save({...one,code:'변경한 코드',usage_limit:1},3),'이미 사용');
 const deleteId=randomUUID(),deleted=await del(one.id,3,deleteId);assert.deepEqual(await del(one.id,3,deleteId),deleted);assert.equal((await list('변경한 코드')).total,0);assert.equal((await list('변경한 코드','deleted')).total,1);assert.equal((await history(one.id)).total,3);
 await anon();await expectError(()=>quote(ds,'변경한 코드'),'사용할 수 없는');
 // Single-destination legacy API must also consume the shared code limit.
 await admin();const single=entry('단일',{usage_limit:1});await save(single);
 await anon();const sid=randomUUID(),args=[sid,'hopungmi-5kg',1,single.code,'단일 주문','01011112222','테스트 주소 123','','',20000,true];
 const legacy=()=>rpc('select public.farmer_submit_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as result',args);
 const lr=await legacy();assert.deepEqual(await legacy(),lr);await expectError(()=>quote(ds,single.code),'소진');
 // Fixed amount spans lines, but is applied once across the checkout.
 await admin();const spread=entry('분배',{amount:20000});await save(spread);await anon();const small=[delivery('hopungmi-2kg'),delivery('hopungmi-2kg')];
 q=await quote(small,spread.code);assert.deepEqual(q.deliveries.map(d=>d.discount_amount),[12000,8000]);assert.equal(q.total,4000);await submit(randomUUID(),small,spread.code,4000);
 await admin();assert.equal((await list('분배')).codes[0].used_count,1);
 // Unicode normalization and stable pagination.
 const ascii=entry('ＡＢＣ');await save(ascii);await anon();assert.equal((await quote(ds,'abc')).discount_amount,2000);await admin();await expectError(()=>save(entry('ABC')),'이미 등록');
 for(let i=0;i<27;i++)await save(entry('페이지'+i));
 const a=await list('페이지'),b=await list('페이지','',25);assert.equal(a.total,27);assert.equal(a.codes.length,25);assert.equal(b.codes.length,2);assert.equal(new Set([...a.codes,...b.codes].map(c=>c.id)).size,27);
 await anon();await expectError(()=>db.query('select * from farmer_private.discount_usage'),'permission denied');await expectError(()=>db.query('select * from farmer_private.discount_codes'),'permission denied');await expectError(()=>db.query('select * from farmer_private.discount_requests'),'permission denied');
 await db.exec("reset role;update auth.users set email_confirmed_at=null where id='00000000-0000-0000-0000-000000000001';");await admin();await expectError(()=>list(),'관리자 권한');await expectError(()=>save(entry('DENIED')),'관리자 권한');
 await db.exec("reset role;update auth.users set email_confirmed_at=now() where id='00000000-0000-0000-0000-000000000001';");
 console.log('PASS: private coupon CRUD, versions/retries, Korean/normalized names, one discount per checkout, product-unit cap, limits across both submit APIs, rollback, cancellation release, rename/delete history and pagination.');
}
