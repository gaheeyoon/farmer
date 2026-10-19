(() => {
 'use strict';
 const $=id=>document.getElementById(id),C=window.GiftCommon,api=window.FarmerAPI,{node,money}=C;
 let query=null,offset=null,busy=false,revision=0;
 const tell=(id,text)=>$(id).textContent=text;
 const date=v=>v?new Date(v).toLocaleDateString('ko-KR',{timeZone:'Asia/Seoul'}):'';
 function prefill(){try{const s=JSON.parse(localStorage.getItem('farmer-orderer:v1')||'null');if(s&&!query){$('sent-gifts-name').value=String(s.name||'').slice(0,40);$('sent-gifts-phone').value=C.formatPhone(String(s.phone||''));}}catch{}}
 function clear(){revision++;query=null;offset=null;$('sent-gifts-results').hidden=true;$('sent-gifts-cards').replaceChildren();$('sent-gifts-more').hidden=true;tell('sent-gifts-status','');tell('sent-gifts-copy-status','');}
 async function card(g){
  const local=C.savedGift(g.order_number);let proof=null;
  if(local){try{const v=await api.rpc('farmer_gift_view',{p_token:local.token});if(v?.found)proof=v;}catch{}}
  const el=node('article',undefined,'gift-link-card'),state=proof?.state||g.state;
  el.append(node('h3',(proof?.recipient_label||g.recipient_label)+'님께 보낸 선물'),node('p',g.product_name+' × '+g.quantity));
  const badges=node('div',undefined,'sent-gift-statuses'),statusLabels={pending:Number(g.total)===0?'주문 확인 대기':'입금 대기',confirmed:'입금 확인(배송 준비)',shipped:'배송 중',delivered:'배송 완료',cancelled:'취소'};
  badges.append(node('span',statusLabels[g.status]||g.status,'gift-link-state '+state));
  if(g.status!=='pending'&&g.status!=='cancelled')badges.append(node('span',{ready:'배송지 등록 대기',claimed:'배송지 등록 완료',expired:'주소 등록 기한 만료'}[state]||'상태 확인 필요','gift-link-state '+state));
  el.append(badges);
  if(proof?.message)el.append(node('p',proof.message,'gift-written'));
  el.append(node('p',date(g.created_at)+' · '+g.order_number,'sent-gift-meta'));
  if(g.expires_at&&state==='ready')el.append(node('p','주소 등록 기한 '+date(g.expires_at),'sent-gift-meta'));
  const awaitingPayment=g.status==='pending'&&state==='pending'&&Number(g.total)>0;
  const price=node('div',undefined,'sent-gift-price');price.append(node('span',awaitingPayment?'입금하실 금액':'구매 금액'),node('strong',money(g.total)));if(awaitingPayment){price.classList.add('sent-gift-price-pending');price.append(window.FarmerBank.create());}el.append(price);
  if(['ready','claimed'].includes(state)&&proof&&local){
   const input=node('input');input.readOnly=true;input.value=C.giftURL(local.token);input.setAttribute('aria-label','선물 링크');
   const button=node('button','선물 링크 복사','gift-button secondary');button.type='button';
   button.addEventListener('click',async()=>{
    button.disabled=true;
    try{const fresh=await api.rpc('farmer_gift_view',{p_token:local.token});if(!fresh.found||!['ready','claimed'].includes(fresh.state)){input.remove();button.remove();tell('sent-gifts-copy-status','선물 상태가 변경되었습니다. 다시 조회해 주세요.');return;}tell('sent-gifts-copy-status',await C.copy(input.value,input)?'선물 링크를 복사했습니다. 받는 분께 보내 주세요.':'선택된 링크를 직접 복사해 주세요.');}catch{input.remove();button.remove();tell('sent-gifts-copy-status','상태를 확인하지 못했습니다. 다시 조회해 주세요.');}finally{button.disabled=false;}
   });el.append(input,button);
  }else{
   const text=state==='pending'?(Number(g.total)===0?'주문 확인 후 선물 링크가 표시됩니다.':'입금 확인 후 선물 링크가 표시됩니다. 입금 확인에는 평일 기준 1일이 소요됩니다.'):state==='cancelled'?'취소된 선물입니다.':state==='expired'?'기한 연장이 필요하면 판매자에게 문의해 주세요.':local?'선물 링크 상태를 확인하지 못했습니다. 다시 조회해 주세요.':'선물 링크는 구매한 브라우저에서 확인할 수 있습니다. 다른 기기라면 판매자에게 문의해 주세요.';
   el.append(node('p',text,'gift-status'));
  }
  return el;
 }
 async function load(append=false){
  if(busy||!query)return;const ticket=revision;
  busy=true;$('sent-gifts-submit').disabled=true;$('sent-gifts-more').disabled=true;tell('sent-gifts-status','선물 구매 내역을 확인하고 있습니다.');
  if(!append){$('sent-gifts-cards').replaceChildren();$('sent-gifts-results').hidden=true;}
  try{
   const r=await api.rpc('farmer_lookup_gifts',{...query,p_offset:append?offset:0});if(ticket!==revision)return;
   if(!r?.found){tell('sent-gifts-status',r?.retry_after?'조회가 잠시 제한되었습니다. 잠시 후 다시 확인해 주세요.':'입력하신 정보와 일치하는 선물 구매 내역이 없습니다.');return;}
   const cards=await Promise.all(r.gifts.map(card));if(ticket!==revision)return;
   $('sent-gifts-cards').append(...cards);offset=r.next_offset;$('sent-gifts-more').hidden=offset===null;
   tell('sent-gifts-count','총 '+r.total_count+'건');tell('sent-gifts-status','');$('sent-gifts-results').hidden=false;
   if(!append&&!$('sent-gifts-panel').hidden)$('sent-gifts-heading').focus();
  }catch(e){if(ticket===revision)tell('sent-gifts-status',e.message);}finally{busy=false;$('sent-gifts-submit').disabled=false;$('sent-gifts-more').disabled=false;}
 }
 $('sent-gifts-form').addEventListener('input',e=>{e.target.setCustomValidity?.('');clear();});
 $('sent-gifts-form').addEventListener('submit',e=>{e.preventDefault();if(busy)return;C.phoneValid($('sent-gifts-phone'));$('sent-gifts-name').setCustomValidity($('sent-gifts-name').value.trim()?'':'성함을 입력해 주세요.');if(!$('sent-gifts-form').reportValidity())return;clear();query={p_customer_name:$('sent-gifts-name').value.trim(),p_phone:$('sent-gifts-phone').value};load();});
 $('sent-gifts-more').addEventListener('click',()=>{if(offset!==null)load(true);});
 window.addEventListener('farmer:viewchange',e=>{if(e.detail.view==='sent')prefill();});
 window.addEventListener('pageshow',e=>{if(e.persisted)clear();});prefill();
})();
