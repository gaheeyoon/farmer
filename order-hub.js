(() => {
 'use strict';
 const views={new:['new-order-tab','new-order-panel','#order'],lookup:['lookup-order-tab','order-lookup','#order-lookup'],gift:['gift-order-tab','gift-order-panel','#gift'],sent:['sent-gifts-tab','sent-gifts-panel','#sent-gifts'],receive:['receive-gift-tab','receive-gift-panel','#receive']};
 const $=id=>document.getElementById(id);let current='new',receivedToken='';
 function parseToken(hash){return new URLSearchParams(hash.replace(/^#/,'').replace(/^receive[?&]/,'')).get('gift')||'';}
 function setView(view,focus=false){
  current=view in views?view:'new';
  for(const [key,[tab,panel]] of Object.entries(views)){$(tab).setAttribute('aria-selected',String(key===current));$(tab).tabIndex=key===current?0:-1;$(panel).hidden=key!==current;}
  if(focus)$(views[current][0]).focus();
  window.dispatchEvent(new CustomEvent('farmer:viewchange',{detail:{view:current}}));
 }
 function open(view,focus=false,token){
  if(!(view in views))view='new';
  if(token!==undefined)receivedToken=token;
  const hash=views[view][2]+(view==='receive'&&receivedToken?'&gift='+encodeURIComponent(receivedToken):'');
  if(location.hash!==hash)history.pushState(null,'',hash);
  setView(view,focus);
  if(focus)$(views[view][0]).scrollIntoView({block:'nearest',inline:'nearest'});
  else $('order').scrollIntoView({block:'start',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
 }
 function sync(){
  const hash=location.hash,t=parseToken(hash);if(t)receivedToken=t;
  const view=hash.startsWith('#receive')||hash.startsWith('#gift=')?'receive':Object.entries(views).find(([,v])=>v[2]===hash)?.[0]||'new';setView(view);
  if(view!=='new')requestAnimationFrame(()=>$('order').scrollIntoView({block:'start'}));
 }
 window.FarmerOrderHub=Object.freeze({open,view:()=>current,token:()=>receivedToken});
 document.querySelectorAll('[data-order-view]').forEach(el=>el.addEventListener('click',e=>{e.preventDefault();open(el.dataset.orderView);}));
 document.querySelector('.order-tabs').addEventListener('keydown',e=>{
  if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();
  const keys=Object.keys(views),i=keys.indexOf(current);open(keys[e.key==='Home'?0:e.key==='End'?keys.length-1:(i+(e.key==='ArrowRight'?1:-1)+keys.length)%keys.length],true);
 });
 addEventListener('popstate',sync);addEventListener('hashchange',sync);sync();
})();
