/* Hanjin workbook parsing only. Files stay in the browser; no upload to storage. */
(() => {
 'use strict';
 const clean=v=>String(v??'').trim(),key=v=>clean(v).replace(/\s+/g,''),find=(row,names)=>row.findIndex(v=>names.includes(key(v)));
 function parse(workbook){
  if(!workbook||!window.XLSX)throw Error('엑셀 읽기 기능을 불러오지 못했습니다.');
  for(const name of workbook.SheetNames){
   const sheet=workbook.Sheets[name],range=sheet['!fullref']||sheet['!ref'];if(!range)continue;
   if(window.XLSX.utils.decode_range(range).e.r>511)throw Error('한 번에 500상자까지 등록할 수 있습니다. 파일을 나눠 주세요.');
   const rows=window.XLSX.utils.sheet_to_json(sheet,{header:1,raw:false,defval:'',blankrows:true});
   const header=rows.findIndex((row,i)=>i<10&&find(row,['운송장번호','송장번호'])>=0);if(header<0)continue;
   const h=rows[header],sub=rows[header+1]||[],group=find(h,['수하인','수취인']),track=find(h,['운송장번호','송장번호']);
   const nested=group>=0&&find(sub.slice(group,group+6),['이름','성명'])>=0;
   const member=names=>{const p=find(sub.slice(group,group+6),names);return p<0?-1:group+p;};
   const nameCol=nested?member(['이름','성명']):find(h,['수하인명','수취인명','받는분','받는분성함']);
   const phoneCol=nested?member(['연락처','전화번호']):find(h,['수하인연락처','수취인연락처','받는분연락처']);
   const zipCol=nested?member(['우편번호']):find(h,['수하인우편번호','우편번호']);
   const addressCol=nested?member(['주소']):find(h,['수하인주소','수취인주소','주소']);
   const product=find(h,['품목명','상품명','상품']),quantity=find(h,['수량']),reference=find(h,['고객출고번호','주문번호']);
   if([nameCol,phoneCol,zipCol,addressCol,product].some(c=>c<0))throw Error('한진 세부내역의 수하인 이름·연락처·우편번호·주소·품목명 열이 필요합니다.');
   const result=[];
   for(let i=header+(nested?2:1);i<rows.length;i++){
    const row=rows[i],tracking=clean(row[track]).replace(/[\s-]/g,'');if(!tracking)continue;
    const weight=clean(row[product]).match(/(\d+(?:\.\d+)?)\s*(?:kg|킬로)/i),ref=reference>=0?clean(row[reference]).match(/GF-\d{8}/g):null;
    result.push({row:i+1,tracking,name:clean(row[nameCol]),phone:clean(row[phoneCol]),postal:clean(row[zipCol]).padStart(5,'0'),address:clean(row[addressCol]),weight_grams:weight?Math.round(Number(weight[1])*1000):0,quantity:quantity<0||!clean(row[quantity])?1:Number(clean(row[quantity]).replace(/,/g,'')),order_number:ref?.length===1?ref[0]:''});
   }
   if(!result.length)throw Error('파일에 운송장번호가 있는 배송 내역이 없습니다.');
   if(result.length>500)throw Error('한 번에 500상자까지 등록할 수 있습니다. 파일을 나눠 주세요.');
   return result;
  }
  throw Error('한진 배송현황 세부내역 파일을 선택해 주세요. 운송장번호 열을 찾지 못했습니다.');
 }
 window.FarmerHanjinFile=Object.freeze({parse});
})();
