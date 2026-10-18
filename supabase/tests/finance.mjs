import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyFinance({db,rpc,admin,anon,expectError}) {
 const report=(year=2042,kind='',search='',offset=0)=>rpc('select public.farmer_admin_finance_report($1,$2,$3,$4) as result',[year,kind,search,offset]);
 const save=(request,entry,version=null)=>rpc('select public.farmer_admin_finance_save($1,$2,$3) as result',[request,JSON.stringify(entry),version]);
 const remove=(id,version,request)=>rpc('select public.farmer_admin_finance_delete($1,$2,$3) as result',[id,version,request]);
 const e={id:randomUUID(),occurred_on:'2042-04-24',direction:'expense',category:'검증 농자재',title:'검증 자재',counterparty:'검증 거래처',note:'<img src=x onerror=alert(1)>',amount:5100,quantity:3,unit_price:1700};
 const req=randomUUID();
 await anon();
 await expectError(()=>report(),'permission denied');await expectError(()=>save(req,e),'permission denied');await expectError(()=>remove(e.id,1,randomUUID()),'permission denied');
 await expectError(()=>db.query('select * from farmer_private.finance_entries'),'permission denied');
 await db.exec(`reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;`);
 await expectError(()=>report(),'관리자 권한');await expectError(()=>save(req,e),'관리자 권한');await expectError(()=>remove(e.id,1,randomUUID()),'관리자 권한');
 await admin();
 const initial=await report();assert.equal(initial.summary.profit,0);assert.equal(initial.months.length,12);
 const receipt=await save(req,e);assert.equal(receipt.version,1);assert.deepEqual(await save(req,e),receipt);
 await expectError(()=>save(req,{...e,title:'changed'}),'이미 사용');
 const expense2={...e,id:randomUUID(),occurred_on:'2042-05-01',title:'검증 작업비',amount:4900,quantity:null,unit_price:null};
 await save(randomUUID(),expense2);
 const income={...e,id:randomUUID(),occurred_on:'2042-06-02',direction:'income',category:'현장 판매',title:'별도 수입',amount:2500,quantity:null,unit_price:null};
 await save(randomUUID(),income);
 let data=await report();assert.equal(data.total,3);assert.equal(data.summary.expense,10000);assert.equal(data.summary.manual_income,2500);assert.equal(data.summary.profit,-7500);
 assert.equal(data.months[3].expense,5100);assert.equal(data.months[4].expense,4900);assert.equal(data.months[5].income,2500);assert.equal(data.categories[0].amount,10000);
 assert.equal((await report(2042,'expense','거래처')).total,2);assert.equal((await report(2042,'income')).total,1);assert.equal((await report(2043)).total,0);
 assert.equal((await report(2042,'expense')).summary.manual_income,2500,'list filter must not change whole-year totals');
 for(const patch of [{amount:-1},{amount:0},{amount:5101},{quantity:0},{quantity:null},{unit_price:null},{occurred_on:'2042-02-30'},{occurred_on:'1999-12-31'},{direction:'invalid'},{title:''},{category:''}]) {
   await assert.rejects(()=>save(randomUUID(),{...e,id:randomUUID(),...patch}));
 }
 assert.equal((await report()).total,3);
 const editRequest=randomUUID(),edited={...e,amount:6000,unit_price:2000};
 const edit=await save(editRequest,edited,1);assert.equal(edit.version,2);assert.deepEqual(await save(editRequest,edited,1),edit);
 await expectError(()=>save(randomUUID(),edited,1),'다른 화면');
 await save(randomUUID(),{...edited,amount:6300,unit_price:2100},2);
 assert.deepEqual(await save(editRequest,edited,1),edit);assert.equal((await report()).summary.expense,11200);
 const deletion=randomUUID();const deleted=await remove(expense2.id,1,deletion);assert.equal(deleted.deleted,true);assert.deepEqual(await remove(expense2.id,1,deletion),deleted);
 assert.equal((await report()).summary.expense,6300);await expectError(()=>save(randomUUID(),expense2,1),'다른 화면');
 await expectError(()=>remove(e.id,1,randomUUID()),'다른 화면');
 await expectError(()=>report(1999),'조회 조건');await expectError(()=>report(2042,'invalid'),'조회 조건');await expectError(()=>report(2042,'','',-1),'조회 조건');
 // Real checkout/status functions create synthetic sales; Korea-local confirmation dates determine revenue year.
 await db.exec('reset role;update public.farmer_inventory set available_grams=100000;');
 const orders=[];
 for(const status of ['pending','confirmed','shipped','delivered','cancelled']){
  await anon();const order=await rpc('select public.farmer_submit_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) as result',[randomUUID(),'hopungmi-5kg',1,'','매출 검증','01055556666','검증 주소 123','','',22000,true]);
  await admin();const row=(await rpc('select public.farmer_admin_orders($1,$2,$3) as result',['',order.order_number,0])).orders[0];
  const change=(state,version)=>rpc('select public.farmer_admin_change_status($1,$2,$3,$4,$5,$6) as result',[row.id,state,version,randomUUID(),'검증 배송','']);
  if(status!=='pending')await change('confirmed',1);
  if(status==='shipped'||status==='delivered')await change('shipped',2);
  if(status==='delivered')await change('delivered',3);
  if(status==='cancelled')await change('cancelled',2);
  await db.exec('reset role;');
  await db.query("update public.farmer_orders set created_at='2041-12-30T12:00:00Z',confirmed_at='2041-12-31T15:10:00Z' where id=$1",[row.id]);
  if(status==='pending')await db.query("update public.farmer_orders set created_at='2042-01-01T00:00:00Z',confirmed_at=null where id=$1",[row.id]);
  orders.push(row.id);
 }
 await admin();const gift=await rpc('select public.farmer_admin_create_gifts($1,$2) as result',[randomUUID(),JSON.stringify([{product_id:'hopungmi-2kg',quantity:1,recipient_name:'검증 선물',recipient_phone:'01055556666',postal_code:'04524',address:'검증 주소 123',address_detail:'',memo:''}])]);
 await db.exec('reset role;');await db.query("update public.farmer_orders set confirmed_at='2042-01-01T00:00:00Z' where order_kind='gift' and order_no=substring($1 from 4)::bigint",[gift.orders[0].order_number]);await admin();
 data=await report();assert.equal(data.summary.order_income,66000);assert.equal(data.summary.order_count,3);assert.equal(data.summary.sold_kg,15);assert.equal(data.summary.pending_income,22000);
 assert.equal(data.summary.profit,62200);assert.equal(data.entries.filter(e=>e.source==='order').length,3);assert.equal(data.months[0].income,66000);
 assert.ok(data.entries.every(e=>!('phone' in e)&&!('address' in e)));
 assert.equal((await report(2041)).summary.order_income,0,'use confirmation year, not order creation year');
 // Pagination must cover all rows without truncating annual totals.
 for(let i=0;i<51;i++)await save(randomUUID(),{...income,id:randomUUID(),title:'페이지 검증 '+i,amount:10});
 const first=await report(),second=await report(2042,'','',50);assert.equal(first.entries.length,50);assert.equal(second.entries.length,6);assert.equal(first.total,56);
 assert.equal(new Set([...first.entries,...second.entries].map(e=>e.source+e.id)).size,56);assert.equal(first.summary.manual_income,3010);
 await expectError(()=>db.query('select * from farmer_private.finance_requests'),'permission denied');
 console.log('PASS: private finance access, dates/quantities, arithmetic, edits/deletions, stale protection, retry safety, paid-sales recognition, Korea year boundary, gift/pending/cancel exclusion, full-year totals and pagination.');
}
