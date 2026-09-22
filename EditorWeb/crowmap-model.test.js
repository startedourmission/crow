import {test} from 'node:test';import assert from 'node:assert/strict';
import {updateNote,emptyMap,createProject,revisePlan,addNote,addMilestone,validateMap,linkLeaves,layoutMap,readNote,timelineCurveY,PRIORITY_GAP,clampPriorityGap,dateLabelStride,mapCamera,setProjectColor,UNIT_WIDTH} from './crowmap-model.js';
function fixture(){return createProject(emptyMap(),{title:'Project',date:'2026-01-01',priority:1,milestones:[{title:'A',date:'2026-01-10'},{title:'B',date:'2026-01-20'},{title:'C',date:'2026-01-30'}]});}
test('Start note carries complete plan and notes stay flat with mandatory dates',()=>{const r=fixture();assert.equal(readNote(r.writes[0].text).meta.milestones.length,3);assert.equal(r.writes.length,4);assert.throws(()=>addNote(r.doc,{title:'No date',date:'',body:'',attach:{kind:'edge',id:r.doc.edges[0].id}}));assert.throws(()=>addNote(r.doc,{title:'Outside segment',date:'2026-02-01',attach:{kind:'edge',id:r.doc.edges[0].id}}));});
test('Adding a milestone on a segment inserts it on that edge at the requested date',()=>{
 const {doc}=fixture(),segment=doc.edges[1],from=segment.from,to=segment.to;
 const r=addMilestone(doc,from,[],{edgeID:segment.id,date:'2026-01-15'});
 const added=r.doc.anchors.find(a=>a.title==='New milestone');
 assert.equal(added.date,'2026-01-15');
 assert.equal(r.doc.edges.find(e=>e.id===segment.id).to,added.id);
 assert(r.doc.edges.some(e=>e.from===added.id&&e.to===to));
 assert(!r.doc.edges.some(e=>e.from===from&&e.to===to));
});
test('Adding a next milestone from the last node extends the timeline by a week',()=>{
 const {doc}=fixture(),last=doc.anchors.at(-1);
 assert(!doc.edges.some(e=>e.from===last.id));
 const r=addMilestone(doc,last.id);
 const added=r.doc.anchors.at(-1);
 assert.equal(added.date,'2026-02-06');
 assert(r.doc.edges.some(e=>e.from===last.id&&e.to===added.id));
 assert.equal(r.doc.anchors.filter(a=>a.kind==='milestone'||a.kind==='revision').length,4);
});
test('Partial plan changes preserve work and both main branches and rejoin the SAME milestone',()=>{let {doc}=fixture();const p=doc.projects[0],a=p.route[1],b=p.route[2],c=p.route[3],segment=doc.edges[1];doc=addNote(doc,{title:'Work',date:'2026-01-13',body:'[ref](https://example.com)',attach:{kind:'edge',id:segment.id}}).doc;const oldNote=structuredClone(doc.notes[0]);const r=revisePlan(doc,{project:p.id,from:a,rejoin:c,date:'2026-01-14',priority:1,title:'Scope change',milestones:[{title:'New B',date:'2026-01-23'}]});assert.equal(r.doc.anchors.filter(n=>n.id===c).length,1);assert(r.doc.projects[0].route.includes(b));assert.equal(r.doc.projects[0].route.at(-1),c);assert.deepEqual(r.doc.notes[0],oldNote);assert.equal(r.doc.edges.find(e=>e.id===segment.id).state,'active');assert.equal(r.writes.length,2);assert(r.doc.edges.every(e=>e.state==='active'));assert.equal(doc.anchors.length,4);validateMap(r.doc);});
test('Rank changes cross project paths and edge notes retain their own date coordinates',()=>{let {doc}=fixture();assert.equal(layoutMap(doc).priorityY(2)-layoutMap(doc).priorityY(1),PRIORITY_GAP);assert.equal(layoutMap(doc,{priorityGap:120}).priorityY(2)-layoutMap(doc,{priorityGap:120}).priorityY(1),120);assert.equal(clampPriorityGap(40),40);assert.equal(clampPriorityGap(5),28);assert.equal(clampPriorityGap(900),400);doc=createProject(doc,{title:'Other',date:'2026-01-01',priority:2,milestones:[{title:'Urgent',date:'2026-01-15',priority:1}]}).doc;const map=layoutMap(doc);const first=doc.projects[0],second=doc.projects[1];assert(map.points.get(first.route[0]).y<map.points.get(second.route[0]).y);assert(map.points.get(first.route.at(-1)).y>map.points.get(second.route.at(-1)).y);doc=addNote(doc,{title:'Process',date:'2026-01-12',attach:{kind:'edge',id:doc.edges[1].id},body:''}).doc;const l=layoutMap(doc);assert.equal(l.notePoints.get(doc.notes[0].id).x,l.x('2026-01-12'));});
test('Changing a timeline color updates only the display cache',()=>{
 const r=fixture(),id=r.doc.projects[0].id,colored=setProjectColor(r.doc,id,'#3F8A86');
 assert.equal(r.doc.projects[0].color,'#476fa8');assert.equal(colored.doc.projects[0].color,'#3f8a86');assert.equal(colored.writes.length,0);
 assert.throws(()=>setProjectColor(r.doc,id,'blue'));
});
test('Zoomed-out date labels skip a regular interval instead of changing scale',()=>{
 assert.equal(dateLabelStride(1),1);
 assert.equal(dateLabelStride(2),1);
 assert(dateLabelStride(.15)>1);
 assert.equal(dateLabelStride(.15),dateLabelStride(.15));
});
test('Date-axis camera matches the map camera x range at every zoom',()=>{
 for(const z of [.15,.5,1,1.25,2,3]){
  const cam=mapCamera(800,120,z,1400,700);
  assert.equal(cam.date.x,cam.x);
  assert.equal(cam.date.w,cam.w);
  assert.equal(cam.date.h,32/z);
  assert(Math.abs(cam.date.w/cam.date.h-1400/32)<1e-10);
  assert.equal(cam.x+cam.w,(800+1400)/z);
 }
});
test('Layout ticks are indexed without building a full array',()=>{
 const layout=layoutMap(createProject(emptyMap(),{title:'Span',date:'2010-01-01',priority:1,milestones:[{title:'End',date:'2012-01-01'}]}).doc,{unit:'month'});
 assert(layout.tickCount>20);assert(layout.tickCount<40);
 assert.equal(layout.tickAt(1).x-layout.tickAt(0).x,UNIT_WIDTH);
 assert.equal(layout.ticks,undefined);
});
test('A later priority 2 project sits above an earlier priority 4 project',()=>{
 let doc=createProject(emptyMap(),{title:'Old',date:'2026-01-01',priority:4,milestones:[{title:'End',date:'2026-06-01',priority:4}]}).doc;
 doc=createProject(doc,{title:'New',date:'2026-03-01',priority:2,milestones:[{title:'End',date:'2026-06-01',priority:2}]}).doc;
 const layout=layoutMap(doc),old=doc.projects[0],neu=doc.projects[1];
 assert.equal(layout.rankAt(neu.id,'2026-03-01'),2);
 assert.equal(layout.rankAt(old.id,'2026-03-01'),4);
 assert(layout.points.get(neu.route[0]).y<layout.points.get(old.route.at(-1)).y);
});
test('Same-priority branches each keep their own lane from the fork',()=>{
 const base=createProject(emptyMap(),{title:'Line',date:'2026-01-01',priority:1,milestones:[{title:'A',date:'2026-02-01'},{title:'B',date:'2026-06-01'}]});
 const branched=addMilestone(base.doc,base.doc.projects[0].route[1]);
 const layout=layoutMap(branched.doc),from=base.doc.projects[0].route[1];
 const edges=branched.doc.edges.filter(e=>e.from===from);
 assert(edges.length>=2);
 const midY=edge=>{const pts=layout.edgePoints.get(edge.id),a=pts[0],b=pts.at(-1),m=a.x+(b.x-a.x)*.5;for(let i=0;i<pts.length-1;i++){const p=pts[i],q=pts[i+1];if(m<Math.min(p.x,q.x)||m>Math.max(p.x,q.x))continue;return p.x===q.x?p.y:p.y+(q.y-p.y)*(m-p.x)/(q.x-p.x);}return a.y;};
 assert(Math.abs(midY(edges[0])-midY(edges[1]))>=90);
 for(const edge of edges){
  const pts=layout.edgePoints.get(edge.id),src=layout.points.get(edge.from),dst=layout.points.get(edge.to);
  assert.equal(pts[0],src);assert.equal(pts.at(-1),dst);
  if(Math.abs(src.y-dst.y)<.5)continue;
  const entered=pts.find(p=>p!==src&&Math.abs(p.y-dst.y)<1);
  assert(entered);assert(entered.x-src.x<=UNIT_WIDTH);assert(dst.x-entered.x>src.x-entered.x);
 }
});
test('A same-date connection does not stretch far to the side of its nodes',()=>{
 const r=createProject(emptyMap(),{title:'Stack',date:'2026-10-01',priority:1,milestones:[{title:'Build',date:'2026-10-09'},{title:'Next',date:'2026-10-09'},{title:'Release',date:'2026-10-16'}]});
 const layout=layoutMap(r.doc),a=r.doc.anchors[1],b=r.doc.anchors[2],edge=r.doc.edges.find(e=>e.from===a.id&&e.to===b.id),pts=layout.edgePoints.get(edge.id);
 const x=layout.points.get(a.id).x;
 assert(Math.max(...pts.map(p=>p.x))-x<20);
 assert(x-Math.min(...pts.map(p=>p.x))<20);
 assert.equal(pts[0],layout.points.get(a.id));assert.equal(pts.at(-1),layout.points.get(b.id));
});
test('Overlapping timeline runs keep a vertical gap along the shared stretch',()=>{
 let doc=createProject(emptyMap(),{title:'One',date:'2026-01-01',priority:1,milestones:[{title:'A',date:'2026-01-10'},{title:'B',date:'2026-03-01'}]}).doc;
 doc=createProject(doc,{title:'Two',date:'2026-01-01',priority:1,milestones:[{title:'A',date:'2026-01-10'},{title:'B',date:'2026-03-01'}]}).doc;
 const layout=layoutMap(doc);
 const ya=layout.points.get(doc.projects[0].route[1]).y,yb=layout.points.get(doc.projects[1].route[1]).y;
 assert(Math.abs(ya-yb)>=95);
});
test('Stacked priority 1 stays above a priority 2 lane',()=>{
 let doc=createProject(emptyMap(),{title:'First',date:'2026-01-01',priority:1,milestones:[{title:'End',date:'2026-06-01'}]}).doc;
 doc=createProject(doc,{title:'Second',date:'2026-03-01',priority:1,milestones:[{title:'End',date:'2026-06-01'}]}).doc;
 doc=createProject(doc,{title:'Lower',date:'2026-01-01',priority:2,milestones:[{title:'End',date:'2026-06-01'}]}).doc;
 const layout=layoutMap(doc);
 const p2=layout.points.get(doc.projects[2].route[0]).y;
 assert(layout.points.get(doc.projects[0].route.at(-1)).y<p2);
 assert(layout.points.get(doc.projects[1].route[0]).y<p2);
});
test('Same-priority project spines never share a height',()=>{
 let doc=createProject(emptyMap(),{title:'One',date:'2026-01-01',priority:1,milestones:[{title:'End',date:'2026-06-01'}]}).doc;
 doc=createProject(doc,{title:'Two',date:'2026-02-01',priority:1,milestones:[{title:'End',date:'2026-07-01'}]}).doc;
 const layout=layoutMap(doc);
 const y0=layout.points.get(doc.projects[0].route[0]).y,y1=layout.points.get(doc.projects[1].route[0]).y;
 assert(Math.abs(y0-y1)>=95);
 for(const e of doc.edges){
  const pts=layout.edgePoints.get(e.id),other=doc.projects.find(p=>p.id!==e.project);
  const otherY=layout.points.get(other.route[0]).y;
  for(let i=0;i<pts.length-1;i++){
   const p=pts[i],q=pts[i+1];if(Math.abs(p.y-q.y)>.5)continue;
   assert(Math.abs(p.y-otherY)>=90,'A horizontal run must not sit on another same-priority timeline');
  }
 }
});
test('Same-priority timelines keep a vertical gap',()=>{
 let doc=createProject(emptyMap(),{title:'One',date:'2026-01-01',priority:1,milestones:[{title:'End',date:'2026-06-01'}]}).doc;
 doc=createProject(doc,{title:'Two',date:'2026-01-01',priority:1,milestones:[{title:'End',date:'2026-06-01'}]}).doc;
 const layout=layoutMap(doc),a=layout.points.get(doc.projects[0].route[0]).y,b=layout.points.get(doc.projects[1].route[0]).y;
 assert(Math.abs(a-b)>=95);
});
test('A split branch stays level then bends next to the destination',()=>{
 const r=createProject(emptyMap(),{title:'Project',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'}]});
 const from=r.doc.projects[0].route[1],to=r.doc.projects[0].route[2];
 const branched=addMilestone(r.doc,from,[],{edgeID:r.doc.edges.find(e=>e.from===from&&e.to===to).id,date:'2026-10-15'});
 const layout=layoutMap(branched.doc),added=branched.doc.anchors.find(n=>n.title==='New milestone');
 const start=layout.points.get(from),end=layout.points.get(added.id),edge=branched.doc.edges.find(e=>e.from===from&&e.to===added.id),pts=layout.edgePoints.get(edge.id);
 if(Math.abs(start.y-end.y)>=.5){const hold=pts.at(-2);assert(Math.abs(hold.y-start.y)<1);assert(end.x-hold.x<=UNIT_WIDTH);}
});
test('A timeline does not follow another project\'s priority events',()=>{
 let doc=createProject(emptyMap(),{title:'Book',date:'2026-01-01',priority:2,milestones:[{title:'Contract',date:'2026-02-01',priority:2},{title:'Cover',date:'2026-08-01',priority:1}]}).doc;
 doc=createProject(doc,{title:'Other',date:'2026-03-01',priority:2,milestones:[{title:'Later',date:'2026-09-01',priority:3}]}).doc;
 const layout=layoutMap(doc),edge=doc.edges.find(e=>e.to===doc.projects[0].route[2]),pts=layout.edgePoints.get(edge.id);
 const ys=pts.map(p=>p.y),fromY=layout.points.get(edge.from).y,toY=layout.points.get(edge.to).y;
 assert(ys.every(y=>Math.abs(y-fromY)<1||Math.abs(y-toY)<1),'Other projects must not insert extra heights on this edge');
});
test('Priority changes bend inside the date column instead of across the whole segment',()=>{
 const doc=createProject(emptyMap(),{title:'Project',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10',priority:1},{title:'B',date:'2026-10-20',priority:3}]}).doc;
 const layout=layoutMap(doc),a=doc.anchors[1],b=doc.anchors[2],edge=doc.edges.find(e=>e.from===a.id&&e.to===b.id),pts=layout.edgePoints.get(edge.id);
 const from=layout.points.get(a.id),to=layout.points.get(b.id),hold=pts.at(-2);
 assert.notEqual(from.y,to.y);assert.equal(pts.at(-1),to);
 assert(Math.abs(hold.y-from.y)<1);assert(to.x-hold.x<=UNIT_WIDTH);assert(to.x-hold.x>0);
});
test('A timeline keeps its lane when another same-priority project appears',()=>{
 let doc=createProject(emptyMap(),{title:'Project',date:'2026-10-01',priority:1,milestones:[{title:'A',date:'2026-10-10'},{title:'B',date:'2026-10-20'}]}).doc;
 doc=createProject(doc,{title:'Other',date:'2026-10-08',priority:1,milestones:[{title:'Urgent',date:'2026-10-15',priority:2}]}).doc;
 const layout=layoutMap(doc),start=doc.projects[0].route[0],a=doc.projects[0].route[1],b=doc.projects[0].route[2];
 const stem=doc.edges.find(e=>e.from===start&&e.to===a),later=doc.edges.find(e=>e.from===a&&e.to===b);
 assert.equal(layout.edgePoints.get(stem.id)[0],layout.points.get(start));assert.equal(layout.edgePoints.get(stem.id).at(-1),layout.points.get(a));
 assert.equal(layout.points.get(start).y,layout.points.get(a).y);
 assert.equal(layout.points.get(a).y,layout.points.get(b).y);
 assert.notEqual(layout.points.get(start).y,layout.points.get(doc.projects[1].route[0]).y);
 assert.equal(layout.edgePoints.get(later.id)[0],layout.points.get(a));assert.equal(layout.edgePoints.get(later.id).at(-1),layout.points.get(b));
 assert.equal(timelineCurveY({x:0,y:0},{x:10,y:10},5,true),5);assert.notEqual(timelineCurveY({x:0,y:0},{x:10,y:10},5),5);
});
test('Links are per-occurrence terminal leaves, never a shared graph identity',()=>{const a=linkLeaves('a','[same](https://example.com) [again](https://example.com)'),b=linkLeaves('b','https://example.com');assert.equal(a.length,2);assert.equal(new Set([...a,...b].map(n=>n.id)).size,3);assert(a.every(n=>n.owner==='a'));assert.equal(linkLeaves('x','`https://hidden.com` [bad](javascript:alert)').length,0);});

test('Editing a real note retains frontmatter comments and unknown metadata',()=>{const before='---\n# project context\ntitle: Work\ndate: 2026-01-13\ncustom: preserved\n---\n\nBefore';const after=updateNote(before,{title:'Edited',date:'2026-01-14',body:'After'});assert(after.includes('# project context'));assert(after.includes('custom: preserved'));assert(after.includes('title: Edited'));assert(after.endsWith('After'));});
