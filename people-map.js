/* All chapters stay expanded. Names and roles are maintained in tmi-data.js. */
(() => {
 'use strict';
 const e=(tag,text,cls)=>{const n=document.createElement(tag);if(text!=null)n.textContent=text;if(cls)n.className=cls;return n;};
 function actor(person){
  const card=e('li',null,'field-person');card.dataset.personId=person.id;
  if(person.kind)card.classList.add(`field-person-${person.kind}`);
  const portraits=e('div',null,'field-portraits');const ids=person.avatars||[person.avatar];
  portraits.style.setProperty('--portrait-count',ids.length);if(ids.length>2)portraits.classList.add('portrait-crowd');
  ids.forEach(index=>portraits.append(window.FarmerPeopleCharacters.avatar(index,{child:!!person.child})));
  const prop=window.FarmerPeopleCharacters.prop(person.prop);portraits.append(prop);
  const info=e('div',null,'field-person-info');info.append(e('p',person.name,'field-person-name'));
  if(person.detail)info.append(e('p',person.detail,'field-person-detail'));
  card.append(portraits,info);return card;
 }
 function render(chapters,target){
  if(!target||!window.FarmerPeopleCharacters)return;
  target.replaceChildren(...chapters.map(chapter=>{
   const li=e('li',null,`field-chapter field-${chapter.scene}`);li.id=`people-scene-${chapter.step}`;
   const heading=e('div',null,'field-chapter-heading');
   const num=e('span',chapter.step,'field-chapter-number');num.setAttribute('aria-hidden','true');
   const titles=e('div');titles.append(e('p',chapter.label,'field-chapter-label'));const h=e('h3',chapter.title);h.id=`people-chapter-${chapter.step}`;titles.append(h);
   if(chapter.date)titles.append(e('p',chapter.date,'field-chapter-date'));
   heading.append(num,titles);li.setAttribute('aria-labelledby',h.id);
   const intro=e('p',chapter.intro,'field-chapter-intro');
   const scene=e('div',null,'field-scene');
   const landline=e('div',null,'field-scene-top');landline.setAttribute('aria-hidden','true');
   landline.append(e('span',`FIELD ${chapter.step}`),e('span',({guidance:'묻고 배우는 자리',prepare:'고구마를 심을 자리',growing:'함께 일군 밭',harvest:'첫 수확의 현장'})[chapter.scene]));
   const tasks=e('div',null,'field-tasks');
   chapter.groups.forEach((group,index)=>{
    const task=e('section',null,'field-task');task.dataset.group=index;
    const top=e('div',null,'field-task-heading');top.append(e('span',String(index+1).padStart(2,'0'),'task-number'),e('h4',group.task));
    if(group.note)top.append(e('p',group.note,'field-task-note'));
    const list=e('ul',null,'field-people');list.setAttribute('role','list');group.people.forEach(p=>list.append(actor(p)));
    task.append(top,list);tasks.append(task);
   });
   scene.append(landline,tasks);
   li.append(heading,intro,scene);
   if(chapter.aside)li.append(e('p',chapter.aside,'field-postscript'));
   return li;
  }));
 }
 window.FarmerPeople=Object.freeze({render});
})();
