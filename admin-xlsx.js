/* Minimal dependency-free OOXML workbook. User values are inline strings, never formulas. */
(() => {
 'use strict';
 const enc=new TextEncoder(),xml=v=>String(v??'').replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]/g,'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
 const table=Uint32Array.from({length:256},(_,n)=>{for(let k=0;k<8;k++)n=n&1?0xedb88320^(n>>>1):n>>>1;return n>>>0;});
 const crc=bytes=>{let n=0xffffffff;for(const b of bytes)n=table[(n^b)&255]^(n>>>8);return(n^0xffffffff)>>>0;};
 const bytes=(size,values)=>{const a=new Uint8Array(size),v=new DataView(a.buffer);for(const [at,n,length]of values)length===2?v.setUint16(at,n,true):v.setUint32(at,n,true);return a;};
 function zip(files){
  const chunks=[],central=[];let offset=0,total=0;
  for(const [path,text]of files){const name=enc.encode(path),body=enc.encode(text),sum=crc(body),head=bytes(30,[[0,0x04034b50,4],[4,20,2],[6,0x800,2],[12,33,2],[14,sum,4],[18,body.length,4],[22,body.length,4],[26,name.length,2]]),entry=bytes(46,[[0,0x02014b50,4],[4,20,2],[6,20,2],[8,0x800,2],[14,33,2],[16,sum,4],[20,body.length,4],[24,body.length,4],[28,name.length,2],[42,offset,4]]);chunks.push(head,name,body);central.push(entry,name);offset+=head.length+name.length+body.length;total+=entry.length+name.length;}
  return new Blob([...chunks,...central,bytes(22,[[0,0x06054b50,4],[8,files.length,2],[10,files.length,2],[12,total,4],[16,offset,4]])],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
 }
 const colName=n=>{let s='';for(n++;n;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s;};
 function build(columns,rows,{header=true}={}){
  const textCell=(ref,v,style=0)=>`<c r="${ref}" s="${style}" t="inlineStr"><is><t xml:space="preserve">${xml(v)}</t></is></c>`;
  const last=colName(columns.length-1),range=`A1:${last}${Math.max(1,rows.length+Number(header))}`;
  let sheet=`<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="${range}"/><sheetViews><sheetView workbookViewId="0">${header?'<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>':''}</sheetView></sheetViews><cols>${columns.map((c,i)=>`<col min="${i+1}" max="${i+1}" width="${c.width||20}" customWidth="1"/>`).join('')}</cols><sheetData>${header?`<row r="1">${columns.map((c,i)=>textCell(colName(i)+'1',c.title,1)).join('')}</row>`:''}`;
  rows.forEach((row,index)=>{const n=index+1+Number(header);sheet+=`<row r="${n}">`+columns.map((c,i)=>{const value=c.value(row),ref=colName(i)+n;return c.number&&typeof value==='number'&&Number.isFinite(value)?`<c r="${ref}" s="${c.decimal?3:2}"><v>${value}</v></c>`:textCell(ref,value);}).join('')+'</row>';});
  sheet+=`</sheetData>${header?`<autoFilter ref="${range}"/>`:''}</worksheet>`;
  return zip([
   ['[Content_Types].xml','<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'],
   ['_rels/.rels','<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'],
   ['xl/workbook.xml','<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="주문 내역" sheetId="1" r:id="rId1"/></sheets></workbook>'],
   ['xl/_rels/workbook.xml.rels','<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'],
   ['xl/styles.xml','<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.###"/></numFmts><fonts count="2"><font><sz val="11"/><name val="맑은 고딕"/></font><font><b/><sz val="11"/><name val="맑은 고딕"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0"/><xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'],
   ['xl/worksheets/sheet1.xml',sheet]
  ]);
 }
 window.FarmerXlsx=Object.freeze({build});
})();
