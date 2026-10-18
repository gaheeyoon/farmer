/* Shared, side-effect-free price planning arithmetic; all money is integer KRW. */
(() => {
 'use strict';
 const integer=(value,name,max=100000000)=>{if(!Number.isSafeInteger(value)||value<0||value>max)throw new Error(name+'을(를) 0 이상의 정수로 입력해 주세요.');return value;};
 function calculate(p){
  const expense=integer(p.expense,'장부 지출',Number.MAX_SAFE_INTEGER),income=integer(p.income,'기존 수입',Number.MAX_SAFE_INTEGER);
  const price2=integer(p.price2,'2kg 판매가'),price5=integer(p.price5,'5kg 판매가'),qty2=integer(p.qty2,'2kg 수량',1000000),qty5=integer(p.qty5,'5kg 수량',1000000);
  const giftBoxes=integer(p.giftQty5===undefined?0:p.giftQty5,'선물 5kg 수량',1000000);
  const shipping=integer(p.shipping,'배송비'),packing=integer(p.packing,'상자비');
  if(!Number.isFinite(p.availableKg)||p.availableKg<0)throw new Error('현재 재고를 확인해 주세요.');
  const paidBoxes=qty2+qty5,boxes=paidBoxes+giftBoxes,kg=qty2*2+(qty5+giftBoxes)*5,revenue=price2*qty2+price5*qty5,shippingCost=shipping*boxes,packingCost=packing*boxes;
  const totalIncome=income+revenue,totalCost=expense+shippingCost+packingCost,profit=totalIncome-totalCost;
  if(![revenue,totalIncome,totalCost,profit].every(Number.isSafeInteger))throw new Error('계산 가능한 금액 범위를 초과했습니다.');
  return {boxes,paidBoxes,giftBoxes,kg,revenue,shippingCost,packingCost,totalIncome,totalCost,profit,baseProfit:income-expense,
   contribution:revenue-shippingCost-packingCost,averagePrice:paidBoxes?revenue/paidBoxes:null,
   breakEvenAverage:paidBoxes?Math.max(0,Math.ceil((expense-income+shippingCost+packingCost)/paidBoxes)):null,
   overStock:kg*1000>Math.round(p.availableKg*1000),remainingKg:p.availableKg-kg};
 }
 function planStock(kg){
  if(!Number.isFinite(kg)||kg<0||!Number.isSafeInteger(Math.round(kg*1000)))throw new Error('현재 재고를 확인해 주세요.');
  const grams=Math.round(kg*1000);let qty5=Math.min(1000000,Math.floor(grams/5000)),qty2=Math.min(1000000,Math.floor((grams-qty5*5000)/2000));
  if(qty5>0&&qty2<=999997&&grams-qty5*5000-qty2*2000>=1000){qty5--;qty2+=3;}
  return {qty2,qty5};
 }
 const comparison=p=>[-2000,-1000,0,1000,2000].map(delta=>{const price2=Math.min(100000000,Math.max(0,p.price2+delta)),price5=Math.min(100000000,Math.max(0,p.price5+delta));return {delta,price2,price5,...calculate({...p,price2,price5})};});
 globalThis.FarmerSimulationMath=Object.freeze({calculate,comparison,planStock});
})();
