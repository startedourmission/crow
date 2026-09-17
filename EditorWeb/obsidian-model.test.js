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
test('Invalid YAML is rejected and unreadable note properties are reported',()=>{
 assert.throws(()=>yaml('views: [not closed'));
 assert.throws(()=>base('filters: {unknown: []}\nviews: [{type: table}]',files,'a.base'),/Invalid Base filter/);
 const result=base('views: [{type: table}]',[{path:'bad.md',text:'---\nbad: [\n---'},...files],'a.base');
 assert.equal(result.rows.length,files.length); assert.match(result.warnings[0],/bad.md/);
});

test('Canvas edits preserve extension fields and node order', async () => {
 const {serializeCanvas} = await import('./obsidian-model.js');
 const source = JSON.stringify({plugin:{zoom:1}, nodes:[{id:'a',type:'text',x:0,y:0,width:300,height:200,text:'old',custom:{keep:true}}],edges:[]});
 const doc = canvas(source); doc.nodes[0].text = '한글 편집'; doc.nodes[0].x = 42;
 const saved = JSON.parse(serializeCanvas(doc));
 assert.deepEqual(saved.plugin,{zoom:1}); assert.deepEqual(saved.nodes[0].custom,{keep:true});
 assert.equal(saved.nodes[0].text,'한글 편집'); assert.equal(saved.nodes[0].x,42);
});
test('Note property edits preserve body, comments, types, BOM and CRLF', async () => {
 const {updateNoteProperty} = await import('./obsidian-model.js');
 const source = '\uFEFF---\r\n# Keep this comment\r\nstatus: reading\r\nprice: 12\r\ncustom: {nested: yes}\r\n---\r\n# Body\r\n\r\nUnchanged **Markdown**.\r\n';
 const edited = updateNoteProperty(source,'note.status','done');
 assert.equal(edited.slice(edited.indexOf('# Body')),source.slice(source.indexOf('# Body')));
 assert.ok(edited.includes('# Keep this comment')); assert.ok(edited.startsWith('\uFEFF---\r\n'));
 assert.ok(!/(?<!\r)\n/.test(edited)); assert.equal(record({path:'a.md',text:edited}).note.status,'done');
 const typed = updateNoteProperty(updateNoteProperty(edited,'price',3.5),'tags',['one','two']);
 assert.equal(record({path:'a.md',text:typed}).note.price,3.5);
 assert.deepEqual(record({path:'a.md',text:typed}).note.tags,['one','two']);
 assert.equal(record({path:'a.md',text:updateNoteProperty(typed,'price',null)}).note.price,undefined);
 assert.throws(()=>updateNoteProperty(source,'file.name','renamed'),/Only note/);
 assert.throws(()=>updateNoteProperty('---\nbad: [\n---\nbody','x','value'));
 assert.throws(()=>updateNoteProperty('---\nstatus: reading','x','value'),/unclosed/);
 assert.ok(updateNoteProperty('---\n---\nBody','new','value').endsWith('---\nBody'));
});
test('Base view changes preserve comments, global filters and unknown settings', async () => {
 const {updateBaseView} = await import('./obsidian-model.js');
 const source = '# Saved by Obsidian\nfilters: \'file.ext == "md"\'\nplugin: {keep: true}\nviews:\n  - type: table\n    name: Notes\n    custom: 42\n    order: [file.name, status]\n';
 const edited = updateBaseView(source,0,{name:'Reading',sort:[{property:'status',direction:'DESC'}]});
 assert.ok(edited.includes('# Saved by Obsidian'));
 assert.equal(yaml(edited).views[0].custom,42); assert.deepEqual(yaml(edited).plugin,{keep:true});
 assert.equal(yaml(edited).filters,'file.ext == "md"');
 assert.equal(yaml(updateBaseView(edited,1,{name:'Cards',type:'cards'})).views.length,2);
 assert.throws(()=>updateBaseView(source,0,{type:'invalid'}),/Unsupported/);
});

test('Note metadata cache is reused and invalidated after an edit', () => {
 const file={path:'Note.md',text:'---\nstatus: reading\n---\n#old',modified:1};
 const first=record(file); assert.strictEqual(record(file),first);
 file.text='---\nstatus: done\n---\n#new';
 const changed=record(file); assert.notStrictEqual(changed,first); assert.equal(changed.note.status,'done');
 file.modified=2; assert.equal(record(file).file.mtime.getTime(),2000);
});

test('Filter scopes, nested conditions and formulas preserve unrelated Base settings', async () => {
 const {updateBaseFilters,updateBaseFormula} = await import('./obsidian-model.js');
 const source=`# Keep comment\nfilters: 'file.ext == "md"'\nplugin: kept\nviews: [{name: Books, type: table, order: [file.name]}]`;
 const rule={and:[{or:['status == "reading"','price < 10']},{not:['file.ext == "png"']}]};
 const scoped=updateBaseFilters(source,0,'view',rule);
 assert.deepEqual(yaml(scoped).views[0].filters,rule); assert.equal(yaml(scoped).filters,'file.ext == "md"');
 assert.equal(base(scoped,files,'a.base').rows.length,2);
 const all=updateBaseFilters(scoped,0,'all','price > 10');
 assert.deepEqual(yaml(all).views[0].filters,rule); assert.equal(base(all,files,'a.base').rows.length,1);
 const formula=updateBaseFormula(all,0,'Per page','price / age');
 assert.equal(base(formula,files,'a.base').rows[0].cells[1],4);
 assert.equal(yaml(formula).plugin,'kept'); assert.ok(formula.includes('# Keep comment'));
 assert.equal(yaml(updateBaseFilters(formula,0,'view',null)).views[0].filters,undefined);
});
