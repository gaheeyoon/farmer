/* Private finance UI. Records are loaded through administrator-only RPCs. */
(() => {
  'use strict';
  const $=id=>document.getElementById(id), api=window.FarmerAPI;
  const money=value=>Number(value).toLocaleString('ko-KR')+'원';
  const number=value=>Number(value).toLocaleString('ko-KR',{maximumFractionDigits:3});
  const today=()=>new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  const node=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
  const cell=(row,text,cls)=>{const n=node('td',text,cls);row.append(n);return n;};
  const message=(id,text,error=false)=>{$(id).textContent=text;$(id).classList.toggle('error',error);};
  let epoch=0, active=false, loading=false, busy=false, pending=null, editing=null, offset=0, result=null, canSwitch=()=>true;
  function filtersDisabled(value){$('finance-filter').querySelectorAll('input,select,button').forEach(n=>n.disabled=value);$('finance-refresh').disabled=value;$('finance-add').disabled=value;}
  function clearReport(){result=null;$('finance-data').hidden=true;for(const id of ['finance-rows','finance-months','finance-month-rows','finance-categories'])$(id).replaceChildren();for(const id of ['finance-order-income','finance-manual-income','finance-expense','finance-profit'])$(id).textContent='—';for(const id of ['finance-order-meta','finance-period','finance-pending','finance-count','finance-page'])$(id).textContent='';}
  function render(data){
    result=data;const s=data.summary;
    $('finance-period').textContent=`${data.year}년 전체 기준 · 수입 = 주문 수입 + 추가 수입`;
    for(const [id,value] of [['finance-order-income',s.order_income],['finance-manual-income',s.manual_income],['finance-expense',s.expense],['finance-profit',s.profit]])$(id).textContent=money(value);
    $('finance-order-meta').textContent=`${number(s.order_count)}건 · ${number(s.sold_kg)}kg 판매`;
    $('finance-pending').textContent=`집계에서 제외한 입금 대기 금액 ${money(s.pending_income)} · 주문 수입에 포함된 받은 배송비 ${money(s.collected_shipping)}`;
    const scale=Math.max(1,...data.months.flatMap(m=>[Number(m.income),Number(m.expense)]));
    $('finance-months').replaceChildren();$('finance-month-rows').replaceChildren();
    for(const m of data.months){
      const column=node('div',undefined,'finance-month'),bars=node('div',undefined,'finance-bars');
      for(const value of [m.income,m.expense]){const bar=node('i');bar.style.height=Number(value)>0?Math.max(2,Number(value)/scale*120)+'px':'0px';bars.append(bar);}
      column.title=`${m.month}월 · 수입 ${money(m.income)} · 지출 ${money(m.expense)}`;column.append(bars,node('span',m.month+'월'));$('finance-months').append(column);
      if(Number(m.income)||Number(m.expense)){const row=node('tr');cell(row,m.month+'월');cell(row,money(m.income));cell(row,money(m.expense));cell(row,money(Number(m.income)-Number(m.expense)));$('finance-month-rows').append(row);}
    }
    if(!$('finance-month-rows').children.length){const row=node('tr'),c=cell(row,'아직 기록한 내역이 없습니다.');c.colSpan=4;$('finance-month-rows').append(row);}
    $('finance-categories').replaceChildren();
    for(const item of data.categories){
      const container=node('div'),head=node('div',undefined,'finance-category-head'),track=node('div',undefined,'finance-category-track'),bar=node('i');
      head.append(node('span',item.category),node('strong',money(item.amount)));bar.style.width=(Number(s.expense)?Math.min(100,Number(item.amount)/Number(s.expense)*100):0)+'%';track.setAttribute('aria-hidden','true');track.append(bar);container.append(head,track);$('finance-categories').append(container);
    }
    if(!data.categories.length)$('finance-categories').append(node('p','기록한 지출이 없습니다.','finance-note'));
    $('finance-rows').replaceChildren();
    for(const e of data.entries){
      const row=node('tr');cell(row,e.occurred_on);cell(row,e.direction==='income'?'수입':'지출',e.direction==='income'?'finance-income':'finance-expense');cell(row,e.category);
      const detail=cell(row);detail.append(node('span',e.title,'finance-entry-title'));
      if(e.source==='manual'&&e.quantity!==null&&e.unit_price!==null)detail.append(node('span',`${number(e.quantity)} × ${money(e.unit_price)}`,'finance-entry-note'));
      if(e.note)detail.append(node('span',e.note,'finance-entry-note'));
      if(e.source==='order')detail.append(node('span','주문 연동 · '+e.order_number,'finance-source'));
      cell(row,e.counterparty||'—');cell(row,(e.direction==='income'?'+':'−')+money(e.amount),'finance-amount '+(e.direction==='income'?'finance-income':'finance-expense'));
      const action=cell(row);
      if(e.source==='manual'){const button=node('button','수정','finance-entry-edit');button.type='button';button.setAttribute('aria-label',e.title+' 수정');button.addEventListener('click',()=>openEntry(e));action.append(button);}else action.append(node('span','자동 집계','finance-source'));
      $('finance-rows').append(row);
    }
    $('finance-empty').hidden=data.entries.length>0;$('finance-count').textContent=`총 ${number(data.total)}건`;
    $('finance-page').textContent=data.total?`${offset+1}–${Math.min(offset+data.entries.length,data.total)} / ${number(data.total)}건`:'0건';
    $('finance-prev').disabled=offset===0;$('finance-next').disabled=offset+data.entries.length>=data.total;
    $('finance-data').hidden=false;
  }
  async function load(){
    if(loading||busy||pending||!api?.hasSession()||!$('finance-filter').reportValidity())return;
    const ticket=epoch;loading=true;filtersDisabled(true);clearReport();message('finance-message','장부를 불러오고 있습니다.');
    try{
      const data=await api.admin('farmer_admin_finance_report',{p_year:Number($('finance-year').value),p_kind:$('finance-kind').value,p_search:$('finance-search').value.trim(),p_offset:offset});
      if(ticket!==epoch)return;render(data);message('finance-message','');
    }catch(error){if(ticket===epoch)message('finance-message',error.message,true);}
    finally{if(ticket===epoch){loading=false;filtersDisabled(false);}}
  }
  function selectView(view){
    if(!canSwitch()||busy||pending)return;
    active=view==='finance';$('operations-panel').hidden=active;$('finance-panel').hidden=!active;
    document.querySelectorAll('[data-admin-view]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.adminView===view)));
    if(active)load();
  }
  function calculation(){
    const q=$('finance-quantity'),p=$('finance-unit-price'),amount=$('finance-amount');
    q.required=!!p.value;p.required=!!q.value;
    amount.readOnly=!!q.value&&!!p.value;
    if(amount.readOnly&&q.validity.valid&&p.validity.valid)amount.value=String(Math.floor((Math.round(Number(q.value)*1000)*Number(p.value)+500)/1000));
  }
  function formLocked(value){
    $('finance-fields').disabled=value;$('finance-close').disabled=value;$('finance-cancel').disabled=value;$('finance-delete').disabled=value;
    $('finance-save').disabled=busy;$('finance-save').textContent=busy?'저장 중…':pending?(pending.name.endsWith('delete')?'삭제 결과 다시 확인':'저장 결과 다시 확인'):'저장';
  }
  function openEntry(entry=null){
    if(loading||busy||pending||!api.hasSession())return;
    editing=entry;$('finance-form').reset();$('finance-calculation').open=!!entry?.quantity;
    const year=Number($('finance-year').value),date=entry?.occurred_on||(year===Number(today().slice(0,4))?today():`${year}-01-01`);
    for(const [id,value] of [['finance-date',date],['finance-direction',entry?.direction||'expense'],['finance-category',entry?.category||'기타'],['finance-title',entry?.title||''],['finance-party',entry?.counterparty||''],['finance-note',entry?.note||''],['finance-amount',entry?.amount??''],['finance-quantity',entry?.quantity??''],['finance-unit-price',entry?.unit_price??'']])$(id).value=String(value);
    calculation();formLocked(false);$('finance-delete').hidden=!entry;$('finance-income-help').hidden=$('finance-direction').value!=='income';
    $('finance-dialog-title').textContent=entry?'수입·지출 수정':'수입·지출 추가';message('finance-form-message','');$('finance-dialog').showModal();
  }
  async function persist(){
    if(busy)return;
    if(!pending){
      if(!$('finance-form').reportValidity())return;
      const entry={id:editing?.id||api.uuid(),occurred_on:$('finance-date').value,direction:$('finance-direction').value,category:$('finance-category').value.trim(),title:$('finance-title').value.trim(),counterparty:$('finance-party').value.trim(),note:$('finance-note').value.trim(),amount:Number($('finance-amount').value),quantity:$('finance-quantity').value||null,unit_price:$('finance-unit-price').value||null};
      pending={name:'farmer_admin_finance_save',body:{p_request_id:api.uuid(),p_entry:entry,p_expected_version:editing?.version??null}};
    }
    await commitPending();
  }
  async function commitPending(){
    if(!pending||busy)return;
    const ticket=epoch,request=pending;busy=true;formLocked(true);
    message('finance-form-message',request.name.endsWith('delete')?'삭제하고 있습니다.':'저장하고 있습니다.');
    try{
      const receipt=await api.admin(request.name,request.body);if(ticket!==epoch)return;
      if(receipt?.id!==(request.body.p_entry?.id||request.body.p_entry_id)||!Number.isFinite(receipt.version)||receipt.deleted!==request.name.endsWith('delete'))throw Object.assign(new Error('저장 결과를 확인하지 못했습니다.'),{uncertain:true});
      if(request.body.p_entry)$('finance-year').value=request.body.p_entry.occurred_on.slice(0,4);
      pending=null;busy=false;formLocked(false);$('finance-dialog').close();$('finance-form').reset();editing=null;offset=0;
      await load();if(ticket===epoch&&result)message('finance-message',request.name.endsWith('delete')?'내역을 삭제했습니다.':'내역을 저장했습니다.');
    }catch(error){
      if(ticket!==epoch)return;
      if(!error.uncertain)pending=null;
      message('finance-form-message',error.message+(error.uncertain?' 같은 버튼으로 처리 결과를 다시 확인해 주세요.':''),true);
    }finally{if(ticket===epoch){busy=false;formLocked(!!pending);}}
  }
  function clear(){
    epoch++;active=false;loading=false;busy=false;pending=null;editing=null;offset=0;clearReport();
    $('finance-form').reset();$('finance-amount').readOnly=false;$('finance-quantity').required=false;$('finance-unit-price').required=false;formLocked(false);filtersDisabled(false);
    if($('finance-dialog').open)$('finance-dialog').close();
    $('finance-panel').hidden=true;$('operations-panel').hidden=false;$('finance-year').value=today().slice(0,4);$('finance-kind').value='';$('finance-search').value='';
    message('finance-message','');message('finance-form-message','');
    document.querySelectorAll('[data-admin-view]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.adminView==='operations')));
  }
  function init(allowSwitch){
    canSwitch=allowSwitch;$('finance-year').value=today().slice(0,4);
    document.querySelectorAll('[data-admin-view]').forEach(b=>b.addEventListener('click',()=>selectView(b.dataset.adminView)));
    $('finance-filter').addEventListener('submit',e=>{e.preventDefault();offset=0;load();});
    $('finance-refresh').addEventListener('click',load);$('finance-add').addEventListener('click',()=>openEntry());
    $('finance-prev').addEventListener('click',()=>{if(!loading){offset=Math.max(0,offset-50);load();}});$('finance-next').addEventListener('click',()=>{if(!loading){offset+=50;load();}});
    $('finance-form').addEventListener('submit',e=>{e.preventDefault();persist();});
    for(const id of ['finance-quantity','finance-unit-price'])$(id).addEventListener('input',calculation);
    $('finance-direction').addEventListener('change',()=>{$('finance-income-help').hidden=$('finance-direction').value!=='income';});
    for(const id of ['finance-close','finance-cancel'])$(id).addEventListener('click',()=>{if(!busy&&!pending){$('finance-dialog').close();$('finance-form').reset();editing=null;}});
    $('finance-dialog').addEventListener('cancel',e=>{if(busy||pending)e.preventDefault();else{$('finance-form').reset();editing=null;}});
    $('finance-delete').addEventListener('click',async()=>{
      if(!editing||busy||pending||!confirm('이 수입·지출 내역을 삭제할까요? 손익 집계에서 제외됩니다.'))return;
      pending={name:'farmer_admin_finance_delete',body:{p_entry_id:editing.id,p_expected_version:editing.version,p_request_id:api.uuid()}};await commitPending();
    });
  }
  window.FarmerFinance=Object.freeze({init,clear});
})();
