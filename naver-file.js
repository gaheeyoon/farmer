/* Smart Store export parsing. Passwords and workbook bytes never leave this browser. */
(() => {
 'use strict';
 const clean=v=>String(v??'').trim(),key=v=>clean(v).replace(/\s+/g,''),digits=v=>clean(v).replace(/[\s()-]/g,'');
 const number=v=>{const s=clean(v).replace(/,/g,'');return s===''?null:/^-?\d+$/.test(s)?Number(s):null;};
 function date(v){
  if(typeof v==='number')return new Date(Math.round((v-25569)*86400000)).toISOString().replace('Z','+09:00');
  const s=clean(v).replace(' ','T');return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(s)?s+(s.length===16?':00':'')+'+09:00':'';
 }
 function parse(sheets){
  for(const {rows,offset=0} of sheets){
   const header=rows.findIndex((r,i)=>i<10&&r.some(v=>key(v)==='상품주문번호')&&r.some(v=>key(v)==='수취인명'));if(header<0)continue;
   const h=rows[header].map(key),required=['상품주문번호','주문번호','구매자명','구매자연락처','수취인명','수취인연락처1','우편번호','기본배송지','상세배송지','상품명','수량','상품가격','최종상품별총주문금액','배송비합계','결제일','주문일시','주문상태'];
   if(required.some(k=>!h.includes(k))||new Set(h.filter(Boolean)).size!==h.filter(Boolean).length)throw Error('네이버 발주·발송관리 엑셀의 필수 열을 확인해 주세요. 열 제목은 변경하지 말아 주세요.');
   const result=[];
   for(let i=header+1;i<rows.length;i++){
    const r=rows[i];if(!r.some(v=>clean(v)!==''))continue;
    const get=k=>r[h.indexOf(k)],title=clean(get('상품명')),option=clean(get('옵션정보'));
    const weights=[...new Set([...((option||title).matchAll(/(?:^|[^\d.])([235])\s*kg\b/gi))].map(m=>m[1]))];
    result.push({row:i+1+offset,external_id:clean(get('상품주문번호')),external_order:clean(get('주문번호')),source_status:clean(get('주문상태')),claim:clean(get('수량클레임여부')),product_id:weights.length===1?'hopungmi-'+weights[0]+'kg':'',source_product:title,source_option:option,quantity:number(get('수량')),unit_price:(number(get('상품가격'))??NaN)+(number(get('옵션가격'))??0),goods_total:number(get('최종상품별총주문금액')),shipping_fee:number(get('배송비합계')),shipping_group:clean(get('배송비묶음번호')),customer_name:clean(get('구매자명')),phone:digits(get('구매자연락처')),recipient_name:clean(get('수취인명')),recipient_phone:digits(get('수취인연락처1')),postal_code:clean(get('우편번호')).padStart(5,'0'),address:clean(get('기본배송지')),address_detail:clean(get('상세배송지')),memo:clean(get('배송메세지')),ordered_at:date(get('주문일시')),paid_at:date(get('결제일')),method:clean(get('배송방법(구매자요청)'))||clean(get('배송방법')),fee_amount:Math.abs(number(get('네이버페이주문관리수수료'))??0)+Math.abs(number(get('매출연동수수료'))??0),settlement:number(get('정산예정금액'))});
   }
   if(!result.length)throw Error('엑셀에 주문 내역이 없습니다.');if(result.length>500)throw Error('한 번에 500건까지 등록할 수 있습니다. 파일을 나눠 주세요.');return result;
  }
  throw Error('네이버 스마트스토어 발주·발송관리 엑셀을 선택해 주세요.');
 }
 window.FarmerNaverFile=Object.freeze({parse});
})();
