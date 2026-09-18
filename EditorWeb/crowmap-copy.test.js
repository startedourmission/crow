import {test} from 'node:test';
import assert from 'node:assert/strict';
import {emptyMap,createProject,addNote,readNote} from './crowmap-model.js';
import {linkedTransaction,resolveMap,graphLinks} from './crowmap-links.js';
import {copyNodes,duplicateNodes} from './crowmap-copy.js';
const files=r=>Object.fromEntries(r.writes.map(w=>[w.name,w.text]));
function fixture(){let r=linkedTransaction(createProject(emptyMap(),{title:'Project',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'}]})),texts=files(r);r=linkedTransaction(addNote(r.doc,{title:'Work',date:'2026-10-15',attach:{kind:'edge',id:r.doc.edges[1].id},body:'[[Project-A]] [external](https://example.com)'}),texts);Object.assign(texts,files(r));return {doc:r.doc,texts};}
test('Copy scope includes only selected files, expanding starts to milestones but never attached work',()=>{
 const {doc}=fixture();assert.equal(copyNodes(doc,[doc.notes[0].id]).length,1);assert.equal(copyNodes(doc,[doc.anchors[1].id]).length,1);
 assert.deepEqual(copyNodes(doc,[doc.anchors[0].id]).map(n=>n.id),doc.anchors.map(n=>n.id));assert.throws(()=>copyNodes(doc,['missing']));
});
test('Duplicating a timeline rewrites its own links, preserves content, and leaves work attached only to original',()=>{
 const {doc,texts}=fixture();texts['Project-A.md']=texts['Project-A.md'].replace('---\n','---\n# keep comment\ncustom: kept\n')+'\n![[Project-B#Heading|Alias]] [[Work]]';
 const before=structuredClone(doc),r=duplicateNodes(doc,[doc.anchors[0].id],texts);Object.assign(texts,files(r));const restored=resolveMap(r.doc,texts);
 assert.equal(restored.projects.length,2);assert.equal(restored.anchors.length,6);assert.equal(restored.notes.length,1);assert.deepEqual(restored.notes[0],doc.notes[0]);assert.deepEqual(doc,before);
 const copy=restored.projects[1],anchors=restored.anchors.filter(a=>a.project===copy.id);assert.equal(copy.title,'Project 2');assert.equal(anchors.length,3);assert.equal(r.writes.filter(w=>!w.expected).length,3);
 assert.equal(readNote(texts['Project 2-A.md']).meta.project,'[[Project 2]]');assert.deepEqual(readNote(texts['Project 2-A.md']).meta.next,['[[Project 2-B]]']);
 assert(texts['Project 2-A.md'].includes('# keep comment'));assert(texts['Project 2-A.md'].includes('custom: kept'));assert(texts['Project 2-A.md'].endsWith('![[Project 2-B#Heading|Alias]] [[Work]]'));
 assert.equal(restored.edges.filter(e=>e.project===copy.id).length,2);assert.equal(graphLinks(restored,texts).connections.filter(e=>e.to===restored.notes[0].id).length,2);
 assert.equal(r.reads.length,3);assert.equal(duplicateNodes(restored,[doc.anchors[0].id],texts).doc.projects[2].title,'Project 3');
});
test('Milestone duplication copies just its file and neighboring connections, never segment work',()=>{
 const {doc,texts}=fixture(),original=doc.anchors[1],r=duplicateNodes(doc,[original.id],texts);Object.assign(texts,files(r));const restored=resolveMap(r.doc,texts),copy=restored.anchors.find(a=>a.id===r.copiedIDs[0]);
 assert.equal(restored.projects.length,1);assert.equal(restored.anchors.length,4);assert.equal(restored.notes.length,1);assert.equal(copy.note,'Project-A 2.md');
 assert.equal(restored.edges.filter(e=>e.to===copy.id||e.from===copy.id).length,2);assert.deepEqual(restored.notes,doc.notes);assert.equal(r.writes.filter(w=>!w.expected).length,1);
});
test('Work duplication copies Markdown once, keeps its attachment and never follows weak links',()=>{
 const {doc,texts}=fixture(),r=duplicateNodes(doc,[doc.notes[0].id],texts);Object.assign(texts,files(r));assert.equal(r.doc.notes.length,2);assert.equal(r.doc.anchors.length,3);assert.equal(r.doc.projects.length,1);assert.equal(r.writes.length,1);
 assert.equal(texts['Work 2.md'],texts['Work.md']);assert.deepEqual(r.doc.notes[1].attach,doc.notes[0].attach);assert.deepEqual(resolveMap(r.doc,texts),r.doc);
});
test('Remote work duplicates into a local Markdown file without changing the device reference',()=>{
 const {doc,texts}=fixture();doc.devices.push({id:'remote',label:'Remote'});const original={...doc.notes[0],id:'remote-note',note:'Remote.md',device:'remote',cachedText:texts['Work.md']};doc.notes.push(original);
 const r=duplicateNodes(doc,[original.id],texts),copy=r.doc.notes.find(n=>n.id===r.copiedIDs[0]);assert.equal(copy.device,undefined);assert.equal(r.doc.notes.find(n=>n.id===original.id).device,'remote');assert(r.writes.some(w=>w.name==='Remote.md'));assert.equal(r.reads.length,0);
});
