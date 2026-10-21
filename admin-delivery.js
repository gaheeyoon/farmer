/* Admin-only shipping edits. Drafts and recipient details stay in memory. */
(() => {
 'use strict';
 const $=id=>document.getElementById(id),api=window.FarmerAPI,C=window.GiftCommon,P=window.FarmerParcels;
 const keys=['recipient_name','recipient_phone','postal_code','address','address_detail','memo','carrier'];
 const input=k=>$('edit-delivery-'+k),form=$('delivery-edit-form');
 let order=null,editing=false,dirty=false,busy=false,pending=null,epoch=0,onSaved=async()=>{};
 const pickup=o=>o?.product_id==='hopungmi-5kg-pickup'||o?.fulfillment_method==='pickup';
 const frozen=()=>busy||!!pending;
 const tell=(text,error=false)=>{$('delivery-edit-status').textContent=text;$('delivery-edit-status').classList.toggle('error',error);};
 function sync(){
  form.hidden=!editing;$('order-details').hidden=editing;$('order-fulfillment-controls').hidden=editing;
  $('edit-delivery-open').hidden=editing;$('edit-delivery-open').disabled=!order||!!(order.awaiting_address&&order.status!=='confirmed');
  $('delivery-edit-fields').disabled=frozen();$('edit-delivery-cancel').disabled=frozen();
  $('edit-delivery-save').disabled=busy;$('edit-delivery-save').textContent=busy?'저장 중…':pending?'저장 결과 다시 확인':'배송 정보 저장';
  document.querySelectorAll('[data-close="order-dialog"]').forEach(b=>b.disabled=frozen());
 }
 function clear(){epoch++;order=null;editing=false;dirty=false;busy=false;pending=null;form.reset();$('edit-delivery-tracking_number').replaceChildren();form.querySelectorAll('input,textarea').forEach(e=>e.setCustomValidity(''));$('edit-delivery-search').disabled=false;$('delivery-edit-search-embed').replaceChildren();$('delivery-edit-search-panel').hidden=true;tell('');$('delivery-edit-availability').textContent='';sync();}
 function setOrder(o){clear();order=o;$('delivery-edit-availability').textContent=o.awaiting_address&&o.status!=='confirmed'?'배송지가 등록되지 않은 선물은 입금 확인 후 수정할 수 있습니다.':'';sync();}
 function start(){
  if(!order||frozen()||order.awaiting_address&&order.status!=='confirmed')return;
  editing=true;dirty=false;for(const k of keys)input(k).value=String(order[k]||'');
  input('recipient_name').value=order.recipient_name||order.customer_name||'';input('recipient_phone').value=C.formatPhone(order.recipient_phone||order.phone||'');
  P.mount($('edit-delivery-tracking_number'),order,'edit-parcel');
  const isPickup=pickup(order);$('delivery-edit-address-fields').hidden=isPickup;$('delivery-edit-tracking-fields').hidden=isPickup;
  for(const k of ['postal_code','address'])input(k).required=!isPickup;
  input('carrier').required=!isPickup&&['shipped','delivered'].includes(order.status);
  $('delivery-edit-context').textContent=order.awaiting_address?'관리자가 배송지를 등록하면 받는 분의 추가 주소 등록은 종료됩니다.':isPickup?'방문 수령 주문입니다. 받는 분과 수령 메모를 수정할 수 있습니다.':['shipped','delivered'].includes(order.status)?'사이트에 저장된 배송 기록을 수정합니다. 실제 배송지 변경은 택배사 확인이 필요합니다.':'';
  $('delivery-edit-memo-label').textContent=isPickup?'수령 메모':'배송 메모';tell('');sync();input('recipient_name').focus();
 }
 function canClose(){if(frozen())return false;if(editing&&dirty&&!confirm('수정한 배송 정보를 저장하지 않고 닫을까요?'))return false;return true;}
 function cancel(){if(!canClose())return;editing=false;dirty=false;form.reset();$('delivery-edit-search-panel').hidden=true;tell('');sync();$('edit-delivery-open').focus();}
 async function save(e){
  e.preventDefault();if(busy||!order)return;
  if(!pending){
   C.phoneValid(input('recipient_phone'));input('recipient_name').setCustomValidity(input('recipient_name').value.trim()?'':'받는 분 성함을 입력해 주세요.');
   input('address').setCustomValidity(pickup(order)||input('address').value.trim().length>=5?'':'배송 주소를 확인해 주세요.');
   if(!form.reportValidity())return;
   let tracking;try{tracking=pickup(order)?'':P.encoded($('edit-delivery-tracking_number'));}catch(error){tell(error.message,true);return;}
   const delivery=Object.fromEntries(keys.map(k=>[k,input(k).value.trim()]));delivery.tracking_number=tracking;delivery.recipient_phone=delivery.recipient_phone.replace(/\D/g,'');
   pending={p_order_id:order.id,p_expected_version:order.version,p_request_id:api.uuid(),p_delivery:delivery};
  }
  const ticket=epoch;busy=true;sync();tell('배송 정보를 저장하고 있습니다.');
  let result;
  try{result=await api.admin('farmer_admin_update_delivery',pending);if(ticket!==epoch)return;if(!result?.saved)throw Object.assign(new Error('저장 결과를 확인하지 못했습니다.'),{uncertain:true});}
  catch(error){if(ticket!==epoch)return;if(!error.uncertain)pending=null;tell(error.uncertain?'저장 결과를 확인하지 못했습니다. 같은 버튼으로 다시 확인해 주세요.':error.message,true);return;}
  finally{if(ticket===epoch){busy=false;sync();}}
  if(ticket!==epoch)return;pending=null;editing=false;dirty=false;form.reset();sync();
  await onSaved(result);
 }
 function init(callback){
  onSaved=callback;$('edit-delivery-open').addEventListener('click',start);$('edit-delivery-cancel').addEventListener('click',cancel);form.addEventListener('submit',save);
  form.addEventListener('input',e=>{dirty=true;e.target.setCustomValidity?.('');});
  $('order-dialog').addEventListener('cancel',e=>{if(!canClose())e.preventDefault();});$('order-dialog').addEventListener('close',clear);
  $('edit-delivery-search').addEventListener('click',async()=>{
   if(frozen())return;const ticket=epoch;$('delivery-edit-search-panel').hidden=false;$('edit-delivery-search').disabled=true;$('delivery-edit-search-status').textContent='주소 검색을 불러오고 있습니다.';
   try{const P=await C.postcode();if(ticket!==epoch||!editing||frozen()||$('delivery-edit-search-panel').hidden)return;new P({width:'100%',height:'100%',onresize:s=>$('delivery-edit-search-embed').style.height=s.height+'px',oncomplete:d=>{if(ticket!==epoch||!editing||frozen())return;input('postal_code').value=d.zonecode;input('address').value=d.userSelectedType==='R'?d.roadAddress:d.jibunAddress;input('address_detail').value='';input('postal_code').setCustomValidity('');input('address').setCustomValidity('');dirty=true;$('delivery-edit-search-panel').hidden=true;input('address_detail').focus();}}).embed($('delivery-edit-search-embed'));$('delivery-edit-search-status').textContent='도로명·건물명·지번으로 검색해 주세요.';}catch(error){if(ticket===epoch)$('delivery-edit-search-status').textContent=error.message;}finally{if(ticket===epoch)$('edit-delivery-search').disabled=false;}
  });
  $('edit-delivery-search-close').addEventListener('click',()=>{$('delivery-edit-search-panel').hidden=true;$('edit-delivery-search').focus();});
  window.addEventListener('beforeunload',e=>{if(frozen()||editing&&dirty){e.preventDefault();e.returnValue='';}});sync();
 }
 window.FarmerDelivery=Object.freeze({init,setOrder,clear,canClose,locked:()=>editing||frozen()});
})();
