import {test} from 'node:test';
import assert from 'node:assert/strict';
import {emptyMap,createProject,addNote,addMilestone,connectMilestones,readNote,mainMilestoneIDs} from './crowmap-model.js';
import {linkedTransaction,resolveMap,timelineNodes,deleteTimeline,deleteMilestone} from './crowmap-links.js';
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
test('Deleting a milestone stitches previous to next and keeps attached work on the new segment',()=>{
 let r=linkedTransaction(createProject(emptyMap(),{title:'Line',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'},{title:'C',date:'2026-10-30'}]})),texts=files(r),doc=r.doc;
 r=linkedTransaction(addNote(doc,{title:'Work',date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;
 const start=doc.anchors[0],a=doc.anchors[1],b=doc.anchors[2],c=doc.anchors[3],work=doc.notes[0];
 const deleted=deleteMilestone(doc,b.id,texts);
 assert.throws(()=>deleteMilestone(doc,start.id,texts),/milestone to delete/);
 assert(!deleted.doc.anchors.some(n=>n.id===b.id));
 assert(deleted.doc.edges.some(e=>e.from===a.id&&e.to===c.id));
 assert(!deleted.doc.edges.some(e=>e.from===a.id&&e.to===b.id||e.from===b.id&&e.to===c.id));
 assert.equal(deleted.doc.notes[0].id,work.id);assert.equal(deleted.doc.notes[0].attach.kind,'edge');
 const stitch=deleted.doc.edges.find(e=>e.from===a.id&&e.to===c.id);
 assert.equal(deleted.doc.notes[0].attach.id,stitch.id);
 assert(deleted.deletes.some(d=>d.name===b.note));
 const next=readNote(deleted.writes.find(w=>w.name===a.note).text).meta.next.join(' ');
 assert(next.includes(c.title)||next.includes(c.note.replace(/\.md$/,'')));
 Object.assign(texts,Object.fromEntries(deleted.writes.map(w=>[w.name,w.text])));for(const d of deleted.deletes)delete texts[d.name];
 assert.deepEqual(resolveMap(deleted.doc,texts),deleted.doc);
 assert(mainMilestoneIDs(deleted.doc).has(a.id)&&mainMilestoneIDs(deleted.doc).has(c.id));
});
test('Deleting a branched milestone reconnects every predecessor to every successor',()=>{
 let r=linkedTransaction(createProject(emptyMap(),{title:'Fork',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'},{title:'C',date:'2026-10-30'}]})),texts=files(r),doc=r.doc;
 const a=doc.anchors[1],c=doc.anchors[3];
 r=linkedTransaction(addMilestone(doc,a.id,Object.keys(texts)),texts);Object.assign(texts,files(r));doc=r.doc;
 const extra=doc.anchors.find(n=>n.title==='New milestone');
 r=linkedTransaction(connectMilestones(doc,extra.id,c.id),texts);Object.assign(texts,files(r));doc=r.doc;
 const b=doc.anchors.find(n=>n.title==='B'),deleted=deleteMilestone(doc,b.id,texts);
 assert(!deleted.doc.anchors.some(n=>n.id===b.id));
 assert(deleted.doc.edges.some(e=>e.from===a.id&&e.to===c.id));
 assert(deleted.doc.edges.some(e=>e.from===extra.id&&e.to===c.id));
});
test('Deleting the final timeline leaves an empty usable map and removes remote references without deleting remote originals',()=>{
 const {doc,texts}=fixture(),attach=doc.notes[0].attach;doc.devices=[{id:'remote',label:'Device',attachments:[attach]}];doc.notes.push({...doc.notes[0],id:'remote-note',note:'Remote.md',device:'remote',cachedText:'Remote body'});
 const scope=timelineNodes(doc,doc.anchors[0].id);assert.equal(scope.notes.length,2);const r=deleteTimeline(doc,doc.anchors[0].id,texts);
 for(const key of ['projects','anchors','edges','notes','devices'])assert.deepEqual(r.doc[key],[]);
 assert.equal(r.deletes.length,4);assert(!r.deletes.some(d=>d.name==='Remote.md'));assert.equal(r.doc.id,doc.id);assert.throws(()=>deleteTimeline(doc,doc.anchors[1].id,texts),/start note/);
});
