import {test} from 'node:test';
import assert from 'node:assert/strict';
import {emptyMap,createProject,revisePlan,addNote,readNote,noteText} from './crowmap-model.js';
import {linkedTransaction,resolveMap,noteResolver,noteName} from './crowmap-links.js';
const files=r=>Object.fromEntries(r.writes.map(w=>[w.name,w.text]));
function fixture(){return linkedTransaction(createProject(emptyMap(),{title:'프로젝트',date:'2026-01-01',priority:1,milestones:[{title:'기획',date:'2026-01-10'},{title:'개발',date:'2026-01-20'},{title:'배포',date:'2026-01-30'}]}));}
test('Start and milestone properties are ordinary wiki-link lists, with readable unique filenames',()=>{const r=fixture(),texts=files(r);assert.deepEqual(Object.keys(texts),['프로젝트.md','프로젝트-기획.md','프로젝트-개발.md','프로젝트-배포.md']);const start=readNote(texts['프로젝트.md']).meta;assert.deepEqual(start.milestones,['[[프로젝트-기획]]','[[프로젝트-개발]]','[[프로젝트-배포]]']);assert.deepEqual(start.next,['[[프로젝트-기획]]']);assert.equal(start.project,undefined);const m=readNote(texts['프로젝트-개발.md']).meta;assert.deepEqual(m.previous,['[[프로젝트-기획]]']);assert.deepEqual(m.next,['[[프로젝트-배포]]']);assert.equal(m.project,'[[프로젝트]]');assert.deepEqual(resolveMap(r.doc,texts),r.doc);assert.equal(noteName('프로젝트-개발',Object.keys(texts)),'프로젝트-개발 2.md');});
test('Editing Markdown links imports new notes and rebuilds the timeline independently of cached edges',()=>{const r=fixture(),texts=files(r);for(const name of ['프로젝트-기획.md','프로젝트-개발.md'])texts[name]=texts[name].replace(name==='프로젝트-기획.md'?'[[프로젝트-개발]]':'[[프로젝트-기획]]','[[검토]]');texts['검토.md']=noteText({title:'검토',date:'2026-01-15',previous:['[[프로젝트-기획]]'],next:['[[프로젝트-개발]]']},'# 검토');const stale={...r.doc,edges:[]};const rebuilt=resolveMap(stale,texts);assert.deepEqual(rebuilt.projects[0].route.map(id=>rebuilt.anchors.find(a=>a.id===id).title),['프로젝트','기획','검토','개발','배포']);assert.equal(rebuilt.edges.length,4);});
test('Revision links retain old work and rejoin one shared existing milestone after rebuilding',()=>{let r=fixture(),texts=files(r);r=linkedTransaction(addNote(r.doc,{title:'작업',date:'2026-01-13',attach:{kind:'edge',id:r.doc.edges[1].id},body:'내용'}),texts);Object.assign(texts,files(r));const p=r.doc.projects[0],join=p.route[3];r=linkedTransaction(revisePlan(r.doc,{project:p.id,from:p.route[1],rejoin:join,date:'2026-01-14',title:'범위 변경',priority:1,milestones:[{title:'새 개발',date:'2026-01-23'}]}),texts);Object.assign(texts,files(r));assert.deepEqual(readNote(texts['작업.md']).meta.between,['[[프로젝트-기획]]','[[프로젝트-개발]]']);assert.equal(readNote(texts['프로젝트-범위 변경.md']).meta.replaces,undefined);const restored=resolveMap(r.doc,texts);assert.equal(restored.projects[0].route.at(-1),join);assert.equal(restored.edges.filter(e=>e.state==='superseded').length,0);assert.equal(restored.anchors.filter(a=>a.id===join).length,1);assert.deepEqual(restored.notes[0].attach,r.doc.notes[0].attach);assert.deepEqual(readNote(texts['프로젝트.md']).meta.milestones,['[[프로젝트-기획]]','[[프로젝트-개발]]','[[프로젝트-배포]]','[[프로젝트-범위 변경]]','[[프로젝트-새 개발]]']);assert.equal(linkedTransaction({doc:restored,writes:[]},texts).writes.length,0);});
test('Legacy object properties convert without deleting custom frontmatter or bodies',()=>{const r=createProject(emptyMap(),{title:'Legacy',date:'2026-01-01',priority:1,milestones:[{title:'Ship',date:'2026-01-10'}]}),texts=files(r);texts['Legacy.md']=texts['Legacy.md'].replace('---\n','---\n# keep comment\ncustom: kept\n')+'Body';assert.equal(resolveMap(r.doc,texts).anchors.length,2);const converted=linkedTransaction({doc:r.doc,writes:[]},texts);const text=files(converted)['Legacy.md'];assert(text.includes('# keep comment'));assert(text.includes('custom: kept'));assert(text.endsWith('Body'));assert.deepEqual(readNote(text).meta.milestones,['[[Legacy-Ship]]']);assert(converted.writes.every(w=>w.expected===texts[w.name]));});
test('Missing, ambiguous, cyclic and invalid dated links report errors instead of silently losing a plan',()=>{const r=fixture(),texts=files(r);assert.throws(()=>resolveMap(r.doc,{...texts,'프로젝트-기획.md':texts['프로젝트-기획.md'].replace('[[프로젝트-개발]]','[[없음]]')}),/Missing/);assert.throws(()=>resolveMap(r.doc,{...texts,'프로젝트-개발.md':texts['프로젝트-개발.md'].replace('2026-01-20','2025-01-01')}),/segment|order/);const lookup=noteResolver({'A.md':noteText({title:'Same'}),'B.md':noteText({title:'Same'})});assert.throws(()=>lookup('[[Same]]'),/Ambiguous/);assert.equal(lookup('[[A|Alias]]'),'A.md');assert.equal(noteResolver({'한글.md':''})('[[한글]]'),'한글.md');});

test('Two same-day Markdown notes stay two nodes when B links A; repeated device attachments stay one node',async()=>{
 const {graphLinks}=await import('./crowmap-links.js');let r=fixture(),texts=files(r),attach={kind:'edge',id:r.doc.edges[1].id};
 r=linkedTransaction(addNote(r.doc,{title:'A',date:'2026-01-13',attach,body:''}),texts);Object.assign(texts,files(r));
 r=linkedTransaction(addNote(r.doc,{title:'B',date:'2026-01-13',attach,body:'[[A]] [[A|Again]] https://example.com'}),texts);Object.assign(texts,files(r));
 const links=graphLinks(resolveMap(r.doc,texts),texts);assert.equal(r.doc.notes.length,2);assert.equal(links.connections.length,1);assert.equal(links.leaves.get(r.doc.notes[1].id).length,1);assert.equal(links.connections[0].to,r.doc.notes[0].id);
 r.doc.devices.push({id:'remote',hostID:'host',label:'Device'});r=addNote(r.doc,{title:'Remote',date:'2026-01-13',attach,device:'remote',note:'Work.md',cachedText:''});r=addNote(r.doc,{title:'Remote',date:'2026-01-13',attach,device:'remote',note:'Work.md',cachedText:''});assert.equal(r.doc.notes.filter(n=>n.device==='remote').length,1);
});

test('A newly linked dated Markdown file is imported once and undated notes are not copied into leaves',async()=>{
 const {graphLinks}=await import('./crowmap-links.js');let r=fixture(),texts=files(r),attach={kind:'edge',id:r.doc.edges[1].id};
 r=linkedTransaction(addNote(r.doc,{title:'Owner',date:'2026-01-13',attach,body:'[[Shared]] [[Shared]]'}),texts);Object.assign(texts,files(r));texts['Shared.md']=noteText({date:'2026-01-13'},'Shared work');
 const restored=resolveMap(r.doc,texts);assert.equal(restored.notes.filter(n=>n.note==='Shared.md').length,1);assert.equal(graphLinks(restored,texts).connections.length,1);
 texts['Shared.md']='# No date';assert.throws(()=>resolveMap(r.doc,texts),/date property/);assert.equal(graphLinks(r.doc,texts).leaves.get(r.doc.notes[0].id).length,0);
});

test('Repeated projects use numbered start names and scoped milestone filenames',()=>{
 const first=fixture(),texts=files(first);
 const second=linkedTransaction(createProject(first.doc,{title:'프로젝트',date:'2026-02-01',priority:2,milestones:[{title:'기획',date:'2026-02-10'}]},Object.keys(texts)),texts);
 assert.equal(second.doc.projects[1].title,'프로젝트 2');
 assert(second.writes.some(w=>w.name==='프로젝트 2.md'));
 assert(second.writes.some(w=>w.name==='프로젝트 2-기획.md'));
 assert.deepEqual(readNote(files(second)['프로젝트 2.md']).meta.milestones,['[[프로젝트 2-기획]]']);
});

test('Renaming a milestone keeps short title references and custom Markdown intact',async()=>{
 const {renamedNoteSource}=await import('./file-title.js');
 const before='---\n# Keep comment\ntitle: Research\nkind: milestone\nproject: "[[Website]]"\ndate: 2026-01-10\ncustom: value\n---\n\nBody unchanged\n';
 const after=renamedNoteSource(before,'Website-Discovery.md');
 assert.equal(readNote(after).meta.title,'Discovery');assert.deepEqual(readNote(after).meta.aliases,['Research']);
 assert(after.includes('# Keep comment'));assert(after.includes('custom: value'));assert(after.endsWith('\n\nBody unchanged\n'));
 assert.equal(noteResolver({'Website-Discovery.md':after})('[[Research]]'),'Website-Discovery.md');
});

test('Deleting a work note removes only its file and weak links while preserving the project',async()=>{
 const {deleteWorkNote,graphLinks}=await import('./crowmap-links.js');let r=fixture(),texts=files(r),attach={kind:'edge',id:r.doc.edges[1].id};
 r=linkedTransaction(addNote(r.doc,{title:'A',date:'2026-01-13',attach,body:'Keep A'}),texts);Object.assign(texts,files(r));
 r=linkedTransaction(addNote(r.doc,{title:'B',date:'2026-01-13',attach,body:'[[A|Related]] Keep B'}),texts);Object.assign(texts,files(r));
 const before=r.doc,deleted=deleteWorkNote(before,before.notes[0].id,texts);
 assert.deepEqual(deleted.doc.anchors,before.anchors);assert.deepEqual(deleted.doc.edges,before.edges);assert.equal(deleted.doc.notes.length,1);
 assert.deepEqual(deleted.deletes,[{name:'A.md',expected:texts['A.md']}]);assert(deleted.writes[0].text.endsWith('Related Keep B'));
 assert.throws(()=>deleteWorkNote(before,before.anchors[0].id,texts),/Work note not found/);
 const next={...texts,...files(deleted)};delete next['A.md'];assert.equal(resolveMap(deleted.doc,next).notes.length,1);assert.equal(graphLinks(deleted.doc,next).connections.length,0);
});


test('An empty display cache discovers Markdown projects and work without rewriting their files',()=>{
  const r=fixture(),texts=files(r),work=addNote(r.doc,{title:'Work',date:'2026-01-15',attach:{kind:'edge',id:r.doc.edges[1].id}});
  const linked=linkedTransaction(work,texts),all={...texts,...files(linked)},before=structuredClone(all),cache=emptyMap('Imported');
  const rebuilt=resolveMap(cache,all);
  assert.equal(rebuilt.projects.length,1);assert.equal(rebuilt.anchors.length,4);assert.equal(rebuilt.notes.length,1);assert.equal(rebuilt.edges.length,3);
  assert.equal(rebuilt.noteLinks,true);assert.deepEqual(all,before);assert.equal(cache.projects.length,0);
  assert.deepEqual(resolveMap(rebuilt,all),rebuilt,'Refreshing preserves discovered IDs and routes');
});

test('New Markdown start notes extend an existing cache while preserving existing identities',()=>{
  const r=fixture(),texts=files(r),added=linkedTransaction(createProject(emptyMap(),{title:'Second',date:'2026-02-01',priority:2,milestones:[{title:'Release',date:'2026-02-10'}]}));
  const all={...texts,...files(added)},result=resolveMap(r.doc,all);
  assert.equal(result.projects.length,2);assert.equal(result.projects[0].id,r.doc.projects[0].id);
  assert.equal(result.anchors.find(a=>a.note==='프로젝트.md').id,r.doc.anchors[0].id);
  assert.equal(result.anchors.length,6);assert.deepEqual(resolveMap(result,all),result);
});

test('Discovering a new linked project keeps legacy cached projects readable',()=>{
  const legacy=createProject(emptyMap(),{title:'Legacy',date:'2026-01-01',priority:1,milestones:[{title:'Done',date:'2026-01-02'}]});
  const modern=linkedTransaction(createProject(emptyMap(),{title:'Modern',date:'2026-02-01',priority:2,milestones:[{title:'Done',date:'2026-02-02'}]}));
  const result=resolveMap(legacy.doc,{...files(legacy),...files(modern)});
  assert.equal(result.projects.length,2);assert.equal(result.anchors.length,4);assert.equal(result.edges.length,2);
  assert.deepEqual(result.projects[0].route,legacy.doc.projects[0].route);assert.notEqual(result.noteLinks,true);
});
