/* Parcel slots never split inventory, payment or order identities. */
(() => {
 'use strict';
 const pickup=o=>o.fulfillment_method==='pickup'||o.product_id==='hopungmi-5kg-pickup';
 const qty=o=>{if(!Number.isInteger(o.quantity)||o.quantity<1||o.quantity>99)throw Error('주문 수량을 확인해 주세요.');return o.quantity;};
 function values(o){
  const n=qty(o);if(pickup(o))return Array(n).fill('');
  const source=Array.isArray(o.tracking_numbers)&&o.tracking_numbers.length?o.tracking_numbers:[o.tracking_number||''];
  if(source.length>n||source.some(v=>typeof v!=='string'||v.length>100))throw Error('상자별 송장 정보를 다시 불러와 주세요.');
  return Array.from({length:n},(_,i)=>source[i]||'');
 }
 function mount(container,o,prefix,drafts=new Map()){
  container.replaceChildren();container.classList.add('parcel-grid');
  values(o).forEach((value,i)=>{
   const label=document.createElement('label'),text=document.createElement('span'),input=document.createElement('input');
   text.textContent=`상자 ${i+1} / ${o.quantity}`;input.id=prefix+'-'+i;input.dataset.parcelKey=o.id+':'+i;
   input.dataset.orderId=o.id;input.dataset.parcelIndex=i;input.maxLength=100;input.autocomplete='off';input.placeholder='송장번호';
   input.value=drafts.get(input.dataset.parcelKey)??value;input.setAttribute('aria-label',`${o.order_number||'주문'} 상자 ${i+1} 송장번호`);
   input.addEventListener('input',()=>input.setCustomValidity(''));label.append(text,input);container.append(label);
  });
 }
 function encoded(container){
  const inputs=[...container.querySelectorAll('input')],seen=new Set(),numbers=[];
  for(const input of inputs){const value=input.value.trim();input.setCustomValidity(value&&seen.has(value)?'상자마다 다른 송장번호를 입력해 주세요.':'');if(!input.reportValidity())throw Error('상자별 송장번호를 확인해 주세요.');if(value)seen.add(value);numbers.push(value);}
  return JSON.stringify(numbers);
 }
 const describe=o=>pickup(o)?'방문 수령':values(o).map((v,i)=>`상자 ${i+1} / ${o.quantity} · ${v||'미입력'}`).join('\n');
 function exportRows(orders,max=30000){
  const count=orders.reduce((n,o)=>n+qty(o),0);if(count>max)throw Error(`상자별 엑셀은 한 번에 ${max.toLocaleString('ko-KR')}행까지 만들 수 있습니다. 검색 조건을 좁혀 주세요.`);
  const split=(value,n,i)=>{if(!Number.isSafeInteger(value)||value<0)throw Error('주문 금액과 중량을 확인해 주세요.');return Math.floor(value/n)+(i<value%n?1:0);};
  return orders.flatMap(o=>values(o).map((tracking,i)=>{
   const n=o.quantity,subtotal=split(o.subtotal,n,i),discount=split(o.discount_amount,n,i),shipping=split(o.shipping_fee,n,i);
   if(o.total!==o.subtotal-o.discount_amount+o.shipping_fee)throw Error('주문 금액의 합계를 확인해 주세요.');
   return {...o,order_quantity:n,parcel_index:i+1,parcel_label:`${i+1} / ${n}`,quantity:1,
    weight_grams:split(o.weight_grams,n,i),subtotal,discount_amount:discount,shipping_fee:shipping,total:subtotal-discount+shipping,
    // Preserve original discount eligibility when financial fields are allocated across boxes.
    gift_sponsor:o.gift_sponsor||(o.unit_price>0&&o.discount_amount>=o.unit_price?({'고구맙습니다홍세환선물용':'홍세환','고구맙습니다윤가희선물용':'윤가희'})[o.discount_code]||'':''),
    tracking_number:tracking};
  }));
 }
 globalThis.FarmerParcels=Object.freeze({values,mount,encoded,describe,exportRows});
})();
