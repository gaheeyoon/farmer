import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import vm from 'node:vm';
const window={};vm.runInNewContext(await readFile(new URL('../naver-file.js',import.meta.url),'utf8'),{window});
const h=['상품주문번호','주문번호','구매자명','구매자연락처','수취인명','수취인연락처1','우편번호','기본배송지','상세배송지','상품명','수량','상품가격','최종 상품별 총 주문금액','배송비 합계','결제일','주문일시','주문상태','옵션가격','옵션정보','배송메세지','배송방법'];
const r=['2026111390000001','20261113900001','구매자','010-1234-5678','받는 분','0502-1234-5678','05410','서울 테스트로 123','101호','호풍미 5kg',2,22000,44000,0,46339.5,46339.49,'발송대기',0,'','문 앞','택배,등기,소포'];
const parse=rows=>window.FarmerNaverFile.parse([{rows}]);let out=parse([['안내'],h,r]);assert.equal(out[0].row,3);assert.equal(out[0].external_id,r[0]);assert.equal(out[0].product_id,'hopungmi-5kg');assert.equal(out[0].recipient_phone,'050212345678');assert.equal(out[0].postal_code,'05410');assert.equal(out[0].paid_at,'2026-11-13T12:00:00.000+09:00');
const option=[...r];option[9]='호풍미 3kg 5kg';option[18]='중량: 3kg';assert.equal(parse([h,option])[0].product_id,'hopungmi-3kg');option[18]='';assert.equal(parse([h,option])[0].product_id,'');
assert.throws(()=>parse([h]),/주문 내역/);assert.throws(()=>parse([['다른파일']]),/스마트스토어/);assert.throws(()=>parse([h,...Array(501).fill(r)]),/500건/);assert.throws(()=>parse([h.filter(v=>v!=='우편번호'),r]),/필수 열/);
console.log('PASS: Naver source IDs, two-row headers, option-first weight mapping, safe phone numbers, postal zeros, Excel local dates and malformed/large files.');
