/* Shared cost reconciliation for the finance report and price simulator. Integer KRW. */
(() => {
 'use strict';
 function integer(v){if(!Number.isSafeInteger(v)||v<0)throw Error('배송·포장 비용 자료를 확인하지 못했습니다. 다시 불러와 주세요.');return v;}
 function calculate(data,shipping=data?.settings?.shipping,packing=data?.settings?.packing){
  if(!data)throw Error('기존 주문 비용을 불러와 주세요.');
  for(const v of [shipping,packing]){integer(v);if(v>100000000)throw Error('단가는 100,000,000원 이하로 입력해 주세요.');}
  const shippingBoxes=integer(data.shipping_boxes),pickupBoxes=integer(data.pickup_boxes),boxes=shippingBoxes+pickupBoxes;
  const recordedShipping=integer(data.recorded_shipping),recordedPacking=integer(data.recorded_packing);
  const estimatedShipping=shippingBoxes*shipping,estimatedPacking=boxes*packing;
  const extraShipping=Math.max(0,estimatedShipping-recordedShipping),extraPacking=Math.max(0,estimatedPacking-recordedPacking);
  const extra=extraShipping+extraPacking;
  for(const v of [boxes,estimatedShipping,estimatedPacking,extra])integer(v);
  return {shippingBoxes,pickupBoxes,boxes,shipping,packing,recordedShipping,recordedPacking,estimatedShipping,estimatedPacking,extraShipping,extraPacking,extra};
 }
 globalThis.FarmerFulfillmentMath=Object.freeze({calculate});
})();
