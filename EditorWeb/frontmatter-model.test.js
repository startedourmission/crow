import test from 'node:test';
import assert from 'node:assert/strict';
import {frontmatter,editFrontmatter,propertyValue} from './frontmatter-model.js';
test('Property changes preserve comments, body, BOM and CRLF and persist types',()=>{
 const source='\uFEFF---\r\n# Keep\r\ncount: "42"\r\ncreated: 2024-12-03\r\ncustom: {nested: yes}\r\n---\r\n# Body\r\n![ [literal] ]\r\n';
 const edited=editFrontmatter(source,'count',{type:'number',value:'42'});
 assert.equal(frontmatter(edited).rows.find(r=>r.name==='count').value,42);
 assert.ok(edited.includes('# Keep\r\n')); assert.ok(edited.endsWith(source.slice(source.indexOf('# Body'))));
 assert.ok(!/(?<!\r)\n/.test(edited));
 const typed=editFrontmatter(edited,'created',{type:'text',value:'2024-12-03'});
 assert.equal(frontmatter(typed).rows.find(r=>r.name==='created').type,'text');
 assert.equal(frontmatter(editFrontmatter(typed,'created',{type:'date',value:'2024-12-03'})).rows.find(r=>r.name==='created').type,'date');
 assert.deepEqual(frontmatter(edited).rows.find(r=>r.name==='custom').value,{nested:'yes'});
});
test('Crowmap date and priority stay typed even when YAML quotes them',()=>{
 const source='---\ndate: "2026-09-19"\npriority: "2"\ncreated: "2024-12-03"\n---\n';
 const rows=frontmatter(source).rows;
 assert.equal(rows.find(r=>r.name==='date').type,'date');
 assert.equal(rows.find(r=>r.name==='priority').type,'number');
 assert.equal(rows.find(r=>r.name==='created').type,'text');
 const edited=editFrontmatter(source,'date',{type:'date',value:'2026-10-02'});
 assert.equal(frontmatter(edited).rows.find(r=>r.name==='date').type,'date');
 assert.match(edited,/date: 2026-10-02/);
 assert.doesNotMatch(edited,/date: "2026-10-02"/);
});
test('Property add, rename and remove validate without dropping unsupported values',()=>{
 let source='---\nname: old\n---\n';
 source=editFrontmatter(source,'tags',{add:true,type:'list',value:'one\ntwo'});
 assert.deepEqual(frontmatter(source).rows[1].value,['one','two']);
 assert.throws(()=>editFrontmatter(source,'name',{rename:'tags'}),/already exists/);
 source=editFrontmatter(source,'name',{rename:'title'});
 assert.equal(frontmatter(source).rows[0].name,'title');
 source=editFrontmatter(source,'tags',{remove:true});
 assert.equal(frontmatter(source).rows.length,1);
 assert.throws(()=>propertyValue('abc','number'),/number/);
 assert.throws(()=>propertyValue('yes','boolean'),/true or false/);
 assert.equal(propertyValue('false','boolean'),false);
 assert.throws(()=>frontmatter('---\nbad: [\n---\n'));
});
