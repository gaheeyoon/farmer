(() => {
 'use strict';
 const $=id=>document.getElementById(id),api=window.FarmerAPI,C=window.GiftCommon,{node,money}=C;
 const form=$('gift-purchase-form'),cards=()=>[...$('gift-recipients').children],field=(c,n)=>c.querySelector(`[data-field="${n}"]`);
 const storageKey='farmer-gift-purchase:v1';let products=[],seq=0,busy=false,prepared=null,pending=null,receipt=null,code='',quoteRevision=0,receiptEpoch=0,statusBusy=false,awaitingPayment=false;
 const items=()=>cards().map(c=>({product_id:field(c,'product_id').value,quantity:Number(field(c,'quantity').value),recipient_label:field(c,'recipient_label').value.trim(),message:field(c,'message').value.trim()}));
 const tell=(id,text,error=false)=>{$(id).textContent=text;$(id).classList.toggle('error',error);};
 function remember(){try{sessionStorage.setItem(storageKey,JSON.stringify({pending,receipt,until:Date.now()+31*864e5}));}catch{}}
 function lock(){
  const reviewing=!!prepared||!!pending;
  $('purchase-fields').disabled=busy||reviewing;
  $('gift-review').disabled=busy||reviewing||!products.length;
  $('gift-review').hidden=reviewing;
  $('gift-save').disabled=busy||!reviewing;
  $('gift-edit').disabled=busy||!!pending;
  $('gift-save').textContent=busy?'저장 중…':pending?'신청 결과 다시 확인':'선물 구매 신청하기';
 }
 function preview(){const first=items()[0];$('preview-to').textContent='TO. '+(first?.recipient_label||'고마운 분께');const p=products.find(p=>p.id===first?.product_id);const sender=$('sender-name').value.trim();$('preview-sender').textContent=sender?`${sender.endsWith('님')?sender:sender+'님'}께서\n${p?.name||'고구마'}${first.quantity>1?' '+first.quantity+'상자':''}을 선물하셨습니다.`:'고마운 마음이 도착했습니다.';$('preview-message').textContent=first?.message||'전하고 싶은 마음을 적어 주세요.';}
 function update(){cards().forEach((c,i)=>{c.querySelector('[data-recipient-number]').textContent=i+1;c.querySelector('[data-remove]').hidden=cards().length===1;});$('gift-add-recipient').disabled=cards().length>=20;const subtotal=items().reduce((sum,d)=>sum+(products.find(p=>p.id===d.product_id)?.price||0)*(Number.isInteger(d.quantity)&&d.quantity>0?d.quantity:0),0);$('gift-total').textContent=money(subtotal);$('gift-discount-note').textContent=code?'할인 적용 금액은 선물 내용 확인 단계에서 다시 확인합니다.':'';preview();}
 function add(){if(busy||pending||cards().length>=20)return;const fragment=$('gift-recipient-template').content.cloneNode(true),card=fragment.querySelector('section'),id=++seq;for(const el of card.querySelectorAll('[data-field]')){el.id=`present-${id}-${el.dataset.field}`;card.querySelector(`[data-label="${el.dataset.field}"]`).htmlFor=el.id;}field(card,'product_id').replaceChildren(...products.map(p=>{const o=node('option',p.name+' · '+money(p.price)+(p.available?'':' · 재고 부족'));o.value=p.id;o.disabled=!p.available;return o;}));field(card,'product_id').value=products.find(p=>p.id==='hopungmi-5kg'&&p.available)?.id||products.find(p=>p.available)?.id||'';$('gift-recipients').append(fragment);update();}
 async function quote(){return api.rpc('farmer_quote_gifts',{p_deliveries:items().map(({product_id,quantity})=>({product_id,quantity})),p_code:code});}
 function receiptCard(g,state){
  const card=node('article',undefined,'gift-link-card');
  card.append(node('h3',g.recipient_label+'님께 보낼 선물'),node('p',g.product_name+' × '+g.quantity+' · '+g.order_number));
  const labels={pending:Number(g.total)===0?'주문 확인 대기':'입금 확인 대기',ready:'입금 확인 완료',claimed:'배송지 등록 완료',expired:'주소 등록 기한 만료',cancelled:'취소',unknown:'상태 확인 필요'};
  card.append(node('span',labels[state]||labels.unknown,'gift-link-state '+state));
  if(['ready','claimed'].includes(state)){
   const input=node('input');input.readOnly=true;input.value=C.giftURL(g.token);input.setAttribute('aria-label',g.recipient_label+'님 선물 링크');
   const button=node('button','선물 링크 복사','gift-button secondary');button.type='button';
   button.addEventListener('click',async()=>{
    button.disabled=true;
    try{
     const fresh=await api.rpc('farmer_gift_view',{p_token:g.token});
     if(!fresh.found||!['ready','claimed'].includes(fresh.state)){
      await refreshGiftStatus();tell('gift-copy-status','선물 상태가 변경되어 링크를 복사할 수 없습니다.',true);return;
     }
     tell('gift-copy-status',await C.copy(input.value,input)?'선물 링크를 복사했습니다. 받는 분께 직접 전달해 주세요.':'복사하지 못했습니다. 선택된 링크를 직접 복사해 주세요.');
    }catch(e){tell('gift-copy-status','선물 상태를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.',true);}
    finally{if(button.isConnected)button.disabled=false;}
   });
   card.append(input,button);
  }else{
   const messages={pending:Number(g.total)===0?'주문이 확인되면 선물 링크가 표시됩니다.':'입금이 확인되면 선물 링크가 표시됩니다.',expired:'기한 연장이 필요하면 판매자에게 문의해 주세요.',cancelled:'취소된 선물입니다.',unknown:'상태를 확인한 뒤 선물 링크를 표시합니다. 새로고침해 주세요.'};
   card.append(node('p',messages[state]||messages.unknown,'gift-status gift-status-muted'));
  }
  return card;
 }
 async function refreshGiftStatus(){
  if(statusBusy||!receipt||$('gift-receipt').hidden||document.getElementById('gift-order-panel')?.hidden)return;
  const ticket=++receiptEpoch,data=receipt;
  statusBusy=true;$('gift-status-refresh').disabled=true;
  tell('gift-status-note','입금 확인 상태를 불러오고 있습니다.');
  try{
   const results=await Promise.allSettled(data.gifts.map(g=>api.rpc('farmer_gift_view',{p_token:g.token})));
   if(ticket!==receiptEpoch||data!==receipt||$('gift-receipt').hidden)return;
   let unpaid=0,ready=0,unknown=0,pendingAmount=0;
   const cards=results.map((r,i)=>{
    const state=r.status==='fulfilled'&&r.value?.found?r.value.state:'unknown';
    if(state==='pending'){unpaid++;pendingAmount+=Number(data.gifts[i].total)||0;}
    if(['ready','claimed'].includes(state))ready++;
    if(state==='unknown')unknown++;
    return receiptCard(data.gifts[i],state);
   });
   $('gift-receipt-links').replaceChildren(...cards);
   awaitingPayment=unpaid>0||unknown>0;
   $('gift-bank').hidden=unpaid===0||pendingAmount===0;
   $('gift-payment-notice').hidden=unpaid===0;
   $('gift-pay-amount').textContent=money(pendingAmount);
   $('gift-payment-title').textContent=pendingAmount?'아래 계좌로 신청 금액을 입금해 주세요.':'추가 입금 없이 주문 확인을 기다려 주세요.';
   $('gift-payment-detail').textContent=pendingAmount?'입금 확인에는 평일 기준 1일이 소요됩니다. 입금이 확인되면 이 페이지에서 선물 링크를 복사할 수 있습니다.':'주문 확인에는 평일 기준 1일이 소요됩니다. 확인이 완료되면 이 페이지에서 선물 링크를 복사할 수 있습니다.';
   $('gift-payment-hint').hidden=pendingAmount===0;
   $('gift-share-hint').hidden=ready===0;
   $('gift-receipt-title').textContent=unpaid?(pendingAmount?'입금 후 선물을 전할 수 있어요.':'주문 확인 후 선물을 전할 수 있어요.'):ready?'선물 링크가 준비되었습니다.':'선물 신청 내역';
   $('gift-receipt-intro').textContent=unpaid?(pendingAmount?'선물 구매 신청서를 저장했습니다. 아래 계좌로 입금해 주세요.':'선물 구매 신청서를 저장했습니다. 추가 입금할 금액은 없습니다.'):ready?'입금 확인이 완료된 선물의 링크를 복사해 받는 분께 보내 주세요.':'선물의 현재 상태를 확인해 주세요.';
   tell('gift-status-note',unknown?'일부 선물의 상태를 확인하지 못했습니다. 다시 새로고침해 주세요.':'최근 확인 '+new Date().toLocaleTimeString('ko-KR',{hour:'2-digit',minute:'2-digit'}),unknown>0);
  }finally{
   if(ticket===receiptEpoch){statusBusy=false;$('gift-status-refresh').disabled=false;}
  }
 }
 function renderReceipt(data){
  if(!Array.isArray(data?.gifts)||!data.gifts.length)throw Object.assign(new Error('저장 결과를 확인하지 못했습니다.'),{uncertain:true});
  receipt=data;C.rememberReceipt(data);pending=null;prepared=null;remember();
  receiptEpoch++;statusBusy=false;awaitingPayment=true;
  $('gift-review-panel').hidden=true;$('purchase-panel').hidden=true;$('gift-receipt').hidden=false;
  $('gift-receipt-title').textContent='선물 구매 신청서를 저장했습니다.';
  $('gift-receipt-intro').textContent='입금 확인 상태를 확인하고 있습니다.';
  $('gift-bank').hidden=true;$('gift-payment-notice').hidden=true;$('gift-share-hint').hidden=true;
  $('gift-receipt-links').replaceChildren(...data.gifts.map(g=>receiptCard(g,'unknown')));
  const bank=window.FARMER_PAYMENT;$('gift-bank-owner').textContent=`${bank.bank} · 예금주 ${bank.holder}`;$('gift-bank-account').textContent=bank.account;
  if(!document.getElementById('gift-order-panel')?.hidden)$('gift-receipt').focus();refreshGiftStatus();
 }
 async function save(){if(busy||!prepared&&!pending)return;if(!pending){pending=prepared;remember();}busy=true;lock();tell('gift-save-status','선물 구매 신청서를 저장하고 있습니다.');try{const data=await api.rpc('farmer_buy_gifts',pending);renderReceipt(data);tell('gift-purchase-status','');}catch(e){if(!e.uncertain){pending=null;prepared=null;remember();}tell('gift-save-status',e.uncertain?'결과를 확인하지 못했습니다. 같은 버튼으로 신청 결과를 다시 확인해 주세요. 중복 주문되지 않습니다.':e.message,true);}finally{busy=false;lock();}}
 form.addEventListener('submit',async e=>{e.preventDefault();if(busy||pending)return;C.phoneValid($('buyer-phone'));for(const c of cards()){for(const n of ['recipient_label'])field(c,n).setCustomValidity(field(c,n).value.trim()?'':'받는 분 이름을 입력해 주세요.');}for(const id of ['buyer-name','sender-name'])$(id).setCustomValidity($(id).value.trim()?'':'성함을 입력해 주세요.');if(!form.reportValidity())return;busy=true;lock();tell('gift-purchase-status','선물 금액을 확인하고 있습니다.');try{code=$('gift-code').value.trim();const q=await quote();prepared={p_request_id:api.uuid(),p_customer_name:$('buyer-name').value.trim(),p_phone:$('buyer-phone').value,p_sender_name:$('sender-name').value.trim(),p_items:items(),p_code:code,p_expected_total:q.total,p_privacy_consent:true};$('gift-review-items').replaceChildren(...items().map((d,i)=>{const el=node('div',undefined,'gift-review-item');el.append(node('strong',d.recipient_label+'님께 · '+q.deliveries[i].product_name+' × '+d.quantity),node('p',d.message||'별도 메시지 없음'));return el;}));$('gift-review-total').textContent=money(q.total);tell('gift-save-status','');$('gift-review-panel').hidden=false;$('gift-review-panel').focus();tell('gift-purchase-status','');}catch(e){tell('gift-purchase-status',e.message,true);}finally{busy=false;lock();}});
 $('gift-save').addEventListener('click',save);$('gift-edit').addEventListener('click',()=>{if(!busy&&!pending){prepared=null;$('gift-review-panel').hidden=true;lock();$('gift-review').focus();}});
 $('gift-add-recipient').addEventListener('click',()=>{add();cards().at(-1)&&field(cards().at(-1),'recipient_label').focus();});
 $('gift-recipients').addEventListener('click',e=>{if(busy||pending)return;const card=e.target.closest('.gift-recipient');if(!card)return;if(e.target.closest('[data-remove]'))card.remove();if(e.target.closest('[data-message-preset]'))field(card,'message').value='고구맙습니다 💜';update();});
 form.addEventListener('input',e=>{if(e.target.setCustomValidity)e.target.setCustomValidity('');prepared=null;quoteRevision++;update();if(e.target.id==='buyer-name'&&!$('sender-name').dataset.edited)$('sender-name').value=e.target.value;if(['buyer-name','buyer-phone'].includes(e.target.id)){try{localStorage.setItem('farmer-orderer:v1',JSON.stringify({name:$('buyer-name').value.trim(),phone:$('buyer-phone').value.replace(/\D/g,'')}));}catch{}}if(e.target.id==='sender-name')$('sender-name').dataset.edited='true';preview();});form.addEventListener('change',update);
 $('gift-apply-code').addEventListener('click',async()=>{if(busy||pending)return;const revision=++quoteRevision;code=$('gift-code').value.trim();tell('gift-purchase-status','할인을 확인하고 있습니다.');try{const q=await quote();if(revision!==quoteRevision)return;$('gift-total').textContent=money(q.total);$('gift-discount-note').textContent=q.discount_amount?money(q.discount_amount)+' 할인 적용':'';tell('gift-purchase-status',code?'할인코드를 적용했습니다.':'할인코드를 해제했습니다.');}catch(e){if(revision===quoteRevision)tell('gift-purchase-status',e.message,true);}});
 $('gift-bank-copy').addEventListener('click',async()=>{const b=window.FARMER_PAYMENT;tell('gift-copy-status',await C.copy(b.bank.replace('은행','')+' '+b.account)?'계좌 정보를 복사했습니다.':'계좌번호를 직접 선택해 복사해 주세요.');});
 $('gift-new-purchase').addEventListener('click',()=>{receiptEpoch++;statusBusy=false;$('gift-receipt').hidden=true;$('purchase-panel').hidden=false;$('restore-gift').hidden=!receipt;$('purchase-panel').scrollIntoView({block:'start'});});$('restore-gift').addEventListener('click',()=>receipt&&renderReceipt(receipt));
 $('gift-status-refresh').addEventListener('click',refreshGiftStatus);
 window.addEventListener('farmer:viewchange',e=>{if(e.detail.view==='gift')refreshGiftStatus();});
 window.addEventListener('focus',()=>{if(!document.hidden)refreshGiftStatus();});
 document.addEventListener('visibilitychange',()=>{if(!document.hidden)refreshGiftStatus();});
 setInterval(()=>{if(awaitingPayment&&!document.hidden)refreshGiftStatus();},60000);
 async function init(){try{const saved=JSON.parse(localStorage.getItem('farmer-orderer:v1')||'null');if(saved){$('buyer-name').value=String(saved.name||'').slice(0,40);$('buyer-phone').value=C.formatPhone(String(saved.phone||''));$('sender-name').value=$('buyer-name').value;}}catch{}try{const saved=JSON.parse(sessionStorage.getItem(storageKey)||'null');if(saved?.until>Date.now()){pending=saved.pending||null;receipt=saved.receipt||null;if(receipt)C.rememberReceipt(receipt);}}catch{}try{const c=await api.rpc('farmer_catalog');products=c.products.filter(p=>p.id!=='hopungmi-5kg-pickup'&&p.fulfillment_method!=='pickup');add();lock();if(receipt&&!pending)renderReceipt(receipt);if(pending){$('gift-review-items').replaceChildren(...pending.p_items.map(d=>{const el=node('div',undefined,'gift-review-item');el.append(node('strong',d.recipient_label+'님께 · '+(products.find(p=>p.id===d.product_id)?.name||d.product_id)+' × '+d.quantity),node('p',d.message||'별도 메시지 없음'));return el;}));$('gift-review-total').textContent=money(pending.p_expected_total);$('gift-review-panel').hidden=false;if(!document.getElementById('gift-order-panel')?.hidden)$('gift-review-panel').focus();tell('gift-save-status','확인이 끝나지 않은 신청이 있습니다. 같은 요청의 결과를 다시 확인해 주세요.');lock();}if(!products.some(p=>p.available))tell('gift-purchase-status','현재 준비된 재고가 없습니다.',true);}catch(e){tell('gift-purchase-status',e.message,true);}}
 init();
})();
