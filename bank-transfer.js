/* One public bank account and copy behavior for guidance, receipts and footers. */
(() => {
 'use strict';
 const el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(cls)n.className=cls;return n;};
 async function copy(text){
  try{if(navigator.clipboard?.writeText){await navigator.clipboard.writeText(text);return true;}}catch{}
  const input=el('textarea');input.value=text;input.readOnly=true;input.tabIndex=-1;input.style.cssText='position:fixed;left:-9999px;top:0;font-size:16px';
  const active=document.activeElement;document.body.append(input);
  try{input.select();input.setSelectionRange(0,text.length);return document.execCommand('copy');}catch{return false;}finally{input.remove();active?.focus({preventScroll:true});}
 }
 function create(){
  const payment=window.FARMER_PAYMENT||{},box=el('aside',undefined,'bank-transfer');box.dataset.bankTransfer='';box.setAttribute('aria-label','입금 계좌 안내');
  const row=el('div',undefined,'bank-transfer-row'),number=el('span',String(payment.bank||'').replace(/은행$/,'')+' '+payment.account,'bank-transfer-number'),button=el('button','복사하기','bank-transfer-copy');
  button.type='button';button.setAttribute('aria-label','은행과 계좌번호 복사');const status=el('p',undefined,'bank-transfer-status');status.setAttribute('role','status');status.setAttribute('aria-live','polite');
  button.addEventListener('click',async()=>{
   if(button.disabled)return;button.disabled=true;status.textContent='';
   try{const text=String(payment.bank||'').replace(/은행$/,'')+' '+payment.account;const ok=await copy(text);status.textContent=ok?payment.bank+' 계좌 정보를 복사했습니다.':'복사하지 못했습니다. 계좌번호를 직접 선택해 복사해 주세요.';button.textContent=ok?'복사됨':'직접 복사';if(!ok){const range=document.createRange();range.selectNodeContents(number);const selection=getSelection();selection.removeAllRanges();selection.addRange(range);}}finally{button.disabled=false;}
  });
  row.append(number,button);box.append(row,status);
  return box;
 }
 window.FarmerBank=Object.freeze({create});
 document.querySelectorAll('[data-bank-transfer]').forEach(holder=>holder.replaceWith(create()));
})();
