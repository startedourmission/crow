import {test} from 'node:test';
import assert from 'node:assert/strict';
import {emptyMap,createProject,addNote,addMilestone,connectMilestones,disconnectMilestones,mainMilestoneIDs,noteText,layoutMap,readNote,UNIT_WIDTH} from './crowmap-model.js';
import {linkedTransaction,resolveMap,deleteWorkNotes,moveNodes,movedDate,graphLinks} from './crowmap-links.js';
import {floatOffset,nodeDegrees,nodeRadius} from './crowmap-motion.js';
const files=r=>Object.fromEntries(r.writes.map(w=>[w.name,w.text]));
function fixture(){const result=linkedTransaction(createProject(emptyMap(),{title:'Project',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'},{title:'C',date:'2026-10-30'}]}));return {...result,texts:files(result)};}
test('One-click branch preserves the old path and reconnects to one existing milestone',()=>{
 let {doc,texts}=fixture();const original=structuredClone(doc),a=doc.projects[0].route[1],b=doc.projects[0].route[2],c=doc.projects[0].route[3];
 let result=linkedTransaction(addMilestone(doc,a,Object.keys(texts)),texts);Object.assign(texts,files(result));doc=result.doc;const added=doc.anchors.at(-1);
 assert.equal(doc.anchors.length,5);assert(doc.projects[0].route.includes(added.id));assert(doc.edges.find(e=>e.from===a&&e.to===b).state==='active');
 result=linkedTransaction(connectMilestones(doc,added.id,b),texts);Object.assign(texts,files(result));doc=resolveMap(result.doc,texts);
 assert.deepEqual(doc.projects[0].route,[original.projects[0].route[0],a,added.id,b,c]);assert.equal(doc.anchors.filter(n=>n.id===b).length,1);assert.equal(doc.edges.filter(e=>e.state==='superseded').length,0);
 assert(readNote(texts[added.note]).meta.next.includes('[[Project-B]]'));assert.throws(()=>connectMilestones(doc,b,a),/later date/);assert.throws(()=>connectMilestones(doc,b,b),/different/);
});
test('Date moves reattach work without copying it and milestone dates respect attached work',()=>{
 let {doc,texts}=fixture();let r=linkedTransaction(addNote(doc,{title:'Work',date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;const note=doc.notes[0],milestone=doc.anchors[1];
 assert.equal(movedDate(doc,milestone.id,'2026-10-19'),'2026-10-15');
 r=moveNodes(doc,[note.id],{days:10},texts);Object.assign(texts,files(r));assert.equal(r.doc.notes.length,1);assert.equal(r.doc.notes[0].id,note.id);assert.equal(r.doc.notes[0].date,'2026-10-25');assert.equal(r.doc.notes[0].attach.id,doc.edges[2].id);assert.equal(readNote(texts[note.note]).meta.date,'2026-10-25');assert.deepEqual(resolveMap(r.doc,texts),r.doc);
});
test('Priority moves cross projects and date spacing keeps attachments aligned',()=>{
 let {doc,texts}=fixture();let r=linkedTransaction(createProject(doc,{title:'Other',date:'2026-10-01',priority:2,milestones:[{title:'End',date:'2026-11-01'}]},Object.keys(texts)),texts);Object.assign(texts,files(r));doc=r.doc;
 r=moveNodes(doc,[doc.projects[1].route[1]],{days:-15,priority:1},texts);Object.assign(texts,files(r));const layout=layoutMap(r.doc),other=r.doc.projects[1].route[1],end=r.doc.projects[0].route.at(-1);assert(layout.points.get(other).y<layout.points.get(end).y);
 assert.equal(readNote(texts[r.doc.anchors.find(a=>a.id===other).note]).meta.priority,1);
});
test('Bulk deletion handles mutually linked notes atomically and keeps surviving link labels',()=>{
 let {doc,texts}=fixture();for(const [title,body]of [['A work',''],['B work','[[A work]]'],['Keep','[[A work|first]] [[B work]]']]){const r=linkedTransaction(addNote(doc,{title,body,date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;}
 const r=deleteWorkNotes(doc,doc.notes.slice(0,2).map(n=>n.id),texts);assert.equal(r.doc.notes.length,1);assert.equal(r.deletes.length,2);assert(r.writes.find(w=>w.name==='Keep.md').text.endsWith('first B work'));assert.equal(r.doc.anchors.length,4);assert.throws(()=>deleteWorkNotes(doc,[doc.anchors[0].id],texts),/not found/);
});
test('Repeated links do not inflate node size and floating stays close to the dated position',()=>{
 let {doc,texts}=fixture();for(const [title,body]of [['Work',''],['Link','[[Work]] [[Work]]']]){const r=linkedTransaction(addNote(doc,{title,body,date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;}
 const degree=nodeDegrees(doc,graphLinks(doc,texts));assert.equal(degree.get(doc.notes[0].id),2);assert(nodeRadius('note',5)>nodeRadius('note',1));for(let t=0;t<100;t++){const offset=floatOffset('work',t);assert(Math.abs(offset.x)<44);assert(Math.abs(offset.y)<=5);}assert.notDeepEqual(floatOffset('work',0),floatOffset('work',2));
});

test('Date columns keep a fixed unit width and round-trip every date',()=>{
 let {doc,texts}=fixture();const r=linkedTransaction(addNote(doc,{title:'Middle',date:'2026-10-11',attach:{kind:'edge',id:doc.edges[1].id}}),texts);doc=r.doc;
 const original=structuredClone(doc),days=layoutMap(doc,{unit:'day'});
 assert.equal(days.x('2026-10-11')-days.x('2026-10-10'),UNIT_WIDTH);
 for(let d=1;d<=30;d++){const date='2026-10-'+String(d).padStart(2,'0');assert.equal(days.dateAt(days.x(date)),date);const bounds=days.dateBounds(date);assert.equal(bounds.right-bounds.left,UNIT_WIDTH);assert(bounds.left<=days.x(date)&&days.x(date)<bounds.right);}
 const weeks=layoutMap(doc,{unit:'week'});assert.equal(weeks.x('2026-10-12')-weeks.x('2026-10-05'),UNIT_WIDTH);assert.equal(weeks.dateAt(weeks.x('2026-10-15')),'2026-10-15');
 const months=layoutMap(doc,{unit:'month'});assert.equal(months.x('2026-11-01')-months.x('2026-10-01'),UNIT_WIDTH);assert.equal(months.dateAt(months.x('2026-10-20')),'2026-10-20');
 const years=layoutMap(createProject(emptyMap(),{title:'Span',date:'2025-06-01',priority:1,milestones:[{title:'Later',date:'2027-03-01'}]}).doc,{unit:'year'});
 assert.equal(years.x('2027-01-01')-years.x('2026-01-01'),UNIT_WIDTH);assert.equal(years.dateAt(years.x('2026-08-15')),'2026-08-15');
 assert.deepEqual(doc,original);
});

test('Parallel same-date branches all remain main and stack separately before a shared milestone',()=>{
 let {doc,texts}=fixture();const from=doc.projects[0].route[1],to=doc.projects[0].route[2],oldEdge=doc.edges.find(e=>e.from===from&&e.to===to).id;
 for(let i=0;i<3;i++){let r=linkedTransaction(addMilestone(doc,from,Object.keys(texts)),texts);Object.assign(texts,files(r));const added=r.doc.anchors.at(-1);r=linkedTransaction(connectMilestones(r.doc,added.id,to),texts);Object.assign(texts,files(r));doc=r.doc;}
 const layout=layoutMap(doc),branches=doc.anchors.filter(n=>n.title==='New milestone');
 assert.equal(branches.length,3);assert.equal(new Set(branches.map(n=>layout.points.get(n.id).x)).size,1);
 assert.equal(new Set(branches.map(n=>layout.points.get(n.id).y)).size,3);
 assert(branches.every(n=>mainMilestoneIDs(doc).has(n.id)));assert(doc.edges.every(e=>e.state==='active'));
 assert(doc.edges.some(e=>e.id===oldEdge));assert.equal(doc.anchors.filter(n=>n.id===to).length,1);
 assert.deepEqual(resolveMap(doc,texts),doc);
});

test('Disconnecting all incident edges isolates only that milestone and preserves work on disk roundtrip',()=>{
 let {doc,texts}=fixture();const retired=doc.anchors[2],incoming=doc.edges.find(e=>e.to===retired.id),outgoing=doc.edges.find(e=>e.from===retired.id);
 let r=linkedTransaction(addNote(doc,{title:'Keep work',date:'2026-10-15',attach:{kind:'edge',id:incoming.id},body:'Keep body'}),texts);Object.assign(texts,files(r));doc=r.doc;
 r=linkedTransaction(disconnectMilestones(doc,incoming.id),texts);Object.assign(texts,files(r));doc=r.doc;
 assert(mainMilestoneIDs(doc).has(retired.id),'One remaining connection keeps it main');
 assert.deepEqual(doc.notes[0].attach,{kind:'anchor',id:incoming.from});
 assert.equal(readNote(texts['Keep work.md']).meta.milestone,'[[Project-A]]');assert(texts['Keep work.md'].endsWith('Keep body'));
 r=linkedTransaction(disconnectMilestones(doc,outgoing.id),texts);Object.assign(texts,files(r));doc=resolveMap(r.doc,texts);
 assert(!mainMilestoneIDs(doc).has(retired.id));assert(doc.anchors.some(n=>n.id===retired.id));assert(texts[retired.note]);
 assert.deepEqual(readNote(texts[retired.note]).meta.previous,[]);assert.deepEqual(readNote(texts[retired.note]).meta.next,[]);
 assert(readNote(texts['Project.md']).meta.milestones.includes('[[Project-B]]'));
 assert(!doc.edges.some(e=>e.from===retired.id||e.to===retired.id));assert.equal(doc.notes.length,1);
 r=linkedTransaction(connectMilestones(doc,incoming.from,retired.id),texts);Object.assign(texts,files(r));assert(mainMilestoneIDs(resolveMap(r.doc,texts)).has(retired.id));
});

test('Legacy inactive metadata never demotes actual links, and same-day cycles remain invalid',()=>{
 let {doc,texts}=fixture();doc.edges.forEach(e=>e.state='superseded');
 texts['Project-A.md']=texts['Project-A.md'].replace('---\n','---\ninactive_next: ["[[Project-B]]"]\n');
 doc=resolveMap(doc,texts);assert(doc.edges.every(e=>e.state==='active'));assert.equal(mainMilestoneIDs(doc).size,4);
 let r=linkedTransaction({doc,writes:[]},texts);Object.assign(texts,files(r));assert.equal(readNote(texts['Project-A.md']).meta.inactive_next,undefined);
 texts['Project-B.md']=texts['Project-B.md'].replace('2026-10-20','2026-10-10');doc=resolveMap(r.doc,texts);
 assert.throws(()=>connectMilestones(doc,doc.anchors[2].id,doc.anchors[1].id),/cycle/);
 texts['Project-B.md']=texts['Project-B.md'].replace('next:\n','next:\n  - "[[Project-A]]"\n');
 assert.throws(()=>resolveMap(doc,texts),/cycle/);
});

test('Consecutive same-date main milestones have separate vertical positions and real edge endpoints',()=>{
 const r=createProject(emptyMap(),{title:'Same date',date:'2026-10-01',priority:1,milestones:[{title:'Build',date:'2026-10-09'},{title:'New milestone',date:'2026-10-09'},{title:'Another milestone',date:'2026-10-09'},{title:'Release',date:'2026-10-16'}]});
 const before=structuredClone(r.doc),layout=layoutMap(r.doc),nodes=r.doc.anchors.slice(1,4),points=nodes.map(n=>layout.points.get(n.id));
 assert.equal(new Set(points.map(p=>p.x)).size,1,'The date position must not move');
 assert.equal(new Set(points.map(p=>p.y)).size,3,'Nodes, not only their curves, must separate');
 assert(points.slice(1).every((p,i)=>p.y-points[i].y>=48));
 for(const edge of r.doc.edges){const line=layout.edgePoints.get(edge.id);assert.equal(line[0],layout.points.get(edge.from));assert.equal(line.at(-1),layout.points.get(edge.to));}
 assert.deepEqual(r.doc,before,'Visual stacking must not edit dates or priorities');
 assert.equal(new Set(nodes.map(n=>layoutMap(r.doc,{unit:'year'}).points.get(n.id).y)).size,3);
});

test('Same-date ordering only changes view state and survives reload without modifying Markdown',async()=>{
 const {reorderMilestones}=await import('./crowmap-model.js');let {doc,texts}=fixture();let r=linkedTransaction(addMilestone(doc,doc.anchors[1].id),texts);Object.assign(texts,files(r));doc=r.doc;const a=doc.anchors.at(-1);
 r=linkedTransaction(addMilestone(doc,doc.anchors[1].id,Object.keys(texts)),texts);Object.assign(texts,files(r));doc=r.doc;const b=doc.anchors.at(-1),before=structuredClone(doc),old=layoutMap(doc);
 r=reorderMilestones(doc,a.id,b.id);assert.deepEqual(r.writes,[]);const restored=resolveMap(r.doc,texts),layout=layoutMap(restored);
 assert.equal(layout.points.get(a.id).y,old.points.get(b.id).y);assert.equal(layout.points.get(b.id).y,old.points.get(a.id).y);
 assert.deepEqual(restored.anchors,before.anchors);assert.deepEqual(restored.edges,before.edges);assert.deepEqual(doc,before);
 assert.throws(()=>reorderMilestones(doc,a.id,doc.anchors[0].id),/same date/);
});

test('Moving the upper same-day milestone changes the project rank; Cmd propagates through later dates only',()=>{
 let {doc,texts}=fixture();let r=linkedTransaction(createProject(doc,{title:'Other',date:'2026-10-01',priority:2,milestones:[{title:'Other end',date:'2026-10-30'}]}),texts);Object.assign(texts,files(r));doc=r.doc;
 r=linkedTransaction(addMilestone(doc,doc.anchors[1].id),texts);Object.assign(texts,files(r));doc=r.doc;const added=doc.anchors.find(n=>n.title==='New milestone'),sameDate=doc.anchors[2];
 r=moveNodes(doc,[added.id],{days:5},texts);Object.assign(texts,files(r));doc=r.doc;
 assert.equal(doc.anchors.find(n=>n.id===added.id).date,sameDate.date);
 const atDate=doc.anchors.filter(n=>n.project===sameDate.project&&n.date===sameDate.date),upper=atDate.sort((a,b)=>layoutMap(doc).points.get(a.id).y-layoutMap(doc).points.get(b.id).y)[0];
 r=moveNodes(doc,[upper.id],{priority:2},texts);const normal=r.doc;
 assert(normal.anchors.filter(n=>n.project===sameDate.project&&n.date===sameDate.date).every(n=>n.priority===2));assert.equal(layoutMap(normal).rankAt(sameDate.project,sameDate.date),2);
 assert.equal(normal.anchors.find(n=>n.id===doc.projects[0].route.at(-1)).priority,1,'An ordinary drag does not rewrite later milestones');
 r=moveNodes(doc,[upper.id],{priority:2,cascadePriority:true},texts);Object.assign(texts,files(r));const cascading=resolveMap(r.doc,texts);
 assert(cascading.anchors.filter(n=>n.project===sameDate.project&&n.date>=sameDate.date).every(n=>n.priority===2));
 assert(cascading.anchors.filter(n=>n.project===sameDate.project&&n.date<sameDate.date).every(n=>n.priority===1));
 assert.deepEqual(cascading.anchors.filter(n=>n.project!==sameDate.project),doc.anchors.filter(n=>n.project!==sameDate.project));
});
