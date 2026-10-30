/* Admin-only Hanjin import: preview first; approved rows commit atomically. */
(() => {
 'use strict';const $=id=>document.getElementById(id),api=window.FarmerAPI;
 let ctx=null,busy=false,pending=null,epoch=0,rows=[],preview=null,sdk=null;
 const locked=()=>busy||!!pending;
 const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
 const tell=(text,error=false)=>{$('hanjin-status').textContent=text;$('hanjin-status').classList.toggle('error',error);};
 function choices(){return [...$('hanjin-rows').querySelectorAll('[data-hanjin-row]')].filter(tr=>tr.querySelector('input').checked&&tr.querySelector('select').value).map(tr=>{const row=Number(tr.dataset.hanjinRow),id=tr.querySelector('select').value,candidate=preview.rows.find(r=>r.row===row).candidates.find(c=>c.id===id);return {row,order_id:id,expected_version:candidate.version};});}
 function sync(){
  const selected=preview?choices():[];
  $('hanjin-file').disabled=locked();$('hanjin-mark-shipped').disabled=locked();
  $('hanjin-save').disabled=busy||(!pending&&!selected.length);$('hanjin-save').textContent=busy?'처리 중…':pending?'등록 결과 다시 확인':'선택한 송장 등록';
  document.querySelectorAll('[data-hanjin-close]').forEach(b=>b.disabled=locked());
  $('hanjin-rows').querySelectorAll('select,input').forEach(e=>e.disabled=locked()||e.dataset.blocked==='true');
  $('hanjin-count').textContent=preview?`${rows.length}상자 중 ${selected.length}상자 선택 · ${new Set(selected.map(s=>s.order_id)).size}건 주문`:'';
 }
 function clear(){epoch++;busy=false;pending=null;rows=[];preview=null;$('hanjin-file').value='';$('hanjin-rows').replaceChildren();$('hanjin-preview').hidden=true;$('hanjin-count').textContent='';tell('');if($('hanjin-dialog').open)$('hanjin-dialog').close();}
 function loadReader(){
  if(window.XLSX)return Promise.resolve();if(sdk)return sdk;
  sdk=new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='vendor/xlsx-0.20.3.full.min.js';script.onload=()=>window.XLSX?resolve():reject(Error('엑셀 읽기 기능을 불러오지 못했습니다.'));script.onerror=()=>{script.remove();reject(Error('엑셀 읽기 기능을 불러오지 못했습니다. 다시 선택해 주세요.'));};document.head.append(script);}).catch(e=>{sdk=null;throw e;});return sdk;
 }
 function render(){
  $('hanjin-rows').replaceChildren();
  for(const r of preview.rows){
   const tr=node('tr');tr.dataset.hanjinRow=String(r.row);const box=document.createElement('input');box.type='checkbox';box.setAttribute('aria-label',`${r.row}행 송장 등록 선택`);
   const select=document.createElement('select');select.setAttribute('aria-label',`${r.row}행 연결할 주문`);const placeholder=node('option',r.reason||'주문을 선택해 주세요');placeholder.value='';select.append(placeholder);
   for(const c of r.candidates){const state=({pending:'입금 대기',confirmed:'배송 준비',shipped:'배송 중',shipped_unpaid:'배송 중·미입금',delivered:'배송 완료'})[c.status]||c.status;const option=node('option',`${c.order_number} · ${c.recipient_name} · ${c.quantity}상자 · ${state} · 주문자 ${c.customer_name}${c.existing?' · 등록된 송장':''}`);option.value=c.id;select.append(option);}
   if(r.candidates.length===1&&!r.reason){select.value=r.candidates[0].id;box.checked=true;}
   const blocked=!!r.reason;box.dataset.blocked=String(blocked);select.dataset.blocked=String(blocked);
   for(const el of [box,node('span',String(r.row)),node('span',r.name||'—'),node('span',r.tracking),select]){const td=node('td');td.append(el);tr.append(td);}
   const detail=node('td',r.reason||(r.candidates.length>1?'같은 배송지의 주문이 여럿입니다. 연결할 주문을 선택해 주세요.':r.candidates[0]?.existing?'기존 송장과 같습니다.':'등록할 수 있습니다.'));tr.append(detail);
   box.addEventListener('change',()=>{if(box.checked&&!select.value){box.checked=false;select.focus();}sync();});select.addEventListener('change',()=>{box.checked=!!select.value;sync();});$('hanjin-rows').append(tr);
  }
  $('hanjin-preview').hidden=false;sync();
 }
 async function readFile(){
  if(locked()||!api.hasSession())return;const file=$('hanjin-file').files[0];if(!file)return;
  const ticket=++epoch;busy=true;rows=[];preview=null;$('hanjin-preview').hidden=true;$('hanjin-rows').replaceChildren();ctx.changed();sync();tell('파일과 주문을 확인하고 있습니다.');
  try{
   if(!/\.xlsx$/i.test(file.name)||file.size>5*1024*1024)throw Error('5MB 이하의 .xlsx 파일을 선택해 주세요.');
   await loadReader();if(ticket!==epoch)return;
   const workbook=window.XLSX.read(await file.arrayBuffer(),{type:'array',cellFormula:false,cellHTML:false,bookVBA:false});
   rows=window.FarmerHanjinFile.parse(workbook);preview=await api.admin('farmer_admin_hanjin_preview',{p_rows:rows});if(ticket!==epoch)return;
   if(!Array.isArray(preview?.rows)||preview.rows.length!==rows.length)throw Error('주문 매칭 결과를 확인하지 못했습니다. 다시 선택해 주세요.');
   render();tell('연결할 주문과 선택한 행을 확인한 뒤 등록해 주세요. 일치하지 않는 행은 등록되지 않습니다.');
  }catch(e){if(ticket!==epoch)return;rows=[];preview=null;tell(e.message,true);}
  finally{if(ticket===epoch){busy=false;ctx.changed();sync();}}
 }
 async function save(){
  if(busy||!api.hasSession())return;
  if(!pending){const matches=choices();if(!matches.length)return;pending={p_request_id:api.uuid(),p_rows:rows,p_matches:matches,p_mark_shipped:$('hanjin-mark-shipped').checked};}
  const ticket=epoch,payload=pending;busy=true;ctx.changed();sync();tell('송장을 등록하고 있습니다.');
  try{
   const result=await api.admin('farmer_admin_import_hanjin',payload);if(ticket!==epoch)return;if(!result?.saved)throw Object.assign(Error('등록 결과를 확인하지 못했습니다.'),{uncertain:true});
   pending=null;busy=false;const text=`한진 송장 ${result.parcels}개 추가 · ${result.orders}건 변경${result.shipped?' · '+result.shipped+'건 발송 처리':''}${result.unchanged?' · 이미 반영된 주문 '+result.unchanged+'건':''}${result.partial?' · 송장이 모두 입력되지 않은 '+result.partial+'건은 기존 상태 유지':''}`;
   clear();ctx.changed();await ctx.saved(text);
  }catch(e){if(ticket!==epoch)return;if(!e.uncertain)pending=null;tell(e.uncertain?'결과를 확인하지 못했습니다. ‘등록 결과 다시 확인’을 누르면 중복 등록 없이 확인합니다.':e.message,true);}
  finally{if(ticket===epoch){busy=false;ctx.changed();sync();}}
 }
 function init(options){ctx=options;$('open-hanjin').addEventListener('click',()=>{if(!ctx.canStart()||locked())return;clear();$('hanjin-mark-shipped').checked=true;$('hanjin-dialog').showModal();sync();$('hanjin-file').focus();});$('hanjin-file').addEventListener('change',readFile);$('hanjin-save').addEventListener('click',save);document.querySelectorAll('[data-hanjin-close]').forEach(b=>b.addEventListener('click',()=>{if(!locked())clear();}));$('hanjin-dialog').addEventListener('cancel',e=>{if(locked())e.preventDefault();else clear();});window.addEventListener('beforeunload',e=>{if(locked()){e.preventDefault();e.returnValue='';}});}
 window.FarmerHanjin=Object.freeze({init,clear,locked});
})();
