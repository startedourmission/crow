import test from 'node:test';
import assert from 'node:assert/strict';
import {canvas, base, expression, evaluate, record, yaml} from './obsidian-model.js';
const files=[{path:'Books/Alpha.md',text:'---\nstatus: reading\nprice: 12\nage: 3\ntags: [book, shelf/one]\n---\n# Alpha'},
 {path:'Books/Beta.md',text:'---\nstatus: done\nprice: 8\nage: 2\n---'}, {path:'photo.png',size:200}];
test('Canvas preserves all node types, layout and labeled edges',()=>{
 const nodes=['group','text','file','link'].map((type,i)=>({id:String(i),type,x:i*100-200,y:-100,width:300,height:200}));
 const result=canvas(JSON.stringify({nodes,edges:[{id:'e',fromNode:'1',toNode:'2',label:'link',fromEnd:'arrow'}]}));
 assert.equal(result.nodes[0].x,-200);assert.equal(result.edges[0].fromEnd,'arrow');
 assert.throws(()=>canvas(JSON.stringify({nodes:[nodes[0],nodes[0]]})),/duplicate/);
 assert.throws(()=>canvas(JSON.stringify({nodes,edges:[{fromNode:'missing',toNode:'2'}]})),/missing/);
});
test('Bases global and view filters, formulas, custom columns and sort',()=>{
 const source=`filters: 'file.ext == "md"'\nformulas:\n  ppu: price / age\nproperties:\n  formula.ppu:\n    displayName: Unit price\nviews:\n  - type: table\n    name: Books\n    filters: 'status != "done" && file.inFolder("Books") && file.hasTag("shelf")'\n    order: [file.name, status, formula.ppu]\n    sort: [{property: price, direction: DESC}]`;
 const result=base(source,files,'Index.base');assert.equal(result.rows.length,1);assert.deepEqual(result.rows[0].cells,['Alpha','reading',4]);
});
test('Nested boolean filters and this context; cards, list, grouping and limit',()=>{
 const source=`filters:\n  not:\n    - 'file.ext == "png"'\nviews:\n  - type: cards\n    name: Shelf\n    filters: 'file.folder == this.file.folder'\n    groupBy: {property: status, direction: DESC}\n    order: [file.name]\n    limit: 1\n  - type: list\n    name: All`;
 const result=base(source,files,'Books/Index.base');assert.equal(result.rows.length,1);assert.equal(result.total,2);assert.equal(result.rows[0].cells[0],'Alpha');
 assert.equal(base(source,files,'Books/Index.base',1).rows.length,2);
});
test('Formula interpreter has no JavaScript execution and detects cycles',()=>{
 const ctx={...record(files[0]),formulas:{a:'formula.b',b:'formula.a'}};
 assert.equal(evaluate(expression('if(price > 10, (price / age).toFixed(2), "none")'),ctx),'4.00');
 assert.equal(evaluate(expression('tags.contains("book")'),ctx),true);
 assert.throws(()=>evaluate(expression('formula.a'),ctx),/Circular/);
 assert.throws(()=>evaluate(expression('file.constructor("return globalThis")()'),ctx),/Unsupported/);
 assert.throws(()=>expression('globalThis.x = 1'),/Unsupported/);
 assert.throws(()=>base('views: [{type: map}]',files,'a.base'),/Unsupported Base view/);
 assert.throws(()=>evaluate(expression('tags.filter(value)'),ctx),/Unsupported Base function/);
});
test('Invalid YAML and frontmatter are reported instead of silently dropping filters',()=>{
 assert.throws(()=>yaml('views: [not closed'));
 assert.throws(()=>base('filters: {unknown: []}\nviews: [{type: table}]',files,'a.base'),/Invalid Base filter/);
 assert.throws(()=>base('views: [{type: table}]',[{path:'bad.md',text:'---\nbad: [\n---'}],'a.base'));
});
