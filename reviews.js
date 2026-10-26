/* A short public story with an optional nickname and up to three photos. */
(() => {
  'use strict';
  const $=id=>document.getElementById(id),api=window.FarmerAPI,config=window.FARMER_BACKEND;
  if(!$('reviews-form'))return;
  const node=(tag,text,cls)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e;};
  let photos=[],processing=false,busy=false,pending=null,offset=0,loading=false,feedVersion=0;
  const photoURLs=new Set(),seen=new Set();
  const status=(text,error=false)=>{const e=$('reviews-form-status');e.textContent=text;e.classList.toggle('error',error);};
  const pathURL=path=>config.url+'/storage/v1/object/authenticated/farmer-reviews/'+path.split('/').map(encodeURIComponent).join('/');
  async function storage(path,options={}){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),45000);
    try{
      const response=await fetch(path,{...options,headers:{apikey:config.publishableKey,...options.headers},signal:controller.signal,cache:'no-store'});
      if(!response.ok){const detail=await response.json().catch(()=>null),e=new Error('사진을 처리하지 못했습니다. 잠시 뒤 다시 시도해 주세요.');e.status=response.status;e.duplicate=detail?.error==='Duplicate'||detail?.code==='Duplicate'||detail?.message==='The resource already exists';throw e;}
      return response;
    }finally{clearTimeout(timer);}
  }
  function freeze(){
    $('reviews-fields').disabled=busy||processing||!!pending;
    $('reviews-submit').disabled=busy||processing;
    $('reviews-close').disabled=busy||!!pending;
    $('reviews-submit').textContent=busy?'등록 중…':processing?'사진 준비 중…':pending?'등록 결과 다시 확인':'이야기 남기기 →';
  }
  function compose(){ $('reviews-compose').hidden=false;$('reviews-write').setAttribute('aria-expanded','true');$('reviews-body').focus({preventScroll:true});$('reviews-compose').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'start'}); }
  $('reviews-write').addEventListener('click',compose);$('reviews-first').addEventListener('click',compose);
  $('reviews-close').addEventListener('click',()=>{if(busy||pending)return;$('reviews-compose').hidden=true;$('reviews-write').setAttribute('aria-expanded','false');$('reviews-write').focus();});
  $('reviews-body').addEventListener('input',()=>{$('reviews-counter').textContent=$('reviews-body').value.length.toLocaleString('ko-KR')+' / 1,200';});
  function previews(){
    $('reviews-previews').replaceChildren();$('reviews-photo-count').textContent=photos.length+' / 3';
    photos.forEach((p,i)=>{const div=node('div',undefined,'reviews-preview'),img=node('img'),button=node('button','×');img.src=p.url;img.alt=`선택한 후기 사진 ${i+1}`;button.type='button';button.setAttribute('aria-label',`사진 ${i+1} 삭제`);button.addEventListener('click',()=>{URL.revokeObjectURL(p.url);photos.splice(i,1);previews();});div.append(img,button);$('reviews-previews').append(div);});
  }
  async function compress(file){
    if(file.size>20*1024*1024)throw Error('사진 한 장은 20MB 이하로 선택해 주세요.');
    if(!/^image\/(jpeg|png|webp|heic|heif)$/.test(file.type))throw Error('JPG·PNG·WebP 사진을 선택해 주세요. HEIC는 기기에서 지원하는 경우 올릴 수 있습니다.');
    const url=URL.createObjectURL(file),img=new Image();
    try{
      img.src=url;await img.decode();if(!img.naturalWidth||!img.naturalHeight||img.naturalWidth*img.naturalHeight>100000000)throw Error('사진 크기가 너무 큽니다. 작은 사진을 선택해 주세요.');
      const scale=Math.min(1,1600/Math.max(img.naturalWidth,img.naturalHeight)),canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(img.naturalWidth*scale));canvas.height=Math.max(1,Math.round(img.naturalHeight*scale));const ctx=canvas.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.drawImage(img,0,0,canvas.width,canvas.height);
      let blob;for(const q of [.82,.65,.45]){blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',q));if(blob&&blob.size<=1500000)break;}
      if(!blob||blob.size>1500000)throw Error('사진을 줄이지 못했습니다. 다른 사진으로 다시 선택해 주세요.');
      return{blob,url:URL.createObjectURL(blob)};
    }catch(e){if(e.name==='EncodingError')throw Error('이 사진을 읽을 수 없습니다. JPG 또는 PNG로 바꿔서 올려 주세요.');throw e;}
    finally{URL.revokeObjectURL(url);}
  }
  $('reviews-photo-open').addEventListener('click',()=>$('reviews-photos').click());
  $('reviews-photos').addEventListener('change',async e=>{
    const files=[...e.target.files];e.target.value='';if(processing||pending||busy)return;
    if(files.length+photos.length>3){status('사진은 최대 3장까지 올릴 수 있습니다. 필요 없는 사진을 지운 뒤 선택해 주세요.',true);return;}
    processing=true;freeze();status('사진을 준비하고 있습니다.');const added=[];
    try{for(const file of files)added.push(await compress(file));photos.push(...added);previews();status('');}
    catch(e){added.forEach(p=>URL.revokeObjectURL(p.url));status(e.message,true);}
    finally{processing=false;freeze();}
  });
  async function photo(button,img,path){
    try{const response=await storage(pathURL(path)),blob=await response.blob();if(!button.isConnected)return;const url=URL.createObjectURL(blob);photoURLs.add(url);img.src=url;img.hidden=false;button.querySelector('span').remove();button.disabled=false;button.addEventListener('click',()=>{$('reviews-lightbox-image').src=url;$('reviews-lightbox-image').alt=img.alt;$('reviews-lightbox').showModal();});}
    catch{button.querySelector('span').textContent='사진을 불러오지 못했어요';}
  }
  function card(r){
    if(seen.has(r.id))return;seen.add(r.id);
    const article=node('article',undefined,'review-card');
    if(r.photos.length){const gallery=node('div',undefined,'review-card-photos');gallery.dataset.count=r.photos.length;r.photos.forEach((path,i)=>{const button=node('button',undefined,'review-photo'),img=node('img'),label=node('span','사진 불러오는 중…');button.type='button';button.disabled=true;button.setAttribute('aria-label',`${r.display_name}님의 후기 사진 ${i+1} 크게 보기`);img.alt=`${r.display_name}님의 고구마 사진 ${i+1}`;img.hidden=true;button.append(img,label);gallery.append(button);photo(button,img,path);});article.append(gallery);}
    const copy=node('div',undefined,'review-card-copy'),top=node('div',undefined,'review-card-top'),date=node('time',new Date(r.published_at).toLocaleDateString('ko-KR',{year:'numeric',month:'2-digit',day:'2-digit',timeZone:'Asia/Seoul'}));date.dateTime=r.published_at;top.append(node('span','고구맙습니다의 다음 이야기'),date);
    const author=node('div',undefined,'review-card-author');author.append(node('span',r.display_name.slice(0,1),'review-card-avatar'),node('span',r.display_name));copy.append(top,node('p',r.body,'review-card-body'),author);article.append(copy);$('reviews-grid').append(article);
  }
  async function load(reset=false){
    if(loading&&!reset)return;const ticket=++feedVersion;loading=true;$('reviews-retry').hidden=true;$('reviews-more').disabled=true;
    if(reset){offset=0;seen.clear();$('reviews-grid').replaceChildren();photoURLs.forEach(url=>URL.revokeObjectURL(url));photoURLs.clear();}
    $('reviews-status').textContent='이야기를 불러오고 있습니다.';
    try{const r=await api.rpc('farmer_reviews',{p_offset:offset});if(ticket!==feedVersion)return;r.reviews.forEach(card);$('reviews-total').textContent=r.total.toLocaleString('ko-KR');$('reviews-empty').hidden=r.total!==0;$('reviews-status').textContent='';offset=r.next_offset;$('reviews-more').hidden=offset===null;}
    catch(e){if(ticket===feedVersion){$('reviews-status').textContent='후기를 불러오지 못했습니다. 잠시 뒤 다시 확인해 주세요.';$('reviews-retry').hidden=false;}}
    finally{if(ticket===feedVersion){loading=false;$('reviews-more').disabled=false;}}
  }
  $('reviews-more').addEventListener('click',()=>load());$('reviews-retry').addEventListener('click',()=>load(offset===null));
  $('reviews-lightbox-close').addEventListener('click',()=>$('reviews-lightbox').close());
  $('reviews-lightbox').addEventListener('close',()=>$('reviews-lightbox-image').removeAttribute('src'));
  $('reviews-form').addEventListener('submit',async e=>{
    e.preventDefault();if(busy||processing)return;
    if(!pending){
      if(!$('reviews-form').reportValidity())return;
      pending={args:{p_request_id:api.uuid(),p_display_name:$('reviews-nickname').value.trim(),p_body:$('reviews-body').value.trim(),p_photo_count:photos.length,p_consent:$('reviews-consent').checked},ticket:null,uploaded:new Set()};
    }
    busy=true;freeze();status('이야기를 등록하고 있습니다.');
    try{
      if(!pending.ticket){const r=await api.rpc('farmer_review_begin',pending.args);if(!r.ok){pending=null;throw Error(r.message);}pending.ticket=r;}
      const t=pending.ticket;
      if(!t.published){
        for(let i=0;i<photos.length;i++)if(!pending.uploaded.has(i)){
          status(`사진을 올리고 있습니다. ${i+1} / ${photos.length}`);
          try{await storage(config.url+'/storage/v1/object/farmer-reviews/'+t.paths[i].split('/').map(encodeURIComponent).join('/'),{method:'POST',headers:{'Content-Type':'image/jpeg','x-upsert':'false'},body:photos[i].blob});}
          catch(e){if(e.status!==409&&!e.duplicate)throw e;/* The publish RPC checks every stored object before making the review visible. */}
          pending.uploaded.add(i);
        }
        await api.rpc('farmer_review_publish',{p_id:t.id,p_upload_token:t.upload_token});
      }
      pending=null;photos.forEach(p=>URL.revokeObjectURL(p.url));photos=[];$('reviews-form').reset();previews();$('reviews-counter').textContent='0 / 1,200';status('이야기를 남겨 주셔서 고구맙습니다.');await load(true);$('reviews-form-status').focus({preventScroll:true});
    }catch(e){status(e.message+(pending?' 같은 버튼을 눌러 등록 결과를 다시 확인해 주세요.':''),true);}
    finally{busy=false;freeze();}
  });
  load();
})();
