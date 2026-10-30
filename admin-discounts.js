/* Private coupon management. Only authorized server RPCs can change or list codes. */
(() => {
 'use strict';
 const $=id=>document.getElementById(id),api=window.FarmerAPI,n=v=>Number(v).toLocaleString('ko-KR'),money=v=>n(v)+'원';
 const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
 const cell=(row,text,cls)=>{const e=node('td',text,cls);row.append(e);return e;};
 const msg=(id,text,error=false)=>{$(id).textContent=text;$(id).classList.toggle('error',error);};
 const date=v=>new Date(v).toLocaleString('ko-KR',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'});
 const states={active:'사용 가능',inactive:'사용 중지',exhausted:'수량 소진',deleted:'삭제됨'},orderStates={pending:'입금 대기',confirmed:'입금 확인',shipped:'배송 중',delivered:'배송 완료',cancelled:'취소'};
 let epoch=0,loading=false,busy=false,pending=null,editing=null,offset=0,data=null,historyCode=null,historyOffset=0,historyTotal=0,historyTicket=0,historyLoading=false;
 const canLeave=()=>!busy&&!pending;
 function controls(value){$('coupon-filter').querySelectorAll('input,select,button').forEach(e=>e.disabled=value);$('coupon-add').disabled=value;$('coupon-refresh').disabled=value;}
 function description(c){return c.mode==='percent'?`상품 금액의 ${c.percent}% 할인`:c.mode==='product_unit'?`최대 ${money(c.amount)} 할인`:`주문당 ${money(c.amount)} 할인`;}
 function render(result){
  data=result;$('coupon-rows').replaceChildren();$('coupon-count').textContent=n(result.total)+'개';
  for(const c of result.codes){
   const row=node('tr'),name=cell(row);name.append(node('span',c.code,'coupon-code'));
   const benefit=cell(row,description(c));if(c.mode==='product_unit')benefit.append(node('span',(c.product_name||'지정 상품')+' 1개 금액까지','coupon-meta'));
   const state=cell(row);state.append(node('span',states[c.status]||c.status,'coupon-state '+c.status));
   cell(row,c.usage_limit===null?'무제한':n(c.usage_limit)+'회','coupon-numbers');
   const count=cell(row,n(c.used_count)+'회 사용','coupon-numbers');count.append(node('span',c.usage_limit===null?'남은 수량 무제한':n(Math.max(0,c.usage_limit-c.used_count))+'회 남음','coupon-meta'));
   const actions=cell(row),wrap=node('div',undefined,'coupon-controls');
   const button=(title,action)=>{const b=node('button',title);b.type='button';b.setAttribute('aria-label',c.code+' '+title);b.addEventListener('click',action);wrap.append(b);};
   if(c.status!=='deleted'){button('수정',()=>open(c));button(c.active?'중지':'사용',()=>toggle(c));}
   button('사용 내역',()=>showHistory(c));actions.append(wrap);[...row.cells].forEach((td,i)=>td.dataset.label=['코드명','할인 혜택','상태','총 수량','사용 / 남음','관리'][i]);$('coupon-rows').append(row);
  }
  $('coupon-empty').hidden=result.codes.length>0;$('coupon-page').textContent=result.total?`${offset+1}–${Math.min(offset+result.codes.length,result.total)} / ${n(result.total)}개`:'0개';
  $('coupon-prev').disabled=offset===0;$('coupon-next').disabled=offset+result.codes.length>=result.total;$('coupon-data').hidden=false;
 }
 async function load(){
  if(loading||busy||pending||!api.hasSession())return;
  const ticket=epoch;loading=true;controls(true);$('coupon-data').hidden=true;msg('coupon-message','할인 코드를 불러오고 있습니다.');
  try{const result=await api.admin('farmer_admin_discount_list',{p_search:$('coupon-search').value.trim(),p_status:$('coupon-status').value,p_offset:offset});if(ticket!==epoch)return;render(result);msg('coupon-message','');}
  catch(e){if(ticket===epoch)msg('coupon-message',e.message,true);}
  finally{if(ticket===epoch){loading=false;controls(false);}}
 }
 function settings(){
  const mode=$('coupon-mode').value,percent=mode==='percent';$('coupon-product-field').hidden=mode!=='product_unit';$('coupon-product').required=mode==='product_unit';
  $('coupon-value-label').textContent=percent?'할인율 (%) *':mode==='product_unit'?'최대 할인 금액 (원) *':'할인 금액 (원) *';$('coupon-value').max=percent?'100':'100000000';
  $('coupon-limit-field').hidden=$('coupon-unlimited').checked;$('coupon-limit').required=!$('coupon-unlimited').checked;
  $('coupon-benefit-help').textContent=percent?'배송비를 제외한 상품 금액에 적용합니다.':mode==='product_unit'?'대상 상품이 포함된 주문에서, 해당 상품 1개의 판매가와 최대 할인 금액 중 작은 금액을 한 번 할인합니다.':'상품 금액에서 주문당 한 번 할인합니다. 주문 금액을 초과해 할인하지 않습니다.';
 }
 function lock(value){$('coupon-fields').disabled=value;for(const id of ['coupon-close','coupon-cancel','coupon-delete'])$(id).disabled=value;$('coupon-save').disabled=busy;$('coupon-save').textContent=busy?'처리 중…':pending?'처리 결과 다시 확인':'저장';}
 function open(c=null){
  if(loading||!canLeave()||!api.hasSession())return;
  editing=c;$('coupon-form').reset();$('coupon-product').replaceChildren();
  for(const p of data?.products||[]){const option=node('option',p.name);option.value=p.id;$('coupon-product').append(option);}
  for(const [id,value] of [['coupon-name',c?.code||''],['coupon-mode',c?.mode||'fixed'],['coupon-value',c?(c.mode==='percent'?c.percent:c.amount):''],['coupon-limit',c?.usage_limit??1]])$(id).value=value;
  $('coupon-product').value=c?.product_id||'hopungmi-5kg';$('coupon-unlimited').checked=c?.usage_limit==null;$('coupon-active').checked=c?.active??true;
  $('coupon-delete').hidden=!c;$('coupon-dialog-title').textContent=c?'할인 코드 수정':'할인 코드 추가';settings();lock(false);msg('coupon-form-message','');$('coupon-dialog').showModal();
 }
 function payload(c){return {id:c.id,code:c.code,mode:c.mode,amount:c.amount,percent:c.percent,product_id:c.product_id,usage_limit:c.usage_limit,active:c.active};}
 async function save(){
  if(busy)return;
  if(!pending){
   if(!$('coupon-form').reportValidity())return;
   const mode=$('coupon-mode').value;
   const entry={id:editing?.id||api.uuid(),code:$('coupon-name').value.normalize('NFKC').trim(),mode,amount:mode==='percent'?0:Number($('coupon-value').value),percent:mode==='percent'?Number($('coupon-value').value):0,product_id:mode==='product_unit'?$('coupon-product').value:null,usage_limit:$('coupon-unlimited').checked?null:Number($('coupon-limit').value),active:$('coupon-active').checked};
   if(!entry.code){msg('coupon-form-message','코드명을 입력해 주세요.',true);return;}
   pending={name:'farmer_admin_discount_save',body:{p_request_id:api.uuid(),p_entry:entry,p_expected_version:editing?.version??null}};
  }
  await commit();
 }
 async function commit(){
  if(!pending||busy)return;const ticket=epoch,request=pending;busy=true;lock(true);controls(true);msg('coupon-form-message','처리하고 있습니다.');
  try{
   const result=await api.admin(request.name,request.body);if(ticket!==epoch)return;
   if(result?.id!==(request.body.p_entry?.id||request.body.p_entry_id)||!Number.isFinite(result.version)||result.deleted!==request.name.endsWith('delete'))throw Object.assign(new Error('처리 결과를 확인하지 못했습니다.'),{uncertain:true});
   pending=null;busy=false;lock(false);$('coupon-dialog').close();$('coupon-form').reset();editing=null;offset=0;await load();if(ticket===epoch&&data)msg('coupon-message',result.deleted?'할인 코드를 삭제했습니다.':'할인 코드를 저장했습니다.');
  }catch(e){if(ticket!==epoch)return;if(!e.uncertain)pending=null;msg('coupon-form-message',e.message+(e.uncertain?' 같은 버튼으로 결과를 다시 확인해 주세요.':''),true);}
  finally{if(ticket===epoch){busy=false;lock(!!pending);controls(!!pending);}}
 }
 async function toggle(c){
  if(!canLeave()||loading)return;
  open(c);pending={name:'farmer_admin_discount_save',body:{p_request_id:api.uuid(),p_entry:{...payload(c),active:!c.active},p_expected_version:c.version}};await commit();
 }
 async function loadHistory(){
  if(!historyCode||historyLoading||!api.hasSession())return;
  const ticket=++historyTicket,generation=epoch;historyLoading=true;const id=historyCode.id;$('coupon-history-list').replaceChildren();$('coupon-history-prev').disabled=true;$('coupon-history-next').disabled=true;msg('coupon-history-message','사용 내역을 불러오고 있습니다.');
  try{
   const result=await api.admin('farmer_admin_discount_history',{p_code_id:id,p_offset:historyOffset});if(ticket!==historyTicket||generation!==epoch)return;
   historyTotal=result.total;$('coupon-history-page').textContent=result.total?`${historyOffset+1}–${Math.min(historyOffset+result.entries.length,result.total)} / ${n(result.total)}건`:'0건';
   for(const e of result.entries){
    const item=node('article',undefined,'coupon-history-item'),head=node('div',undefined,'coupon-history-head');head.append(node('strong',money(e.discount_amount)+' 할인'),node('span',e.released?'전체 취소 · 수량 복원':n(e.usage_count??1)+'회 사용','coupon-state '+(e.released?'inactive':'')));item.append(head,node('span',date(e.created_at)+' · 사용 당시 코드 '+e.code,'coupon-meta'));
    const orders=node('div',undefined,'coupon-history-orders');for(const o of e.orders||[])orders.append(node('span',o.order_number+' · '+(orderStates[o.status]||o.status)));item.append(orders);$('coupon-history-list').append(item);
   }
   msg('coupon-history-message',result.total?'':'아직 사용한 주문이 없습니다.');$('coupon-history-prev').disabled=historyOffset===0;$('coupon-history-next').disabled=historyOffset+result.entries.length>=result.total;
  }catch(e){if(ticket===historyTicket&&generation===epoch)msg('coupon-history-message',e.message,true);}
  finally{if(ticket===historyTicket&&generation===epoch)historyLoading=false;}
 }
 function showHistory(c){if(!canLeave())return;historyCode=c;historyOffset=0;historyLoading=false;$('coupon-history-title').textContent=c.code+' · 사용 내역';$('coupon-history-note').textContent='선물하기는 받는 분별 1회로 집계합니다. 한 번에 신청한 선물은 묶어 표시하며, 취소·삭제된 건은 제외합니다.';$('coupon-history-dialog').showModal();loadHistory();}
 function clearHistory(){historyTicket++;historyLoading=false;historyCode=null;historyOffset=0;historyTotal=0;$('coupon-history-list').replaceChildren();for(const id of ['coupon-history-title','coupon-history-note','coupon-history-message','coupon-history-page'])$(id).textContent='';}
 function clear(){epoch++;loading=false;busy=false;pending=null;editing=null;offset=0;data=null;clearHistory();$('coupon-data').hidden=true;$('coupon-rows').replaceChildren();$('coupon-form').reset();$('coupon-filter').reset();$('coupon-product').replaceChildren();$('coupon-count').textContent='';$('coupon-page').textContent='';$('discounts-panel').hidden=true;msg('coupon-message','');msg('coupon-form-message','');lock(false);controls(false);for(const id of ['coupon-dialog','coupon-history-dialog'])if($(id).open)$(id).close();}
 function init(){
  $('coupon-filter').addEventListener('submit',e=>{e.preventDefault();offset=0;load();});$('coupon-refresh').addEventListener('click',load);$('coupon-add').addEventListener('click',()=>open());
  $('coupon-prev').addEventListener('click',()=>{if(!loading){offset=Math.max(0,offset-25);load();}});$('coupon-next').addEventListener('click',()=>{if(!loading){offset+=25;load();}});
  for(const id of ['coupon-mode','coupon-unlimited'])$(id).addEventListener('change',settings);
  $('coupon-form').addEventListener('submit',e=>{e.preventDefault();save();});
  for(const id of ['coupon-close','coupon-cancel'])$(id).addEventListener('click',()=>{if(canLeave()){$('coupon-dialog').close();$('coupon-form').reset();editing=null;}});
  $('coupon-dialog').addEventListener('cancel',e=>{if(!canLeave())e.preventDefault();else{$('coupon-form').reset();editing=null;}});
  $('coupon-delete').addEventListener('click',()=>{if(!editing||!canLeave()||!confirm('이 할인 코드를 삭제할까요? 기존 사용 내역은 보관됩니다.'))return;pending={name:'farmer_admin_discount_delete',body:{p_entry_id:editing.id,p_expected_version:editing.version,p_request_id:api.uuid()}};commit();});
  $('coupon-history-close').addEventListener('click',()=>{$('coupon-history-dialog').close();clearHistory();});$('coupon-history-dialog').addEventListener('cancel',clearHistory);
  $('coupon-history-prev').addEventListener('click',()=>{if(!historyLoading){historyOffset=Math.max(0,historyOffset-50);loadHistory();}});$('coupon-history-next').addEventListener('click',()=>{if(!historyLoading&&historyOffset+50<historyTotal){historyOffset+=50;loadHistory();}});
 }
 window.FarmerDiscounts=Object.freeze({init,clear,canLeave,show:view=>{if(view==='discounts')load();}});
})();
