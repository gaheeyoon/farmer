import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function verifyHanjinImport({db,rpc,admin,anon,expectError}){
 await db.exec('reset role;begin;update public.farmer_inventory set available_grams=1000000;');
 const bad=async(fn,text)=>{await db.exec('savepoint negative_hanjin');try{await expectError(fn,text);}finally{await db.exec('rollback to savepoint negative_hanjin;release savepoint negative_hanjin;');}};
 const delivery=(name,quantity)=>({product_id:'hopungmi-5kg',quantity,recipient_name:name,recipient_phone:'01022223333',postal_code:'04524',address:'서울특별시 강남구 테스트로 123',address_detail:'101호',memo:'기존 배송 메모'});
 const submit=async(name,quantity)=>{await anon();const receipt=await rpc('select public.farmer_submit_batch($1,$2,$3,$4,$5,$6,true) as result',[randomUUID(),'한진 검증 주문자','01011112222',JSON.stringify([delivery(name,quantity)]),'',22000*quantity]);await admin();return (await rpc("select public.farmer_admin_order_list('','한진 검증 주문자',0,'') as result")).orders.find(o=>o.order_number===receipt.orders[0].order_number);};
 const preview=rows=>rpc('select public.farmer_admin_hanjin_preview($1) as result',[JSON.stringify(rows)]);
 const commit=(rows,matches,mark=true,id=randomUUID())=>rpc('select public.farmer_admin_import_hanjin($1,$2,$3,$4) as result',[id,JSON.stringify(rows),JSON.stringify(matches),mark]);
 const read=async id=>{await db.exec('reset role;');const o=(await db.query('select * from public.farmer_orders where id=$1',[id])).rows[0];await admin();return o;};
 const stock=async()=>Number((await rpc('select public.farmer_admin_summary() as result')).available_kg);
 const confirm=async o=>{await rpc("select public.farmer_admin_change_status($1,'confirmed',$2,$3,'','') as result",[o.id,o.version,randomUUID()]);return read(o.id);};
 const parcel=(o,row,tracking)=>({row,tracking,name:o.recipient_name.slice(0,-1)+'* (선물입니다)',phone:'0102222****',postal:o.postal_code,address:o.address,weight_grams:5000,quantity:1,order_number:''});
 const mapped=(p,id)=>p.rows.map(r=>({row:r.row,order_id:id||r.candidates[0].id,expected_version:r.candidates.find(c=>!id||c.id===id).version}));
 let a=await confirm(await submit('한진4상자',4));
 const rows=Array.from({length:4},(_,i)=>parcel(a,i+3,'46361537000'+i));
 await anon();await bad(()=>preview(rows),'permission denied');await bad(()=>commit(rows,[]),'permission denied');
 await db.exec("reset role;select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);set role authenticated;");await bad(()=>preview(rows),'관리자 권한');await admin();
 let p=await preview(rows);assert.ok(p.rows.every(r=>r.candidates.length===1&&r.reason===''));
 assert.ok((await preview([{...rows[0],tracking:'bad'}])).rows[0].reason);assert.ok((await preview([rows[0],{...rows[0],row:99}])).rows.every(r=>r.reason.includes('중복')));
 assert.equal((await preview([{...rows[0],phone:'0109999****'}])).rows[0].candidates.length,0);
 assert.equal((await preview([{...rows[0],postal:'11111'}])).rows[0].candidates.length,0);
 assert.equal((await preview([{...rows[0],address:'서울특별시 다른 주소 123'}])).rows[0].candidates.length,0);
 assert.equal((await preview([{...rows[0],weight_grams:2000}])).rows[0].candidates.length,0);
 const before=await read(a.id),balance=await stock(),id=randomUUID(),matches=mapped(p);
 const saved=await commit(rows,matches,true,id);assert.equal(saved.parcels,4);assert.equal(saved.shipped,1);assert.equal(await stock(),balance);assert.deepEqual(await commit(rows,matches,true,id),saved);
 a=await read(a.id);assert.equal(a.status,'shipped');assert.equal(a.carrier,'한진');assert.deepEqual(a.tracking_numbers,rows.map(r=>r.tracking));
 for(const key of ['customer_name','phone','recipient_name','recipient_phone','postal_code','address','address_detail','memo','subtotal','total','discount_amount','weight_grams','quantity','confirmed_at'])assert.deepEqual(a[key],before[key]);
 p=await preview(rows);assert.ok(p.rows.every(r=>r.candidates[0].existing));const repeat=await commit(rows,mapped(p));assert.equal(repeat.orders,0);assert.equal(repeat.parcels,0);assert.equal((await read(a.id)).version,a.version);
 const pending=await submit('미입금한진',1),pendingRow=[{...parcel(pending,3,'463615371111'),name:pending.recipient_name}];p=await preview(pendingRow);const pendingStock=await stock();await commit(pendingRow,mapped(p));assert.equal((await read(pending.id)).status,'shipped_unpaid');assert.equal((await read(pending.id)).confirmed_at,null);assert.equal(await stock(),pendingStock-5);
 const free=await submit('전액할인선물',1);await db.exec('reset role;');await db.query('update public.farmer_orders set discount_amount=subtotal,total=0 where id=$1',[free.id]);await admin();const freeRow=[{...parcel(free,3,'463615371999'),name:free.recipient_name}],freeBefore=await stock();p=await preview(freeRow);await commit(freeRow,mapped(p));assert.equal((await read(free.id)).status,'shipped');assert.equal(await stock(),freeBefore-5);
 const c1=await submit('같은받는분',1),c2=await submit('같은받는분',2),ambiguous=[{...parcel(c1,3,'463615372222'),name:'같은받는분'}];p=await preview(ambiguous);assert.equal(p.rows[0].candidates.length,2);await bad(()=>commit(ambiguous,[{row:3,order_id:a.id,expected_version:a.version}]),'일치하지 않는 주문');
 let partial=await confirm(await submit('부분송장',4));const one=[{...parcel(partial,3,'463615373333'),name:partial.recipient_name}];p=await preview(one);const part=await commit(one,mapped(p));assert.equal(part.partial,1);partial=await read(partial.id);assert.equal(partial.status,'confirmed');assert.deepEqual(partial.tracking_numbers,['463615373333','','','']);
 const rest=[4,5,6].map((r,i)=>({...parcel(partial,r,'46361537333'+(i+4)),name:partial.recipient_name}));p=await preview(rest);await commit(rest,mapped(p));partial=await read(partial.id);assert.equal(partial.status,'shipped');assert.equal(partial.tracking_numbers.filter(Boolean).length,4);
 const overflow=[{...parcel(partial,3,'463615374444'),name:partial.recipient_name}];p=await preview(overflow);await bad(()=>commit(overflow,mapped(p)),'주문 수량보다');assert.deepEqual((await read(partial.id)).tracking_numbers,partial.tracking_numbers);
 const stale=await confirm(await submit('버전변경',1)),staleRow=[{...parcel(stale,3,'463615375555'),name:stale.recipient_name}];p=await preview(staleRow);await db.exec('reset role;');await db.query('update public.farmer_orders set version=version+1 where id=$1',[stale.id]);await admin();await bad(()=>commit(staleRow,mapped(p)),'다른 화면');assert.deepEqual((await read(stale.id)).tracking_numbers,[]);
 // A later failing order rolls back every earlier order in the same import.
 const good=await confirm(await submit('원자성검증',1)),goodRow={...parcel(good,3,'463615376666'),name:good.recipient_name};const combined=[goodRow,{...overflow[0],row:4}];p=await preview(combined);await bad(()=>commit(combined,mapped(p)),'주문 수량보다');assert.deepEqual((await read(good.id)).tracking_numbers,[]);
 // Existing waybill on another order never becomes a candidate.
 assert.equal((await preview([{...goodRow,tracking:rows[0].tracking}])).rows[0].candidates.length,0);
 const notShipped=[{...goodRow,tracking:'463615377777'}];p=await preview(notShipped);await commit(notShipped,mapped(p),false);assert.equal((await read(good.id)).status,'confirmed');
 await db.exec('reset role;');const audits=(await db.query('select count(*)::int n from farmer_private.hanjin_import_orders')).rows[0].n;assert.ok(audits>=5);await db.exec('rollback;');
 console.log('PASS: Hanjin admin authorization, strict masked identity/address/weight matching, ambiguous candidates, four parcels, preview and stale protection, exact replay, no overwrite, atomic rollback, partial imports, unpaid shipment stock, audit and preserved personal/financial fields.');
}
