/* Read-only planning, with the same private year totals used by the accounting page. */
(() => {
 'use strict';
 const $=id=>document.getElementById(id),api=window.FarmerAPI,math=window.FarmerSimulationMath;
 const money=v=>Number(v).toLocaleString('ko-KR')+'원',number=v=>Number(v).toLocaleString('ko-KR',{maximumFractionDigits:3});
 const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
 const message=(text,error=false)=>{$('sim-message').textContent=text;$('sim-message').classList.toggle('error',error);};
 const todayYear=()=>Number(new Intl.DateTimeFormat('en',{year:'numeric',timeZone:'Asia/Seoul'}).format(new Date()));
 const ids=['sim-price2','sim-price5','sim-qty2','sim-qty5','sim-gift-qty5','sim-shipping','sim-packing'];
 let base=null,catalog=null,gifts=null,epoch=0,loading=false,initialized=false;
 function hideResults(){for(const id of ['sim-results','sim-comparison'])$(id).hidden=true;$('sim-placeholder').hidden=false;for(const id of ['sim-profit','sim-total-income','sim-total-cost','sim-base-income','sim-revenue','sim-base-expense','sim-shipping-cost','sim-packing-cost','sim-break-even'])$(id).textContent='—';for(const id of ['sim-profit-note','sim-break-even-note','sim-impact'])$(id).textContent='';$('sim-bars').replaceChildren();$('sim-comparison-rows').replaceChildren();}
 function hideData(){base=null;catalog=null;gifts=null;$('sim-gift-registered5').value=0;$('sim-gift-people').replaceChildren();$('sim-gift-count-note').textContent='';$('sim-gift-total').textContent='';$('sim-data').hidden=true;hideResults();for(const id of ['sim-expense','sim-income','sim-stock','sim-updated'])$(id).textContent='—';for(const id of ['sim-categories'])$(id).replaceChildren();for(const id of ['sim-baseline-note','sim-input-message','sim-plan-note'])$(id).textContent='';}
 function disabled(value){$('sim-year').disabled=value;$('sim-refresh').disabled=value;$('sim-form').querySelectorAll('input,button').forEach(e=>e.disabled=value);}
 function fillStock(){if(!base||!$('sim-gift-qty5').validity.valid||$('sim-gift-qty5').value==='')return;const plan=math.planStock(Math.max(0,base.availableKg-Number($('sim-gift-qty5').value)*5));$('sim-qty5').value=plan.qty5;$('sim-qty2').value=plan.qty2;}
 function resetPrices(){if(!catalog)return;for(const k of [2,5])$('sim-price'+k+'-range').max=50000;$('sim-price2').value=catalog.find(p=>p.id==='hopungmi-2kg').price;$('sim-price5').value=catalog.find(p=>p.id==='hopungmi-5kg').price;}
 function syncSliders(){
  for(const k of [2,5]){
   const field=$('sim-price'+k),slider=$('sim-price'+k+'-range');
   const valid=field.value!==''&&field.validity.valid,price=valid?Number(field.value):0;
   const max=Math.min(100000000,Math.max(50000,Number(slider.max),Math.ceil(price/10000)*10000));
   slider.max=max;slider.value=Math.round(price/1000)*1000;
   slider.setAttribute('aria-valuetext',money(Number(slider.value)));
   slider.style.setProperty('--sim-slider-progress',(Number(slider.value)/max*100)+'%');
   $('sim-price'+k+'-value').textContent=valid?money(price):'—';$('sim-price'+k+'-max').textContent=money(max);
  }
 }
 function input(){
  if(!base)return null;
  let invalid=false;
  for(const id of ids){const e=$(id),valid=e.value!==''&&e.validity.valid;e.setAttribute('aria-invalid',String(!valid));invalid||=!valid;}
  if(invalid){$('sim-input-message').textContent='판매가·판매/선물 수량·배송비·상자비를 0 이상의 정수로 입력해 주세요.';return null;}
  $('sim-input-message').textContent='';
  return {expense:base.expense,income:base.income,availableKg:base.availableKg,price2:Number($('sim-price2').value),price5:Number($('sim-price5').value),qty2:Number($('sim-qty2').value),qty5:Number($('sim-qty5').value),giftQty5:Number($('sim-gift-qty5').value),shipping:Number($('sim-shipping').value),packing:Number($('sim-packing').value)};
 }
 function render(){
  syncSliders();
  if(!base||loading)return;hideResults();$('sim-plan-note').textContent='';
  const planned=Number($('sim-gift-qty5').value);$('sim-gift-total').textContent=$('sim-gift-qty5').value!==''&&Number.isInteger(planned)&&planned>=0?`5kg 선물 합계 ${number(gifts.totals.qty5+planned)}상자 · 등록 ${number(gifts.totals.qty5)} + 추가 계획 ${number(planned)}`:'';
  const p=input();if(!p)return;
  try{
   const r=math.calculate(p),rows=math.comparison(p);
   for(const [id,value] of [['sim-profit',r.profit],['sim-total-income',r.totalIncome],['sim-total-cost',r.totalCost],['sim-base-income',p.income],['sim-revenue',r.revenue],['sim-base-expense',p.expense],['sim-shipping-cost',r.shippingCost],['sim-packing-cost',r.packingCost]])$(id).textContent=money(value);
   $('sim-profit').closest('.sim-profit-card').classList.toggle('loss',r.profit<0);
   $('sim-profit-note').textContent=`장부 기준 손익 ${money(r.baseProfit)}에서 ${money(r.contribution)} 변화`;
   $('sim-plan-note').textContent=`판매 ${number(r.paidBoxes)}상자 · 선물 ${number(r.giftBoxes)}상자, 총 ${number(r.kg)}kg 발송 계획. `+(r.overStock?`현재 재고보다 ${number(-r.remainingKg)}kg 많습니다.`:`발송 후 남는 재고 ${number(r.remainingKg)}kg.`);
   $('sim-plan-note').classList.toggle('error',r.overStock);
   $('sim-break-even').textContent=r.breakEvenAverage===null?'수량을 입력해 주세요':money(r.breakEvenAverage)+' / 상자';
   $('sim-break-even-note').textContent=r.paidBoxes?`판매 ${number(r.paidBoxes)}상자를 모두 팔 때, 선물 ${number(r.giftBoxes)}상자의 비용과 기존 장부 손익을 포함한 기준입니다.`:'판매 수량이 0이면 손익분기 판매가는 계산하지 않습니다. 선물 비용은 손익에 반영합니다.';
   $('sim-impact').textContent=`2kg·5kg의 상자당 가격을 함께 1,000원 올리면, 예상 수입과 손익이 ${money(r.paidBoxes*1000)} 늘어납니다. 선물은 0원이며 수량과 비용은 그대로입니다.`;
   const scale=Math.max(1,...rows.map(v=>Math.abs(v.profit)));
   for(const v of rows){
    const label=v.delta===0?'현재 입력 가격':(v.delta>0?'+':'−')+money(Math.abs(v.delta));
    const row=node('tr',undefined,v.delta===0?'current':'');for(const value of [label,money(v.price2),money(v.price5),money(v.revenue),money(v.profit)])row.append(node('td',value));$('sim-comparison-rows').append(row);
    const barRow=node('div',undefined,'sim-bar-row'+(v.delta===0?' current':'')),track=node('div',undefined,'sim-bar-track'),bar=node('i',undefined,v.profit<0?'negative':'');const width=Math.abs(v.profit)/scale*50;bar.style.width=width+'%';bar.style.left=(v.profit<0?50-width:50)+'%';track.append(bar);barRow.append(node('span',v.delta===0?'현재':label),track,node('span',money(v.profit),'sim-bar-value'));$('sim-bars').append(barRow);
   }
   $('sim-placeholder').hidden=true;$('sim-results').hidden=false;$('sim-comparison').hidden=false;
  }catch(e){$('sim-input-message').textContent=e.message;}
 }
 async function load(){
  if(loading||!api.hasSession()||!$('sim-year-form').reportValidity())return;
  const ticket=epoch,year=Number($('sim-year').value);loading=true;hideData();disabled(true);message('장부와 재고를 불러오고 있습니다.');
  try{
   const responses=await Promise.allSettled([
    api.admin('farmer_admin_finance_report',{p_year:year,p_kind:'',p_search:'',p_offset:0}),
    api.admin('farmer_admin_summary'),api.rpc('farmer_catalog'),api.admin('farmer_admin_free_gift_summary',{p_year:year})
   ]);
   if(ticket!==epoch)return;const failures=responses.filter(r=>r.status==='rejected');if(failures.length)throw failures[0].reason;
   const [report,inventory,products,giftReport]=responses.map(r=>r.value);
   if(!report?.summary||!Array.isArray(report.categories)||!Array.isArray(products?.products)||!inventory)throw Error('장부·재고·현재 판매가를 확인하지 못했습니다. 다시 불러와 주세요.');
   const s=report.summary;
   const expense=Number(s.expense),income=Number(s.order_income)+Number(s.manual_income),availableKg=Number(inventory.available_kg);
   if(Number(report.year)!==year||![expense,income].every(v=>Number.isSafeInteger(v)&&v>=0)||!Number.isFinite(availableKg)||availableKg<0||!['hopungmi-2kg','hopungmi-5kg'].every(id=>products.products.some(p=>p.id===id&&Number.isSafeInteger(p.price)&&p.price>=0)))throw Error('장부·재고·현재 판매가를 확인하지 못했습니다. 다시 불러와 주세요.');
   if(giftReport?.year!==year||!giftReport?.totals||!Array.isArray(giftReport.people)||!['boxes','qty5','qty2','pending_boxes','reserved_boxes'].every(k=>Number.isSafeInteger(giftReport.totals[k])&&giftReport.totals[k]>=0))throw Error('무상 선물 수량을 확인하지 못했습니다. 다시 불러와 주세요.');
   base={expense,income,availableKg,year};catalog=products.products;gifts=giftReport;
   $('sim-gift-registered5').value=gifts.totals.qty5;
   $('sim-gift-count-note').textContent=`${year}년 등록 기준 · 전체 무상 선물 ${number(gifts.totals.boxes)}상자 / ${number(gifts.totals.kg)}kg${gifts.totals.qty2?' · 2kg '+number(gifts.totals.qty2)+'상자 포함':''} · 접수 대기 ${number(gifts.totals.pending_boxes)}상자. 취소·삭제 제외.`;
   for(const person of gifts.people){const line=node('p',person.sponsor+' · 5kg '+number(person.qty5)+'상자'+(person.qty2?' / 2kg '+number(person.qty2)+'상자':''),'sim-note');$('sim-gift-people').append(line);}
   $('sim-expense').textContent=money(expense);$('sim-income').textContent=money(income);$('sim-stock').textContent=number(availableKg)+'kg';$('sim-updated').textContent=year+'년 장부 · '+new Date().toLocaleString('ko-KR',{timeZone:'Asia/Seoul',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'});
   for(const c of report.categories)$('sim-categories').append(node('span',c.category+' '+money(c.amount)));
   if(!report.categories.length)$('sim-categories').append(node('span','아직 기록한 지출이 없습니다.'));
   $('sim-baseline-note').textContent=`${year}년 장부 전체 지출을 반영했습니다. 기존 수입에는 입금 확인·배송 중·배송 완료인 일반 주문 수입 ${money(s.order_income)}과 추가 수입 ${money(s.manual_income)}을 포함합니다. 현재 입금 대기 ${number(inventory.pending)}건은 재고에서 아직 차감되지 않았습니다.`;
   if(!initialized){fillStock();resetPrices();initialized=true;}
   $('sim-data').hidden=false;message('');
  }catch(e){if(ticket===epoch){hideData();message(e.message,true);}}
  finally{if(ticket===epoch){loading=false;disabled(false);render();}}
 }
 function clear(){epoch++;loading=false;initialized=false;hideData();$('sim-form').reset();for(const k of [2,5])$('sim-price'+k+'-range').max=50000;$('sim-year-form').reset();$('sim-year').value=todayYear();for(const id of ids)$(id).removeAttribute('aria-invalid');$('sim-plan-note').classList.remove('error');$('simulator-panel').hidden=true;message('');disabled(false);syncSliders();}
 function init(){
  $('sim-year').value=todayYear();$('sim-year-form').addEventListener('submit',e=>{e.preventDefault();load();});
  $('sim-year').addEventListener('input',()=>{if(!loading){hideData();message('연도를 바꿨습니다. 장부·재고 새로고침을 눌러 주세요.');}});
  $('sim-form').addEventListener('submit',e=>{e.preventDefault();render();});$('sim-form').addEventListener('input',e=>{if(e.target.dataset.priceInput)$(e.target.dataset.priceInput).value=e.target.value;render();});$('sim-form').addEventListener('change',e=>{if(e.target.dataset.priceInput)$(e.target.dataset.priceInput).value=e.target.value;render();});
  $('sim-fill-stock').addEventListener('click',()=>{fillStock();render();});$('sim-reset-prices').addEventListener('click',()=>{resetPrices();render();});
 }
 window.FarmerSimulator=Object.freeze({init,clear,show:view=>{if(view==='simulator')load();}});
})();
