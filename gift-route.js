(() => {
 const mode=document.body.dataset.giftRoute;
 const params=new URLSearchParams(location.hash.slice(1));
 const token=params.get('gift')||'';
 const target='./#'+mode+(mode==='receive'&&token?'&gift='+encodeURIComponent(token):'');
 document.querySelector('a').href=target;location.replace(target);
})();
