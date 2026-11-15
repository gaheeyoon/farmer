/* Admin-only Smart Store upload, preview and idempotent registration. No file/password storage. */
(() => {
 'use strict';const $=id=>document.getElementById(id),api=window.FarmerAPI;
 let ctx=null,busy=false,pending=null,epoch=0,rows=[],preview=null,reader=null;
 const locked=()=>busy||!!pending;
 const node=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e;};
 const tell=(text,error=false)=>{$('naver-status').textContent=text;$('naver-status').classList.toggle('error',error);};
 const selected=()=>[...$('naver-rows').querySelectorAll('input:checked')].map(e=>Number(e.dataset.row));
 function sync(){
  const count=selected().length;const chosen=rows.filter(r=>selected().includes(r.row));
  for(const id of ['naver-file','naver-password','naver-read'])$(id).disabled=locked();
  document.querySelectorAll('[data-naver-close]').forEach(e=>e.disabled=locked());
  $('naver-rows').querySelectorAll('input').forEach(e=>e.disabled=locked()||e.dataset.blocked==='true');
  $('naver-all').disabled=locked()||!preview?.rows.some(r=>r.kind==='ready');
  const available=preview?.rows.filter(r=>r.kind==='ready').length||0;
  $('naver-all').checked=available>0&&count===available;$('naver-all').indeterminate=count>0&&count<available;
  $('naver-save').disabled=busy||(!pending&&!count);$('naver-save').textContent=busy?'등록 중…':pending?'등록 결과 다시 확인':`선택한 ${count}건 등록`;
  const kg=preview?.rows.filter(r=>selected().includes(r.row)).reduce((sum,r)=>sum+Number(r.weight_grams),0)/1000||0;
  $('naver-count').textContent=preview?`새 주문 ${available}건 · 이미 등록 ${preview.rows.filter(r=>r.kind==='existing').length}건 · 확인 필요 ${preview.rows.filter(r=>r.kind==='invalid').length}건 / 선택 ${count}건 · ${kg}kg · 상품 금액 ${chosen.reduce((sum,r)=>sum+Number(r.goods_total||0),0).toLocaleString('ko-KR')}원`:'';
 }
 function resetPreview(){rows=[];preview=null;$('naver-rows').replaceChildren();$('naver-preview').hidden=true;sync();}
 function clear(){epoch++;busy=false;pending=null;resetPreview();$('naver-file').value='';$('naver-password').value='';tell('');if($('naver-dialog').open)$('naver-dialog').close();}
 function loadReader(){
  if(window.XlsxPopulate)return Promise.resolve();if(reader)return reader;
  reader=new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='vendor/xlsx-populate-1.21.0.min.js';script.onload=()=>window.XlsxPopulate?resolve():reject(Error('엑셀 읽기 기능을 불러오지 못했습니다.'));script.onerror=()=>{script.remove();reject(Error('엑셀 읽기 기능을 불러오지 못했습니다. 다시 시도해 주세요.'));};document.head.append(script);}).catch(e=>{reader=null;throw e;});return reader;
 }
 function render(){
  $('naver-rows').replaceChildren();
  for(const item of preview.rows){
   const data=rows.find(r=>r.row===item.row),tr=node('tr'),check=node('input');check.type='checkbox';check.dataset.row=String(item.row);check.dataset.blocked=String(item.kind!=='ready');check.checked=item.kind==='ready';check.setAttribute('aria-label',`${item.row}행 주문 등록 선택`);check.addEventListener('change',sync);
   for(const content of [check,String(item.row),item.external_id,data.recipient_name,item.product_name||data.source_product,`${data.quantity??'—'}상자`,Number(data.goods_total||0).toLocaleString('ko-KR')+'원',item.reason||'입금 확인 (배송 준비)로 등록']){const td=node('td');if(typeof content==='string')td.textContent=content;else td.append(content);tr.append(td);}
   $('naver-rows').append(tr);
  }
  $('naver-preview').hidden=false;sync();
 }
 async function read(){
  if(locked()||!api.hasSession())return;const file=$('naver-file').files[0];if(!file){tell('네이버 주문 엑셀을 선택해 주세요.',true);return;}
  const ticket=++epoch;resetPreview();busy=true;ctx.changed();sync();tell('엑셀을 열고 기존 주문과 비교하고 있습니다.');
  try{
   if(!/\.xlsx$/i.test(file.name)||file.size>5*1024*1024)throw Error('5MB 이하의 .xlsx 파일을 선택해 주세요.');
   await loadReader();if(ticket!==epoch)return;
   let workbook;try{workbook=await window.XlsxPopulate.fromDataAsync(await file.arrayBuffer(),{password:$('naver-password').value});}catch{throw Error('엑셀을 열지 못했습니다. 비밀번호와 파일을 확인해 주세요.');}
   if(ticket!==epoch)return;$('naver-password').value='';
   const sheets=workbook.sheets().map(sheet=>{const range=sheet.usedRange();if(!range)return {rows:[]};if(range.endCell().rowNumber()>510||range.endCell().columnNumber()>200)throw Error('한 번에 500건까지 등록할 수 있습니다. 네이버 주문 파일을 나눠 주세요.');return {rows:range.value(),offset:range.startCell().rowNumber()-1};});
   rows=window.FarmerNaverFile.parse(sheets);
   preview=await api.admin('farmer_admin_naver_preview',{p_rows:rows});if(ticket!==epoch)return;
   if(!Array.isArray(preview?.rows)||preview.rows.length!==rows.length)throw Error('주문 확인 결과를 가져오지 못했습니다. 다시 확인해 주세요.');
   render();tell('등록할 새 주문을 확인해 주세요. 이미 등록된 주문은 제외되며, 기존 주문은 변경하지 않습니다.');
  }catch(e){if(ticket!==epoch)return;resetPreview();tell(e.message,true);}
  finally{if(ticket===epoch){busy=false;ctx.changed();sync();}}
 }
 async function save(){
  if(busy||!api.hasSession())return;
  if(!pending){const chosen=selected();if(!chosen.length)return;pending={p_request_id:api.uuid(),p_rows:rows,p_selected:chosen};}
  const ticket=epoch;busy=true;ctx.changed();sync();tell('주문을 등록하고 재고를 반영하고 있습니다.');
  try{
   const result=await api.admin('farmer_admin_import_naver',pending);if(ticket!==epoch)return;if(!result?.saved)throw Object.assign(Error('등록 결과를 확인하지 못했습니다.'),{uncertain:true});
   pending=null;busy=false;clear();ctx.changed();await ctx.saved(`네이버 주문 ${result.added}건 등록 · 재고 ${result.weight_kg}kg 차감${result.skipped?' · 중복 '+result.skipped+'건 제외':''}`);
  }catch(e){if(ticket!==epoch)return;if(!e.uncertain)pending=null;tell(e.uncertain?'결과를 확인하지 못했습니다. ‘등록 결과 다시 확인’을 누르면 중복 등록 없이 확인합니다.':e.message,true);}
  finally{if(ticket===epoch){busy=false;ctx.changed();sync();}}
 }
 function init(options){
  ctx=options;$('open-naver').addEventListener('click',()=>{if(!ctx.canStart()||locked())return;clear();$('naver-dialog').showModal();$('naver-file').focus();});
  $('naver-read').addEventListener('click',read);$('naver-save').addEventListener('click',save);$('naver-file').addEventListener('change',()=>{if(!locked()){epoch++;resetPreview();tell('');}});
  $('naver-all').addEventListener('change',()=>{$('naver-rows').querySelectorAll('input').forEach(e=>{if(e.dataset.blocked!=='true')e.checked=$('naver-all').checked;});sync();});
  document.querySelectorAll('[data-naver-close]').forEach(e=>e.addEventListener('click',()=>{if(!locked())clear();}));$('naver-dialog').addEventListener('cancel',e=>{if(locked())e.preventDefault();else clear();});
  window.addEventListener('beforeunload',e=>{if(locked()){e.preventDefault();e.returnValue='';}});
 }
 window.FarmerNaver=Object.freeze({init,clear,locked});
})();
