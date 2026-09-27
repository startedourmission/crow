import {test} from 'node:test';
import assert from 'node:assert/strict';
import {emptyMap,createProject,addNote,addMilestone,connectMilestones,disconnectMilestones,mainMilestoneIDs,noteText,layoutMap,readNote,UNIT_WIDTH,reorderMilestones,noteOrbitRadius} from './crowmap-model.js';
import {linkedTransaction,resolveMap,deleteWorkNotes,moveNodes,movedDate,applyNoteDate,shiftFollowingDates,graphLinks} from './crowmap-links.js';
import {floatOffset,nodeDegrees,nodeRadius,stepNotes} from './crowmap-motion.js';
import {edgeScrollDelta,graphGestures} from './crowmap-gestures.js';
const files=r=>Object.fromEntries(r.writes.map(w=>[w.name,w.text]));
function fixture(){const result=linkedTransaction(createProject(emptyMap(),{title:'Project',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'},{title:'C',date:'2026-10-30'}]}));return {...result,texts:files(result)};}
test('graphGestures teardown unbinds canvas pointer handlers',()=>{
 const listeners=[];
 const canvas={viewBox:{baseVal:{x:0,y:0,width:1,height:1}},getBoundingClientRect:()=>({left:0,top:0,width:1,height:1}),
  addEventListener(type,fn,opts){listeners.push(fn);opts?.signal?.addEventListener('abort',()=>{const i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1);});},
  removeEventListener(type,fn){const i=listeners.indexOf(fn);if(i>=0)listeners.splice(i,1);}};
 const stub=()=>{};
 const stop=graphGestures({canvas,viewport:{getBoundingClientRect:()=>({left:0,top:0,right:1,bottom:1}),scrollLeft:0,scrollTop:0},notes:[],selection:new Set(),doc:{anchors:[],notes:[],edges:[]},layout:{points:new Map(),notePoints:new Map(),width:1,height:1,priorityY:()=>0,priorityAt:()=>1,x:()=>0,dateAt:()=>'2026-01-01',dateBounds:()=>({left:0,right:1})},preview:stub,pause:stub,resume:stub,onSelect:stub,onConnect:stub,onMove:stub,onReorder:stub});
 assert.equal(listeners.length,2);
 stop();assert.equal(listeners.length,0);
 stop();assert.equal(listeners.length,0);
});
test('Dragging near a viewport edge produces a scroll delta toward that edge',()=>{
 const box={left:0,top:0,right:400,bottom:300};
 assert.deepEqual(edgeScrollDelta(200,150,box),{x:0,y:0});
 assert(edgeScrollDelta(10,150,box).x<0);assert.equal(edgeScrollDelta(10,150,box).y,0);
 assert(edgeScrollDelta(390,150,box).x>0);assert(edgeScrollDelta(200,10,box).y<0);assert(edgeScrollDelta(200,290,box).y>0);
 assert(Math.abs(edgeScrollDelta(-20,150,box).x)>=Math.abs(edgeScrollDelta(20,150,box).x));
});
test('One-click branch preserves the old path and reconnects to one existing milestone',()=>{
 let {doc,texts}=fixture();const original=structuredClone(doc),a=doc.projects[0].route[1],b=doc.projects[0].route[2],c=doc.projects[0].route[3];
 let result=linkedTransaction(addMilestone(doc,a,Object.keys(texts)),texts);Object.assign(texts,files(result));doc=result.doc;const added=doc.anchors.at(-1);
 assert.equal(doc.anchors.length,5);assert(doc.projects[0].route.includes(added.id));assert(doc.edges.find(e=>e.from===a&&e.to===b).state==='active');
 result=linkedTransaction(connectMilestones(doc,added.id,b),texts);Object.assign(texts,files(result));doc=resolveMap(result.doc,texts);
 assert.deepEqual(doc.projects[0].route,[original.projects[0].route[0],a,added.id,b,c]);assert.equal(doc.anchors.filter(n=>n.id===b).length,1);assert.equal(doc.edges.filter(e=>e.state==='superseded').length,0);
 assert(readNote(texts[added.note]).meta.next.includes('[[Project-B]]'));assert.throws(()=>connectMilestones(doc,b,a),/later date/);assert.throws(()=>connectMilestones(doc,b,b),/different/);
});
test('Date moves keep YAML date type so the note editor still shows a date field',()=>{
 let {doc,texts}=fixture();const start=doc.anchors[0];
 const r=moveNodes(doc,[start.id],{days:1},texts);Object.assign(texts,files(r));
 const source=texts[start.note];
 assert.match(source,/date: 2026-10-02/);
 assert.doesNotMatch(source,/date: "2026-10-02"/);
 assert.equal(readNote(source).meta.date,'2026-10-02');
 assert.equal(readNote(source).meta.priority,1);
 assert.equal(typeof readNote(source).meta.priority,'number');
});
test('Note properties that delay a milestone past the next one gather crossed milestones on that date',()=>{
 let {doc,texts}=fixture();const a=doc.anchors[1],b=doc.anchors[2],c=doc.anchors[3];
 const source=texts[a.note].replace('2026-10-10','2026-10-25')+'\nKept body\n';
 const r=applyNoteDate(doc,a.note,source,texts),dates=id=>r.doc.anchors.find(n=>n.id===id).date;
 assert.equal(dates(a.id),'2026-10-25');assert.equal(dates(b.id),'2026-10-25');assert.equal(dates(c.id),'2026-10-30');
 assert.equal(readNote(r.writes.find(w=>w.name===a.note).text).meta.date,'2026-10-25');
 assert.equal(readNote(r.writes.find(w=>w.name===b.note).text).meta.date,'2026-10-25');
 assert.equal(r.writes.find(w=>w.name===c.note),undefined);
 assert(r.writes.find(w=>w.name===a.note).text.endsWith('Kept body\n'));
 assert.deepEqual(resolveMap(r.doc,{...texts,...Object.fromEntries(r.writes.map(w=>[w.name,w.text]))}),r.doc);
 assert.equal(shiftFollowingDates(doc,a.id,'2026-10-15',texts),null);
 const both=applyNoteDate(doc,a.note,texts[a.note].replace('2026-10-10','2026-11-05'),texts);
 assert.equal(both.doc.anchors.find(n=>n.id===a.id).date,'2026-11-05');
 assert.equal(both.doc.anchors.find(n=>n.id===b.id).date,'2026-11-05');
 assert.equal(both.doc.anchors.find(n=>n.id===c.id).date,'2026-11-05');
});
test('Note properties keep later milestones when the new date is still before the next one',()=>{
 let {doc,texts}=fixture();const a=doc.anchors[1],b=doc.anchors[2];
 const r=applyNoteDate(doc,a.note,texts[a.note].replace('2026-10-10','2026-10-15'),texts);
 assert.equal(r.doc.anchors.find(n=>n.id===a.id).date,'2026-10-15');
 assert.equal(r.doc.anchors.find(n=>n.id===b.id).date,'2026-10-20');
 assert.equal(r.writes.length,1);
});
test('Note properties that move a milestone earlier pull crossed previous milestones onto that date',()=>{
 let {doc,texts}=fixture();const start=doc.anchors[0],a=doc.anchors[1],b=doc.anchors[2],c=doc.anchors[3];
 const r=applyNoteDate(doc,b.note,texts[b.note].replace('2026-10-20','2026-10-05'),texts),dates=id=>r.doc.anchors.find(n=>n.id===id).date;
 assert.equal(dates(start.id),'2026-10-01');assert.equal(dates(a.id),'2026-10-05');assert.equal(dates(b.id),'2026-10-05');assert.equal(dates(c.id),'2026-10-30');
 const pulled=applyNoteDate(doc,a.note,texts[a.note].replace('2026-10-10','2026-09-20'),texts);
 assert.equal(pulled.doc.anchors.find(n=>n.id===start.id).date,'2026-09-20');
 assert.equal(pulled.doc.anchors.find(n=>n.id===a.id).date,'2026-09-20');
 assert.equal(pulled.doc.anchors.find(n=>n.id===b.id).date,'2026-10-20');
 const stayed=applyNoteDate(doc,b.note,texts[b.note].replace('2026-10-20','2026-10-12'),texts);
 assert.equal(stayed.doc.anchors.find(n=>n.id===a.id).date,'2026-10-10');
 assert.equal(stayed.doc.anchors.find(n=>n.id===b.id).date,'2026-10-12');
 assert.equal(stayed.writes.length,1);
});
test('Delaying a milestone past the next one moves later-segment work and leaves incoming work',()=>{
 let {doc,texts}=fixture();
 let r=linkedTransaction(addNote(doc,{title:'Incoming',date:'2026-10-05',attach:{kind:'edge',id:doc.edges[0].id}}),texts);Object.assign(texts,files(r));doc=r.doc;
 r=linkedTransaction(addNote(doc,{title:'Outgoing',date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;
 r=linkedTransaction(addNote(doc,{title:'Later',date:'2026-10-25',attach:{kind:'edge',id:doc.edges[2].id}}),texts);Object.assign(texts,files(r));doc=r.doc;
 const a=doc.anchors[1],applied=applyNoteDate(doc,a.note,texts[a.note].replace('2026-10-10','2026-10-25'),texts);
 const note=title=>applied.doc.notes.find(n=>n.title===title);
 assert.equal(note('Incoming').date,'2026-10-05');
 assert.equal(note('Outgoing').date,'2026-10-25');
 assert.equal(note('Later').date,'2026-10-25');
 assert.equal(note('Outgoing').attach.kind,'edge');assert.equal(note('Later').attach.kind,'edge');
 const pulled=applyNoteDate(doc,a.note,texts[a.note].replace('2026-10-10','2026-09-20'),texts),after=title=>pulled.doc.notes.find(n=>n.title===title);
 assert.equal(after('Incoming').date,'2026-09-20');
 assert.equal(after('Outgoing').date,'2026-10-15');
});
test('A delayed milestone does not shift a parallel branch that is not downstream',()=>{
 let {doc,texts}=fixture();const a=doc.anchors[1],c=doc.anchors[3];
 let r=linkedTransaction(addMilestone(doc,a.id,Object.keys(texts)),texts);Object.assign(texts,files(r));doc=r.doc;
 const added=doc.anchors.find(n=>n.title==='New milestone');
 r=linkedTransaction(connectMilestones(doc,added.id,c.id),texts);Object.assign(texts,files(r));doc=r.doc;
 const b=doc.anchors.find(n=>n.title==='B'),applied=applyNoteDate(doc,b.note,texts[b.note].replace('2026-10-20','2026-11-05'),texts);
 assert.equal(applied.doc.anchors.find(n=>n.id===b.id).date,'2026-11-05');
 assert.equal(applied.doc.anchors.find(n=>n.id===c.id).date,'2026-11-05');
 assert.equal(applied.doc.anchors.find(n=>n.id===added.id).date,added.date);
});
test('Dragging a milestone past the next one gathers crossed milestones on that date',()=>{
 let {doc,texts}=fixture();const a=doc.anchors[1],b=doc.anchors[2],c=doc.anchors[3];
 assert.equal(movedDate(doc,a.id,'2026-10-25'),'2026-10-25');
 const r=moveNodes(doc,[a.id],{days:15},texts),dates=id=>r.doc.anchors.find(n=>n.id===id).date;
 assert.equal(dates(a.id),'2026-10-25');assert.equal(dates(b.id),'2026-10-25');assert.equal(dates(c.id),'2026-10-30');
 assert.equal(readNote(files(r)[b.note]).meta.date,'2026-10-25');
 const stayed=moveNodes(doc,[a.id],{days:5},texts);
 assert.equal(stayed.doc.anchors.find(n=>n.id===a.id).date,'2026-10-15');
 assert.equal(stayed.doc.anchors.find(n=>n.id===b.id).date,'2026-10-20');
 const spaced=moveNodes(doc,[a.id],{days:15,preserveGaps:true},texts),keep=id=>spaced.doc.anchors.find(n=>n.id===id).date;
 assert.equal(keep(a.id),'2026-10-25');assert.equal(keep(b.id),'2026-11-04');assert.equal(keep(c.id),'2026-11-14');
});
test('Dragging a milestone earlier pulls crossed previous milestones onto that date',()=>{
 let {doc,texts}=fixture();const start=doc.anchors[0],a=doc.anchors[1],b=doc.anchors[2],c=doc.anchors[3];
 assert.equal(movedDate(doc,b.id,'2026-10-05'),'2026-10-05');
 const r=moveNodes(doc,[b.id],{days:-15},texts),dates=id=>r.doc.anchors.find(n=>n.id===id).date;
 assert.equal(dates(b.id),'2026-10-05');assert.equal(dates(a.id),'2026-10-05');assert.equal(dates(start.id),'2026-10-01');assert.equal(dates(c.id),'2026-10-30');
 const spaced=moveNodes(doc,[b.id],{days:-15,preserveGaps:true},texts),keep=id=>spaced.doc.anchors.find(n=>n.id===id).date;
 assert.equal(keep(b.id),'2026-10-05');assert.equal(keep(a.id),'2026-09-25');assert.equal(keep(start.id),'2026-09-16');assert.equal(keep(c.id),'2026-10-30');
});
test('Date moves reattach work without copying it and milestone dates respect attached work',()=>{
 let {doc,texts}=fixture();let r=linkedTransaction(addNote(doc,{title:'Work',date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;const note=doc.notes[0],milestone=doc.anchors[1];
 assert.equal(movedDate(doc,milestone.id,'2026-10-19'),'2026-10-19');
 assert.equal(movedDate(doc,milestone.id,'2026-10-25'),'2026-10-25');
 r=moveNodes(doc,[milestone.id],{days:9},texts);Object.assign(texts,files(r));
 assert.equal(r.doc.anchors.find(a=>a.id===milestone.id).date,'2026-10-19');
 assert.equal(r.doc.notes[0].date,'2026-10-19');
 doc=r.doc;Object.assign(texts,files(r));
 r=moveNodes(doc,[r.doc.notes[0].id],{days:6},texts);Object.assign(texts,files(r));assert.equal(r.doc.notes.length,1);assert.equal(r.doc.notes[0].id,note.id);assert.equal(r.doc.notes[0].date,'2026-10-25');assert.equal(r.doc.notes[0].attach.id,doc.edges[2].id);assert.equal(readNote(files(r)[note.note]??texts[note.note]).meta.date,'2026-10-25');assert.deepEqual(resolveMap(r.doc,{...texts,...files(r)}),r.doc);
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
 const degree=nodeDegrees(doc,graphLinks(doc,texts));assert.equal(degree.get(doc.notes[0].id),2);assert(nodeRadius('note',5)>nodeRadius('note',1));for(let t=0;t<100;t++){const offset=floatOffset('work',t,10);assert(Math.abs(offset.x)<=2.5);assert(Math.abs(offset.y)<=2.5);}
 assert.deepEqual(floatOffset('work',1,0),{x:0,y:0});
});
test('Same-date work notes sit on a ring around the edge, and tension 0 pins them',()=>{
 let {doc,texts}=fixture();
 for(const title of ['One','Two','Three','Four']){const r=linkedTransaction(addNote(doc,{title,date:'2026-10-15',attach:{kind:'edge',id:doc.edges[1].id}}),texts);Object.assign(texts,files(r));doc=r.doc;}
 const laid=layoutMap(doc,{noteTension:10}),notes=[...laid.notePoints.values()];
 const radii=notes.map(n=>Math.hypot(n.x-n.origin.x,n.y-n.origin.y));
 assert(radii.every(r=>Math.abs(r-radii[0])<1e-6));assert.equal(radii[0],10);
 assert.equal(new Set(notes.map(n=>Math.atan2(n.y-n.origin.y,n.x-n.origin.x).toFixed(3))).size,4);
 assert(notes.some(n=>n.y<n.origin.y));assert(notes.some(n=>n.y>n.origin.y));
 const tight=layoutMap(doc,{noteTension:4}),loose=layoutMap(doc,{noteTension:24});
 const rt=Math.hypot([...tight.notePoints.values()][0].x-[...tight.notePoints.values()][0].origin.x,[...tight.notePoints.values()][0].y-[...tight.notePoints.values()][0].origin.y);
 const rl=Math.hypot([...loose.notePoints.values()][0].x-[...loose.notePoints.values()][0].origin.x,[...loose.notePoints.values()][0].y-[...loose.notePoints.values()][0].origin.y);
 assert.equal(rt,4);assert.equal(rl,24);assert(rt<rl);assert.equal(noteOrbitRadius(4,4),4);assert.equal(noteOrbitRadius(4,0),0);
 const pinned=layoutMap(doc,{noteTension:0});
 assert([...pinned.notePoints.values()].every(n=>n.x===n.origin.x&&n.y===n.origin.y));
});
test('Nearby work notes push each other apart',()=>{
 const a={id:'a',x:0,y:0,origin:{x:0,y:0},orbit:14,point:{x:0,y:0},vx:0,vy:0};
 const b={id:'b',x:10,y:0,origin:{x:56,y:0},orbit:14,point:{x:10,y:0},vx:0,vy:0};
 for(let i=0;i<50;i++)stepNotes([a,b]);
 assert(Math.hypot(a.point.x-b.point.x,a.point.y-b.point.y)>12);
});

test('A long date range keeps one tick per day at a fixed column width',()=>{
 const r=createProject(emptyMap(),{title:'Span',date:'2000-01-01',priority:1,milestones:[{title:'End',date:'2020-01-01'}]});
 const layout=layoutMap(r.doc,{unit:'day'});
 assert(layout.tickCount>7000);
 assert.equal(layout.tickAt(1).x-layout.tickAt(0).x,UNIT_WIDTH);
 assert.equal(layout.tickAt(layout.tickCount-1).x-layout.tickAt(layout.tickCount-2).x,UNIT_WIDTH);
 assert.equal(layout.x('2000-01-02')-layout.x('2000-01-01'),UNIT_WIDTH);
 const i=Math.round((layout.x('2010-06-15')-layout.tickAt(0).x)/UNIT_WIDTH);
 assert.equal(layout.tickAt(i).date,'2010-06-15');
 assert.equal(layout.dateAt(layout.x('2010-06-15')),'2010-06-15');
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

test('Same-date swap rewrites previous/next so the timeline order changes',()=>{
 let {doc,texts}=fixture();const a=doc.anchors[1],b=doc.anchors[2];
 let r=moveNodes(doc,[b.id],{days:-10},texts);Object.assign(texts,files(r));doc=r.doc;
 assert(doc.edges.some(e=>e.from===a.id&&e.to===b.id));
 r=reorderMilestones(doc,a.id,b.id);assert(r.doc.edges.some(e=>e.from===b.id&&e.to===a.id));assert(!r.doc.edges.some(e=>e.from===a.id&&e.to===b.id));
 const linked=linkedTransaction(r,texts);Object.assign(texts,files(linked));
 assert(readNote(texts[a.note]).meta.previous.some(value=>value.includes(doc.anchors.find(n=>n.id===b.id).title)||value.includes(b.note.replace(/\.md$/,''))));
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
