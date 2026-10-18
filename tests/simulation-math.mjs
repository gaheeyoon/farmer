import assert from 'node:assert/strict';
await import('../simulation-math.js');
const {calculate,comparison,planStock}=globalThis.FarmerSimulationMath;
const base={expense:3017620,income:0,price2:12000,price5:22000,qty2:0,qty5:600,shipping:3500,packing:1000,availableKg:3000};
let r=calculate(base);assert.equal(r.revenue,13200000);assert.equal(r.shippingCost,2100000);assert.equal(r.packingCost,600000);assert.equal(r.totalCost,5717620);assert.equal(r.profit,7482380);assert.equal(r.breakEvenAverage,9530);assert.equal(r.overStock,false);assert.equal(r.remainingKg,0);
r=calculate({...base,income:1000000,qty2:10,qty5:2});assert.equal(r.boxes,12);assert.equal(r.kg,30);assert.equal(r.revenue,164000);assert.equal(r.totalIncome,1164000);assert.equal(r.profit,1164000-3017620-12*4500);assert.equal(r.overStock,false);
const rows=comparison(base);assert.equal(rows[0].profit,7482380-1200000);assert.equal(rows[3].profit-rows[2].profit,600000);assert.equal(rows[2].profit,calculate(base).profit);
const clamped=comparison({...base,price2:500,price5:1000,qty2:1,qty5:1});assert.equal(clamped[0].price2,0);assert.equal(clamped[0].price5,0);assert.equal(clamped[0].revenue,0);
r=calculate({...base,qty2:0,qty5:0});assert.equal(r.totalCost,3017620);assert.equal(r.profit,-3017620);assert.equal(r.breakEvenAverage,null);assert.equal(r.averagePrice,null);
r=calculate({...base,expense:0,income:100000000,qty5:1,price5:0});assert.equal(r.breakEvenAverage,0);assert.equal(r.profit,99995500);
assert.equal(calculate({...base,qty5:601}).overStock,true);assert.equal(calculate({...base,qty5:0,qty2:1,availableKg:1.999}).overStock,true);
for(const field of ['expense','income','price2','price5','qty2','qty5','shipping','packing'])for(const value of [-1,NaN,Infinity,1.5])assert.throws(()=>calculate({...base,[field]:value}));
assert.throws(()=>calculate({...base,availableKg:-1}));assert.throws(()=>calculate({...base,qty2:1000001}));assert.throws(()=>calculate({...base,income:Number.MAX_SAFE_INTEGER}));
console.log('PASS: simulator mixed boxes, existing income/expenses, per-box costs, loss/zero/stock cases, break-even rounding, comparison deltas, clamped prices and invalid/unsafe input.');

assert.deepEqual(planStock(3000),{qty2:0,qty5:600});assert.deepEqual(planStock(2998),{qty2:4,qty5:598});assert.deepEqual(planStock(8),{qty2:4,qty5:0});assert.deepEqual(planStock(1.999),{qty2:0,qty5:0});assert.deepEqual(planStock(2.001),{qty2:1,qty5:0});assert.throws(()=>planStock(-1));

// Gift boxes have zero revenue but consume stock and per-box fulfillment costs.
r=calculate({...base,giftQty5:10});assert.equal(r.paidBoxes,600);assert.equal(r.giftBoxes,10);assert.equal(r.boxes,610);assert.equal(r.kg,3050);assert.equal(r.revenue,13200000);assert.equal(r.profit,7437380);assert.equal(r.breakEvenAverage,9605);assert.equal(r.averagePrice,22000);assert.equal(r.overStock,true);
r=calculate({...base,qty5:590,giftQty5:10});assert.equal(r.kg,3000);assert.equal(r.overStock,false);assert.equal(r.profit,7262380);assert.equal(r.shippingCost,2100000);assert.equal(r.packingCost,600000);
r=calculate({...base,qty5:0,giftQty5:10});assert.equal(r.revenue,0);assert.equal(r.boxes,10);assert.equal(r.kg,50);assert.equal(r.profit,-3062620);assert.equal(r.breakEvenAverage,null);assert.equal(r.averagePrice,null);
const giftRows=comparison({...base,giftQty5:10});assert.equal(giftRows[3].profit-giftRows[2].profit,600000);assert.equal(giftRows[0].giftBoxes,10);assert.equal(giftRows[0].shippingCost,2135000);
for(const value of [-1,1.5,NaN,Infinity,1000001,null])assert.throws(()=>calculate({...base,giftQty5:value}));
assert.equal(calculate({...base,giftQty5:0}).profit,calculate(base).profit);
console.log('PASS: gifts fixed at zero revenue, paid-only price sensitivity and break-even denominator, combined stock and costs, all-gift cases and gift quantity validation.');
