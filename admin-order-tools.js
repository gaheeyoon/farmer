/* Order archival is reversible; recipient export data stays in memory until download. */
(() => {
 'use strict';const $=id=>document.getElementById(id),api=window.FarmerAPI;
 let ctx=null,current=null,busy=false,pending=null,exporting=false,epoch=0;
 const eligible=o=>o&&!o.deleted_at&&['pending','confirmed','cancelled'].includes(o.status);
 const locked=()=>busy||!!pending||exporting;
 const tell=(t,error=false)=>{$('order-tools-message').textContent=t;$('order-tools-message').classList.toggle('error',error);};
 function sync(){
  if(!ctx)return;const s=ctx.state(),orders=s.selected,deleted=s.filters.p_status==='deleted',blocked=!s.canStart||locked();
  $('archive-selected').textContent=pending?'처리 결과 다시 확인':deleted?'선택 주문 복원':'선택 주문 삭제';
  $('archive-selected').disabled=busy||exporting||(!pending&&(blocked||!orders.length||!orders.every(o=>deleted?!!o.deleted_at:eligible(o))));
  for(const [kind,label]of [['orders','주문 내역 (엑셀)'],['courier','택배 배송용 주문 내역 (엑셀)'],['sms','문자 발송용 주문 내역 (엑셀)']]){const button=$('export-'+kind);button.disabled=blocked;button.textContent=exporting===kind?'엑셀 준비 중…':label;}
  $('archive-order').hidden=!current;$('archive-order').textContent=pending?'처리 결과 다시 확인':current?.deleted_at?'주문 복원':'주문 삭제';
  $('archive-order').disabled=busy||exporting||(!pending&&(blocked||!(current?.deleted_at||eligible(current))));
  document.querySelectorAll('[data-close="order-dialog"]').forEach(b=>{if(locked())b.disabled=true;else if(!window.FarmerDelivery.locked())b.disabled=false;});
 }
 function clear(){epoch++;current=null;busy=false;pending=null;exporting=false;tell('');sync();}
 function setOrder(o){current=o;$('archive-order-note').textContent=o.deleted_at?'삭제된 주문입니다. 복원해도 취소 상태와 복구된 재고는 유지됩니다.':eligible(o)?'삭제 시 취소 처리와 필요한 재고 복원을 함께 진행합니다. 입금된 금액의 환불은 별도로 처리해 주세요.':'배송·수령이 시작되거나 완료된 주문은 안전을 위해 삭제할 수 없습니다.';sync();}
 async function archive(detail=false){
  if(busy||exporting)return;
  if(!pending){const s=ctx.state();if(!s.canStart)return;const orders=detail?[current]:s.selected,restore=orders.every(o=>!!o?.deleted_at);
   if(!orders.length||!orders.every(o=>restore?!!o?.deleted_at:eligible(o)))return;
   const kg=orders.filter(o=>o.status==='confirmed').reduce((n,o)=>n+Number(o.weight_grams),0)/1000;
   const note=restore?'취소 상태로 목록에 복원합니다. 재고는 다시 차감되지 않습니다.':`기본 목록과 고객 조회에서 제외합니다. 주문·재고 이력은 보존되며 ‘삭제된 주문’에서 복원할 수 있습니다.\n${kg?`확보했던 재고 ${kg}kg을 복구합니다. `:''}입금된 금액은 별도로 환불해 주세요.`;
   if(!confirm(`${orders.length}건을 ${restore?'복원':'삭제'}할까요?\n${note}`))return;
   pending={p_orders:orders.map(o=>({order_id:o.id,expected_version:o.version})),p_restore:restore,p_request_id:api.uuid()};
  }
  const ticket=epoch;busy=true;ctx.changed();sync();tell('처리하고 있습니다.');
  let result;
  try{result=await api.admin('farmer_admin_archive_orders',pending);if(ticket!==epoch)return;if(!result?.saved)throw Object.assign(new Error('처리 결과를 확인하지 못했습니다.'),{uncertain:true});}
  catch(e){if(ticket!==epoch)return;if(!e.uncertain)pending=null;tell(e.uncertain?'처리 결과를 확인하지 못했습니다. ‘처리 결과 다시 확인’을 눌러 주세요. 중복 취소·재고 복원은 발생하지 않습니다.':e.message,true);return;}
  finally{if(ticket===epoch){busy=false;ctx.changed();sync();}}
  if(ticket!==epoch)return;pending=null;ctx.changed();sync();
  await ctx.saved(`${result.count}건을 ${result.restored?'복원':'삭제'}했습니다.${Number(result.returned_kg)>0?' 재고 '+result.returned_kg+'kg을 복구했습니다.':''}`);
 }
 const dt=v=>v?new Date(v).toLocaleString('sv-SE',{timeZone:'Asia/Seoul'}):'';
 const columns=[['주문번호','order_number',22],['접수일시(한국시간)','created_at',24,dt],['주문 구분','order_kind',16,v=>v==='gift'?'무상 선물':'일반 주문'],['선물 링크 주문','is_link_gift',16,v=>v?'예':'아니오'],['상태','status',22,(v,o)=>o.deleted_at?'삭제됨(취소)':({pending:'입금 대기',confirmed:'입금 확인(준비)',shipped:'배송·수령 중',shipped_unpaid:'배송 중 · 미입금',delivered:'배송·수령 완료',cancelled:'취소'})[v]||v],['수령 방식','fulfillment_method',16,v=>v==='pickup'?'방문 수령':'배송'],['상품','product_name',26],['주문 전체 수량','order_quantity',16,null,true],['상자 순번','parcel_label',14],['수량','quantity',10,null,true],['중량(kg)','weight_grams',14,v=>Number(v)/1000,true],['상품 금액(상자별)','subtotal',16,Number,true],['할인코드','discount_code',24],['할인 금액(상자별)','discount_amount',16,Number,true],['배송비(상자별)','shipping_fee',14,Number,true],['결제 금액(상자별)','total',18,Number,true],['선물하는 사람','gift_sponsor',18,(v,o)=>v||(Number(o.unit_price)>0&&Number(o.discount_amount)>=Number(o.unit_price)?({'고구맙습니다홍세환선물용':'홍세환','고구맙습니다윤가희선물용':'윤가희'})[o.discount_code]||'':'')],['주문자','customer_name',18],['주문자 연락처','phone',20],['받는 분','recipient_name',18],['받는 분 연락처','recipient_phone',20],['우편번호','postal_code',12],['주소','address',48],['상세주소','address_detail',32],['배송 메모','memo',40],['택배사/배송 방법','carrier',22],['송장번호','tracking_number',26],['입금 확인일시','confirmed_at',24,dt],['발송일시','shipped_at',24,dt],['완료일시','delivered_at',24,dt],['취소일시','cancelled_at',24,dt],['삭제일시','deleted_at',24,dt]].map(([title,key,width,convert,number])=>({title,width,number,decimal:key==='weight_grams',value:o=>convert?convert(o[key],o):o[key]??''}));
 // Fixed courier template: never append internal/payment/tracking columns here.
 const courierHeaders=['주문번호','상품','수량','중량(kg)','받는 분','받는 분 연락처','우편번호','주소','상세주소','배송 메모'];
 const courierColumns=courierHeaders.map(title=>columns.find(column=>column.title===title));
 const smsColumns=[['이름','recipient_name',18],['연락처','recipient_phone',20],['송장번호','tracking_number',26]].map(([title,key,width])=>({title,width,value:o=>o[key]??''}));
 async function download(kind='orders'){
  const s=ctx.state();if(!s.canStart||locked())return;const ticket=epoch,filters={...s.filters};exporting=kind;ctx.changed();sync();tell('현재 검색 조건의 전체 주문을 준비하고 있습니다.');
  try{const result=await api.admin('farmer_admin_export_orders',filters);if(ticket!==epoch)return;
   if(!Array.isArray(result?.orders)||result.orders.length!==result.total)throw Error('전체 주문을 확인하지 못했습니다. 다시 시도해 주세요.');
   if(!result.total){tell('조건에 맞는 주문이 없습니다.');return;}
   const rows=window.FarmerParcels.exportRows(result.orders);
   const blob=window.FarmerXlsx.build(kind==='sms'?smsColumns:kind==='courier'?courierColumns:columns,rows,{header:kind!=='sms'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`고구맙습니다_${kind==='sms'?'문자발송용':kind==='courier'?'택배사용':'주문내역'}_${dt(result.exported_at||new Date()).replace(/[^0-9]/g,'')}.xlsx`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);tell(`${result.total}건의 주문을 ${rows.length}상자 · ${rows.length}행으로 내려받았습니다. ${kind==='sms'?'받는 분의 이름·연락처·송장번호만 제목 행 없이 포함했습니다.':'연락처·주소가 포함되어 있으니 안전하게 보관해 주세요.'}`);
  }catch(e){if(ticket===epoch)tell(e.message,true);}finally{if(ticket===epoch){exporting=false;ctx.changed();sync();}}
 }
 function init(options){ctx=options;$('archive-selected').addEventListener('click',()=>archive());$('archive-order').addEventListener('click',()=>archive(true));for(const kind of ['orders','courier','sms'])$('export-'+kind).addEventListener('click',()=>download(kind));$('order-dialog').addEventListener('cancel',e=>{if(locked())e.preventDefault();});$('order-dialog').addEventListener('close',()=>{current=null;});window.addEventListener('beforeunload',e=>{if(pending||busy){e.preventDefault();e.returnValue='';}});sync();}
 window.FarmerOrderTools=Object.freeze({init,clear,setOrder,sync,locked});
})();
