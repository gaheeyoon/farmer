/* Original pixel characters. Shared IDs keep the same symbolic character across scenes. */
(() => {
 'use strict';
 const ns='http://www.w3.org/2000/svg';
 const palettes=[
  ['#684531','#839e62','#536077',0,'glasses'],['#292f37','#6d8f9a','#4f4967',1,'tie'],['#724454','#a97595','#635a68',2,'glasses'],['#454439','#9d774b','#534f42',3,'hat'],['#51352f','#b87567','#6a694c',4,'scarf'],['#333d36','#f0e7cd','#6d8791',5,'glasses'],['#66533d','#6e8d65','#555d72',6,'cap'],['#554236','#b9935c','#57534d',7,'glasses'],['#403234','#a782a1','#596865',8,'scarf'],['#6c4c30','#81a897','#4c6470',9,'hat'],['#553b32','#c07a82','#626c55',4,'apron'],['#2f4043','#9baf7e','#685d80',2,'headband'],['#784b36','#bf925a','#496c71',0,'glasses'],['#453330','#a083b9','#53617b',1,'bow'],['#5c3932','#e1af60','#6c6481',8,'bow'],['#333d3e','#6f9eaf','#725e69',9,'cap'],['#77746a','#9a9672','#4c5e62',3,'glasses'],['#37343c','#b67b62','#575e76',7,'glasses'],['#4c3436','#9c7da7','#4c7775',5,'glasses'],['#4d4b3b','#b1a356','#556c67',6,'cap'],['#5e4935','#7396ae','#595a73',0,'hat'],['#3b3d3a','#b17e70','#6f7052',3,'cap'],['#6d443c','#9eae72','#67647b',9,'headband'],['#4c3439','#a98cba','#5d7470',1,'hat'],['#774631','#7c9d80','#766174',8,'bow'],['#3d3b43','#c39c68','#547e80',2,'scarf'],['#605144','#7e9e9a','#65576a',6,'glasses'],['#4b4136','#9d8b5d','#587675',3,'apron'],['#3b3432','#8c879f','#6f7955',5,'scarf'],['#614a39','#6a9ca1','#78705e',9,'cap'],['#4d4d42','#bba061','#536f7c',7,'headband'],['#413e4b','#8191a5','#655773',1,'glasses']
 ];
 function svgNode(tag,attrs){const n=document.createElementNS(ns,tag);for(const[k,v]of Object.entries(attrs))n.setAttribute(k,v);return n;}
 function prop(kind){
  const s=svgNode('svg',{viewBox:'0 0 40 32','aria-hidden':'true',class:'pixel-prop','shape-rendering':'crispEdges'});
  const r=(x,y,w,h,c)=>s.append(svgNode('rect',{x,y,width:w,height:h,fill:c}));
  const outline='#4e4038',gold='#d2b05b',green='#718a51';
  if(kind==='tractor') {r(3,12,32,12,outline);r(6,10,25,11,green);r(18,2,12,15,outline);r(21,5,6,8,'#c5d8cd');r(3,19,12,12,outline);r(6,22,6,6,gold);r(27,22,8,8,outline);r(29,24,4,4,gold);r(7,6,3,7,outline);}
  else if(kind==='excavator'){r(2,25,30,6,outline);r(6,21,19,5,gold);r(6,10,15,12,gold);r(8,12,9,7,'#a4b9b3');r(21,9,4,14,gold);r(23,6,13,4,gold);r(33,9,4,13,gold);r(31,21,8,7,outline);r(5,27,5,2,'#8f8a78');r(15,27,5,2,'#8f8a78');r(25,27,4,2,'#8f8a78');}
  else if(kind==='greenhouse'){r(3,14,34,17,'#b6cbbb');r(6,9,28,5,'#cbd9c4');r(11,5,18,4,'#dce3cc');r(16,2,8,3,'#dce3cc');r(3,14,2,17,green);r(35,14,2,17,green);r(6,9,2,6,green);r(32,9,2,6,green);r(11,5,2,5,green);r(27,5,2,5,green);r(16,2,8,2,green);r(19,4,2,27,green);r(4,20,32,2,green);r(4,29,32,2,green);}
  else if(kind==='supplies'){r(4,8,13,22,'#9aa46f');r(7,4,7,5,'#b8bd90');r(6,14,9,9,'#e4ddbe');r(20,12,15,18,'#b5a275');r(24,8,7,5,'#d4bd8d');r(23,17,9,8,'#e6dcc2');r(8,17,5,3,green);r(25,19,5,3,green);}
  else if(kind==='crate'){r(4,12,32,18,outline);r(7,15,26,12,'#b58c59');r(5,18,30,3,gold);r(12,13,3,17,outline);r(25,13,3,17,outline);r(8,7,10,7,'#9b536f');r(20,5,10,9,'#af6278');}
  else if(kind==='shovel'){r(17,3,8,3,outline);r(16,6,3,6,outline);r(23,6,3,6,outline);r(18,11,6,3,outline);r(20,14,3,12,'#96734d');r(15,24,13,5,'#81948e');r(18,29,7,3,'#81948e');}
  else if(kind==='soil'){r(12,10,18,18,outline);r(15,13,12,12,'#ceaa76');r(15,21,12,4,'#8f6347');r(15,3,3,7,green);r(9,2,9,3,green);r(18,0,9,4,'#92a366');}
  else if(kind==='water'){r(8,13,23,4,outline);r(11,8,4,9,'#90aaa8');r(11,8,14,4,'#90aaa8');r(22,8,4,10,'#90aaa8');r(24,20,3,5,'#729aad');r(23,25,5,3,'#729aad');r(15,3,7,3,outline);r(17,2,3,7,outline);}
  else if(kind==='laptop'){r(5,6,29,18,outline);r(8,9,23,12,'#b2c8b5');r(2,24,35,4,'#8a8881');r(14,12,3,3,'#6b7c69');r(19,16,8,2,'#6b7c69');}
  else if(kind==='music'){r(17,3,3,21,outline);r(20,3,12,3,outline);r(29,5,3,15,outline);r(9,21,11,7,'#9f6e91');r(22,18,10,7,'#9f6e91');}
  else if(kind==='heart'){r(9,6,8,5,'#b66b85');r(23,6,8,5,'#b66b85');r(6,11,28,9,'#b66b85');r(10,20,20,4,'#b66b85');r(14,24,12,4,'#b66b85');r(18,28,4,3,'#b66b85');}
  else if(kind==='sprout'){r(18,12,4,17,green);r(7,5,11,7,'#93aa66');r(12,11,9,6,green);r(22,3,11,8,'#a3b578');r(20,11,8,5,green);r(11,29,19,3,'#9c7859');}
  else{r(9,4,23,25,outline);r(11,6,19,21,kind==='book'?'#e3d1a5':'#e9e0c8');r(11,6,3,21,kind==='book'?'#9c6d83':'#cbbf9b');r(17,11,10,2,'#a39779');r(17,16,10,2,'#a39779');r(17,21,7,2,'#a39779');if(kind==='clipboard'){r(16,2,10,6,'#71877c');}}
  return s;
 }
 function avatar(index,{child=false}={}){
  const [hair,shirt,pants,style,acc]=palettes[index%palettes.length];
  const s=svgNode('svg',{viewBox:'0 0 32 42',class:'pixel-person','aria-hidden':'true','shape-rendering':'crispEdges','data-avatar':index});
  const r=(x,y,w,h,c)=>s.append(svgNode('rect',{x,y,width:w,height:h,fill:c}));
  const ink='#493c35',skin=['#dfb48c','#e4bd99','#d6a481'][index%3],shade='#bf8c6f';
  r(7,39,19,2,'#c4ba9c');r(4,40,24,1,'#d1c6ad');
  // Different silhouettes, hairstyles, headwear, clothes, and accessories are original artwork.
  if([2,4,5,8].includes(style)){r(7,8,19,17,hair);r(5,13,3,12,hair);r(25,13,3,11,hair);}
  r(9,29,6,8,pants);r(18,29,6,8,pants);r(8,36,8,3,ink);r(18,36,8,3,ink);
  r(8,21,18,12,ink);r(10,22,14,10,shirt);r(5,23,5,8,shirt);r(24,23,5,8,shirt);r(5,30,5,3,skin);r(24,30,5,3,skin);
  r(13,19,8,4,skin);r(14,21,6,2,shade);r(8,6,18,14,hair);r(10,8,14,12,skin);r(7,11,3,5,skin);r(24,11,3,5,skin);r(12,20,10,2,skin);
  r(10,4,14,4,hair);r(8,7,18,3,hair);
  const cuts=[[[10,9,4,3],[14,8,3,2]],[[9,9,14,2],[10,11,3,2]],[[8,8,4,11],[23,8,3,10]],[[8,8,5,5],[21,8,5,5]],[[8,5,6,8],[22,5,4,9]],[[10,3,4,3],[8,7,6,6]],[[8,7,18,3]],[[10,6,5,6],[21,7,5,4]],[[7,6,5,12],[21,6,6,12]],[[9,7,8,4],[22,7,4,4]]];
  cuts[style].forEach(a=>r(...a,hair));
  r(12,13,2,2,ink);r(20,13,2,2,ink);r(15,17,4,1,ink);r(10,16,2,1,'#cd8b82');r(23,16,2,1,'#cd8b82');
  r(13,24,3,3,'#ffffff55');r(19,24,3,3,'#ffffff55');
  if(acc==='glasses'){r(10,12,7,1,ink);r(18,12,7,1,ink);r(10,15,7,1,ink);r(18,15,7,1,ink);r(10,13,1,2,ink);r(16,13,3,1,ink);r(24,13,1,2,ink);}
  if(acc==='cap'){r(9,3,16,4,shirt);r(7,7,21,2,shirt);r(11,4,4,2,goldColor(index));}
  if(acc==='hat'){r(10,2,14,5,'#c3a565');r(5,7,24,3,'#ddbd78');r(10,6,14,2,'#93734d');}
  if(acc==='scarf'){r(11,21,13,3,'#e1bc74');r(21,23,3,6,'#e1bc74');}
  if(acc==='bow'){r(7,5,4,4,'#e2b178');r(14,5,4,4,'#e2b178');r(11,6,3,2,'#b78074');}
  if(acc==='tie'){r(15,22,4,2,'#d0b980');r(16,24,2,6,'#d0b980');}
  if(acc==='apron'){r(12,25,11,8,'#e1c9a0');r(15,22,5,5,'#e1c9a0');r(15,28,5,3,'#b99774');}
  if(acc==='headband'){r(8,8,18,2,'#d9bd7e');r(24,8,3,7,'#d9bd7e');}
  if(child)s.classList.add('pixel-child');
  return s;
 }
 function goldColor(i){return i%2?'#dfcc89':'#e6dfb7';}
 window.FarmerPeopleCharacters=Object.freeze({avatar,prop});
})();
