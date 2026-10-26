(() => {
 'use strict';
 const $=id=>document.getElementById(id),api=window.FarmerAPI;
 let epoch=0,offset=0,next=null,loading=false;
 const text=(value,error=false)=>{$('admin-reviews-status').textContent=value;$('admin-reviews-status').classList.toggle('error',error);};
 async function load(reset=false){
  if(loading||!api.hasSession())return;const ticket=epoch;if(reset)offset=0;loading=true;$('admin-reviews-more').disabled=true;text('후기를 불러오고 있습니다.');
  try{const result=await api.admin('farmer_admin_reviews',{p_status:$('admin-reviews-filter').value,p_offset:offset});if(ticket!==epoch)return;if(reset)$('admin-reviews-list').replaceChildren();
   for(const r of result.reviews){const card=document.createElement('article');card.className='panel';card.style.marginBottom='16px';const top=document.createElement('div');top.className='actions';top.style.justifyContent='space-between';const heading=document.createElement('h2');heading.textContent=r.display_name+' · '+(r.status==='hidden'?'숨김':'공개');const button=document.createElement('button');button.type='button';button.className='button secondary';button.textContent=r.status==='hidden'?'다시 공개':'후기 숨기기';button.addEventListener('click',async()=>{if(loading)return;loading=true;button.disabled=true;const current=epoch;try{await api.admin('farmer_admin_review_visibility',{p_id:r.id,p_status:r.status==='hidden'?'published':'hidden',p_version:r.version});if(current!==epoch)return;loading=false;await load(true);}catch(e){if(current===epoch)text(e.message,true);}finally{if(current===epoch){loading=false;button.disabled=false;}}});top.append(heading,button);const body=document.createElement('p');body.textContent=r.body;body.style.whiteSpace='pre-wrap';body.style.overflowWrap='anywhere';body.style.lineHeight='1.8';body.style.marginTop='18px';const meta=document.createElement('p');meta.className='notice';meta.textContent=new Date(r.published_at).toLocaleString('ko-KR')+' · 사진 '+r.photo_count+'장';card.append(top,body,meta);$('admin-reviews-list').append(card);}
   next=result.next_offset;$('admin-reviews-more').hidden=next===null;text(result.total?`전체 ${result.total}개의 후기`:'아직 등록된 후기가 없습니다.');
  }catch(e){if(ticket===epoch)text(e.message,true);}finally{if(ticket===epoch){loading=false;$('admin-reviews-more').disabled=false;}}
 }
 function clear(){epoch++;loading=false;offset=0;next=null;$('reviews-panel').hidden=true;$('admin-reviews-list').replaceChildren();text('');}
 function init(){$('admin-reviews-refresh').addEventListener('click',()=>load(true));$('admin-reviews-filter').addEventListener('change',()=>load(true));$('admin-reviews-more').addEventListener('click',()=>{if(next!==null){offset=next;load();}});}
 window.FarmerReviewsAdmin=Object.freeze({init,clear,show:view=>{if(view==='reviews')load(true);}});
})();
