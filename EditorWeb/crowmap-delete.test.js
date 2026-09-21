import {test} from 'node:test';
import assert from 'node:assert/strict';
import {emptyMap,createProject,addNote,readNote} from './crowmap-model.js';
import {linkedTransaction,resolveMap,timelineNodes,deleteTimeline} from './crowmap-links.js';
const files=r=>Object.fromEntries(r.writes.map(w=>[w.name,w.text]));
function fixture(){let r=linkedTransaction(createProject(emptyMap(),{title:'Delete me',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'}]})),texts=files(r);r=linkedTransaction(addNote(r.doc,{title:'Attached work',date:'2026-10-15',attach:{kind:'edge',id:r.doc.edges[1].id},body:'Work body'}),texts);Object.assign(texts,files(r));return {doc:r.doc,texts};}
test('Deleting a timeline removes all its milestones and attached notes, preserving other timelines and unrelated files',()=>{
 let {doc,texts}=fixture();const start=doc.anchors[0],oldProject=doc.projects[0];let r=linkedTransaction(createProject(doc,{title:'Keep',date:'2026-10-01',priority:2,milestones:[{title:'End',date:'2026-10-20'}]}),texts);Object.assign(texts,files(r));doc=r.doc;
 r=linkedTransaction(addNote(doc,{title:'Keep note',date:'2026-10-15',attach:{kind:'edge',id:doc.edges.at(-1).id},body:'[[Attached work|Old work]] [[Delete me-A]]'}),texts);Object.assign(texts,files(r));doc=r.doc;texts['Unrelated.md']='Unrelated body';
 doc.view={milestoneOrder:{[oldProject.id+':2026-10-10']:[doc.anchors[1].id],keep:['keep']}};
 const before=structuredClone(doc);r=deleteTimeline(doc,start.id,texts);assert.equal(r.deletingProject,oldProject.id);assert.equal(r.doc.projects.length,1);assert.equal(r.doc.anchors.length,2);assert.equal(r.doc.notes.length,1);assert.equal(r.doc.edges.length,1);
 assert.deepEqual(new Set(r.deletes.map(d=>d.name)),new Set(['Delete me.md','Delete me-A.md','Delete me-B.md','Attached work.md']));assert(r.deletes.every(d=>d.expected===texts[d.name]));assert.equal(r.writes.length,1);assert(r.writes[0].text.endsWith('Old work Delete me-A'));
 assert.deepEqual(r.doc.view.milestoneOrder,{keep:['keep']});assert.deepEqual(doc,before);Object.assign(texts,files(r));for(const d of r.deletes)delete texts[d.name];assert.deepEqual(resolveMap(r.doc,texts),r.doc);assert.equal(texts['Unrelated.md'],'Unrelated body');
});
test('Deleting the final timeline leaves an empty usable map and removes remote references without deleting remote originals',()=>{
 const {doc,texts}=fixture(),attach=doc.notes[0].attach;doc.devices=[{id:'remote',label:'Device',attachments:[attach]}];doc.notes.push({...doc.notes[0],id:'remote-note',note:'Remote.md',device:'remote',cachedText:'Remote body'});
 const scope=timelineNodes(doc,doc.anchors[0].id);assert.equal(scope.notes.length,2);const r=deleteTimeline(doc,doc.anchors[0].id,texts);
 for(const key of ['projects','anchors','edges','notes','devices'])assert.deepEqual(r.doc[key],[]);
 assert.equal(r.deletes.length,4);assert(!r.deletes.some(d=>d.name==='Remote.md'));assert.equal(r.doc.id,doc.id);assert.throws(()=>deleteTimeline(doc,doc.anchors[1].id,texts),/start note/);
});
