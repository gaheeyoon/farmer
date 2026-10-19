(() => {
 'use strict';
 const money=n=>Number(n).toLocaleString('ko-KR')+'원';
 const node=(tag,text,cls)=>{const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el;};
 const formatPhone=v=>{const d=v.replace(/\D/g,'').slice(0,11),p=d.startsWith('02')?2:3,r=d.slice(p),m=r.length>7?4:3;return d.length<=p?d:d.slice(0,p)+'-'+(r.length<=m?r:r.slice(0,m)+'-'+r.slice(m));};
 document.addEventListener('input',e=>{if(!e.target.matches('[data-phone]'))return;const el=e.target,pos=el.selectionStart||0,n=el.value.slice(0,pos).replace(/\D/g,'').length;el.value=formatPhone(el.value);let i=0,c=0;while(i<el.value.length&&c<n){if(/\d/.test(el.value[i]))c++;i++;}el.setSelectionRange(i,i);el.setCustomValidity('');});
 const phoneValid=el=>{el.setCustomValidity(/^0\d{8,10}$/.test(el.value.replace(/\D/g,''))?'':'연락처를 확인해 주세요.');};
 const giftURL=token=>{const u=new URL('https://yoongahee.com/farmer/');u.hash='receive&'+new URLSearchParams({gift:token}).toString();return u.href;};
 async function copy(value,input){try{await navigator.clipboard.writeText(value);return true;}catch{if(input){input.focus();input.select();}return false;}}
 let sdk;
 async function postcode(){if(window.kakao?.Postcode||window.daum?.Postcode)return window.kakao?.Postcode||window.daum.Postcode;if(sdk)return sdk;sdk=new Promise((resolve,reject)=>{const s=document.createElement('script');const fail=()=>{clearTimeout(timer);s.remove();sdk=null;reject(new Error('주소 검색에 연결하지 못했습니다. 직접 입력해 주세요.'));};const timer=setTimeout(fail,15000);s.src='https://t1.kakaocdn.net/mapjsapi/bundle/postcode/prod/postcode.v2.js';s.onload=()=>{clearTimeout(timer);const P=window.kakao?.Postcode||window.daum?.Postcode;P?resolve(P):fail();};s.onerror=fail;document.head.append(s);});return sdk;}
 const receiptKey='farmer-sent-gifts:v1';
 function savedGifts(){try{const a=JSON.parse(localStorage.getItem(receiptKey)||'[]');return Array.isArray(a)?a.filter(g=>g.until>Date.now()&&/^[a-f0-9]{64}$/.test(g.token)&&typeof g.order_number==='string'):[];}catch{return [];}}
 function rememberReceipt(data){if(!Array.isArray(data?.gifts))return;try{const map=new Map(savedGifts().map(g=>[g.order_number,g]));for(const g of data.gifts){if(/^[a-f0-9]{64}$/.test(g.token)&&g.order_number)map.set(g.order_number,{order_number:g.order_number,token:g.token,until:Date.now()+90*864e5});}localStorage.setItem(receiptKey,JSON.stringify([...map.values()].slice(-500)));}catch{}}
 const savedGift=number=>savedGifts().find(g=>g.order_number===number);
 window.GiftCommon=Object.freeze({money,node,formatPhone,phoneValid,giftURL,copy,postcode,rememberReceipt,savedGift});
})();
