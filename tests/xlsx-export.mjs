import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const context={window:{},TextEncoder,Uint8Array,Uint32Array,DataView,Blob};vm.runInNewContext(await readFile(new URL('../admin-xlsx.js',import.meta.url),'utf8'),context);
const columns=[{title:'성함',value:o=>o.name},{title:'연락처',value:o=>o.phone},{title:'우편번호',value:o=>o.postal},{title:'금액',number:true,value:o=>o.total}];
const blob=context.window.FarmerXlsx.build(columns,[{name:'=HYPERLINK("bad") <윤&가희>\x00',phone:'01012345678',postal:'04524',total:22000}]);
const buffer=Buffer.from(await blob.arrayBuffer()),files=new Map();let off=0;
while(buffer.readUInt32LE(off)===0x04034b50){const size=buffer.readUInt32LE(off+18),len=buffer.readUInt16LE(off+26),extra=buffer.readUInt16LE(off+28),name=buffer.toString('utf8',off+30,off+30+len),start=off+30+len+extra;files.set(name,buffer.toString('utf8',start,start+size));off=start+size;}
assert.equal(files.size,6);assert.ok(files.has('[Content_Types].xml'));const sheet=files.get('xl/worksheets/sheet1.xml');assert.ok(sheet.includes('04524'));assert.ok(sheet.includes('01012345678'));assert.ok(sheet.includes('=HYPERLINK(&quot;bad&quot;) &lt;윤&amp;가희&gt;'));assert.ok(sheet.includes('<v>22000</v>'));assert.ok(!sheet.includes('<f>'));assert.ok(!sheet.includes('\x00'));assert.ok(sheet.includes('state="frozen"'));assert.ok(sheet.includes('autoFilter'));assert.equal(buffer.readUInt32LE(buffer.length-22),0x06054b50);
console.log('PASS: valid OOXML package, Unicode escaping, formula-safe strings, leading zeroes, numeric amounts and frozen/filterable headers.');
