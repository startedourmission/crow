import {parse, stringify} from 'yaml';
import {noteName} from './crowmap-links.js';
import {editFrontmatter} from './frontmatter-model.js';
const DAY=86400000;
export const uid=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),byte=>byte.toString(16).padStart(2,'0')).join('');
export function day(value){if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(value)||new Date(value+'T00:00:00Z').toISOString().slice(0,10)!==value)throw Error('Choose a valid date.');return Date.parse(value+'T00:00:00Z')/DAY;}
export const today=()=>new Date().toLocaleDateString('en-CA');
export function emptyMap(title='Crowmap'){return {version:1,id:uid(),title,projects:[],anchors:[],edges:[],notes:[],devices:[]};}
export function validateMap(doc){
  if(doc?.version!==1||typeof doc.id!=='string'||typeof doc.title!=='string')throw Error('Unsupported Crowmap document.');
  for(const key of ['projects','anchors','edges','notes','devices'])if(!Array.isArray(doc[key])||doc[key].length>10000)throw Error('Invalid Crowmap '+key+'.');
  const ids=new Set();for(const item of [...doc.projects,...doc.anchors,...doc.edges,...doc.notes,...doc.devices]){if(!item.id||ids.has(item.id))throw Error('Duplicate Crowmap ID.');ids.add(item.id);}
  const anchors=new Map(doc.anchors.map(a=>[a.id,a])),projects=new Set(doc.projects.map(p=>p.id)),edges=new Map(doc.edges.map(e=>[e.id,e]));
  for(const a of doc.anchors){day(a.date);if(!projects.has(a.project)||!['start','milestone','revision'].includes(a.kind)||!Number.isInteger(a.priority)||a.priority<1||!flatNote(a.note))throw Error('Invalid timeline milestone.');}
  for(const e of doc.edges){const a=anchors.get(e.from),b=anchors.get(e.to);if(!a||!b||a.project!==e.project||b.project!==e.project||a.id===b.id||b.kind==='start'||day(a.date)>day(b.date)||!['active','superseded'].includes(e.state))throw Error('Invalid timeline segment.');}
  for(const p of doc.projects){if(!Array.isArray(p.route)||!p.route.length||anchors.get(p.route[0])?.kind!=='start')throw Error('A project needs a start note.');const seen=new Set();for(const id of p.route){const a=anchors.get(id);if(!a||a.project!==p.id||seen.has(id))throw Error('Invalid milestone order.');seen.add(id);}orderedMilestones(doc,p);}
  const devices=new Set(doc.devices.map(d=>d.id));
  for(const n of doc.notes){day(n.date);if(!flatNote(n.note)||n.device&&!devices.has(n.device))throw Error('Invalid note source.');const target=n.attach?.kind==='edge'?edges.get(n.attach.id):n.attach?.kind==='anchor'?anchors.get(n.attach.id):null;if(!target)throw Error('A note must belong to a milestone or segment.');if(n.attach.kind==='edge'){const a=anchors.get(target.from),b=anchors.get(target.to);if(day(n.date)<day(a.date)||day(n.date)>day(b.date))throw Error('The note date must fall within its segment.');}}
  return doc;
}
export function mainMilestoneIDs(doc){return new Set([...doc.projects.map(p=>p.route[0]),...doc.edges.flatMap(e=>[e.from,e.to])]);}
export function orderedMilestones(doc,project){
 const nodes=doc.anchors.filter(a=>a.project===project.id),byID=new Map(nodes.map(a=>[a.id,a])),incoming=new Map(nodes.map(a=>[a.id,0])),outgoing=new Map(nodes.map(a=>[a.id,[]]));
 for(const e of doc.edges.filter(e=>e.project===project.id)){if(!byID.has(e.from)||!byID.has(e.to))throw Error('Invalid timeline segment.');incoming.set(e.to,incoming.get(e.to)+1);outgoing.get(e.from).push(e.to);}
 const ready=nodes.filter(a=>!incoming.get(a.id)),result=[];while(ready.length){ready.sort((a,b)=>a.date.localeCompare(b.date));const node=ready.shift();result.push(node);for(const id of outgoing.get(node.id)){incoming.set(id,incoming.get(id)-1);if(!incoming.get(id))ready.push(byID.get(id));}}
 if(result.length!==nodes.length)throw Error('Milestone links contain a cycle.');return result;
}
export function normalizeTimeline(doc){
 for(const edge of doc.edges){edge.state='active';delete edge.revision;}
 const connected=mainMilestoneIDs(doc);for(const p of doc.projects){const start=p.route[0];p.route=[start,...orderedMilestones(doc,p).filter(a=>a.id!==start&&connected.has(a.id)).map(a=>a.id)];}doc.connectionDriven=true;return doc;
}
export const flatNote=name=>typeof name==='string'&&name.endsWith('.md')&&!/[\/\\\0]/.test(name)&&!name.startsWith('.');
export function noteText(meta,body=''){return '---\n'+stringify(meta)+'---\n\n'+body;}
export function readNote(text){const match=String(text??'').match(/^\uFEFF?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);let meta={};if(match)meta=parse(match[1],{maxAliasCount:20})??{};return {meta,body:match?text.slice(match[0].length).replace(/^\r?\n/,''):String(text??'')};}
export function updateNote(text,{title,date,body}){
  let source=text;const {meta}=readNote(source);day(date);
  for(const [name,value,type] of [['title',title,'text'],['date',date,'date']]){
    if(meta[name]!==value)source=editFrontmatter(source,name,{value,type,add:!Object.hasOwn(meta,name)});
  }
  const match=source.match(/^\uFEFF?---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/);if(!match)throw Error('A note needs dated frontmatter.');
  const newline=source.includes('\r\n')?'\r\n':'\n';return match[0]+newline+body.replace(/\r?\n/g,newline);
}
function anchor(project,title,date,priority,kind='milestone'){day(date);if(!title.trim()||!Number.isInteger(priority)||priority<1)throw Error('Enter a title and a positive priority.');const id=uid();return {id,project,title:title.trim(),date,priority,kind,note:id+'.md'};}
function edge(project,from,to,state='active'){return {id:uid(),project,from,to,state};}
export function createProject(doc,{title,date,priority,milestones},occupied=[]){
  const next=structuredClone(doc),id=uid(),start=anchor(id,title,date,priority,'start');
  const anchors=[start,...milestones.map(m=>anchor(id,m.title,m.date,m.priority??priority))];
  const used=[...occupied,...doc.anchors.map(a=>a.note),...doc.notes.filter(n=>!n.device).map(n=>n.note)];for(const a of anchors){a.note=noteName(a.kind==='start'?a.title:start.title+'-'+a.title,used);if(a.kind==='start')a.title=a.note.slice(0,-3);used.push(a.note);}
  for(let i=1;i<anchors.length;i++)if(day(anchors[i].date)<day(anchors[i-1].date))throw Error('Milestones must be in date order.');
  next.projects.push({id,title:start.title,color:['#476fa8','#9d6b48','#6b8d63','#9575aa','#b77582'][next.projects.length%5],route:anchors.map(a=>a.id)});next.anchors.push(...anchors);
  for(let i=1;i<anchors.length;i++)next.edges.push(edge(id,anchors[i-1].id,anchors[i].id));
  const writes=anchors.map(a=>({name:a.note,text:noteText({title:a.title,date:a.date,priority:a.priority,kind:a.kind,crowmap:doc.id,project:id,...(a===start?{milestones:anchors.slice(1).map(m=>({id:m.id,title:m.title,date:m.date,priority:m.priority}))}:{})})}));
  return {doc:validateMap(next),writes};
}
export function revisePlan(doc,{project:projectID,from:fromID,rejoin:rejoinID,date,title,priority,milestones,body=''},occupied=[]){
  const next=structuredClone(doc),p=next.projects.find(p=>p.id===projectID);if(!p)throw Error('Project no longer exists.');
  const fromIndex=p.route.indexOf(fromID),joinIndex=rejoinID?p.route.indexOf(rejoinID):p.route.length;
  if(fromIndex<0||joinIndex<=fromIndex)throw Error('Choose a later milestone to rejoin.');
  const byID=new Map(next.anchors.map(a=>[a.id,a])),from=byID.get(fromID),firstNext=byID.get(p.route[fromIndex+1]);
  if(day(date)<day(from.date)||firstNext&&day(date)>day(firstNext.date))throw Error('The change date must fall in the selected segment.');
  const revision=anchor(p.id,title||'Plan changed',date,priority,'revision'),replacement=milestones.map(m=>anchor(p.id,m.title,m.date,m.priority??priority));
  const used=[...occupied,...doc.anchors.map(a=>a.note),...doc.notes.filter(n=>!n.device).map(n=>n.note)];for(const a of [revision,...replacement]){a.note=noteName(p.title+'-'+a.title,used);used.push(a.note);}
  const added=[revision,...replacement],join=rejoinID?byID.get(rejoinID):null;
  const sequence=[from,...added,...(join?[join]:[])];
  for(let i=1;i<sequence.length;i++)if(day(sequence[i].date)<day(sequence[i-1].date))throw Error('Replacement milestones must fit before the rejoin milestone.');
  const oldRoute=p.route.slice(fromIndex,joinIndex+1);
  for(let i=1;i<sequence.length;i++)next.edges.push(edge(p.id,sequence[i-1].id,sequence[i].id));
  next.anchors.push(...added);p.route=[...p.route.slice(0,fromIndex+1),...added.map(a=>a.id),...p.route.slice(joinIndex)];
  const writes=added.map(a=>({name:a.note,text:noteText({title:a.title,date:a.date,priority:a.priority,kind:a.kind,crowmap:doc.id,project:p.id,...(a===revision?{replaces:oldRoute.slice(1,join? -1:undefined),rejoin:rejoinID||null,milestones:replacement.map(m=>({id:m.id,title:m.title,date:m.date,priority:m.priority}))}:{})},a===revision?body:'')}));
  return {doc:validateMap(normalizeTimeline(next)),writes};
}
export function addNote(doc,{title,date,body,attach,device=null,note=null,cachedText=null},occupied=[]){
  if(device&&note){const existing=doc.notes.find(n=>n.device===device&&n.note===note);if(existing)return {doc:structuredClone(doc),writes:[]};}
  const next=structuredClone(doc),id=uid(),name=note||noteName(title,[...occupied,...doc.anchors.map(a=>a.note),...doc.notes.filter(n=>!n.device).map(n=>n.note)]);day(date);if(!title.trim())throw Error('Enter a note title.');
  const n={id,title:title.trim(),date,note:name,attach,...(device?{device,cachedText}:{} )};next.notes.push(n);
  return {doc:validateMap(next),writes:device?[]:[{name,text:noteText({title:n.title,date,crowmap:doc.id,attach},body)}]};
}
function milestonePath(doc,project,from,to){
 const queue=[[from]],seen=new Set();while(queue.length){const path=queue.shift(),last=path.at(-1);if(last===to)return path;if(seen.has(last))continue;seen.add(last);for(const e of doc.edges.filter(e=>e.project===project&&e.from===last))queue.push([...path,e.to]);}return null;
}
export function addMilestone(doc,fromID,occupied=[]){
 const next=structuredClone(doc),from=next.anchors.find(a=>a.id===fromID);if(!from)throw Error('Milestone no longer exists.');const project=next.projects.find(p=>p.id===from.project);
 const successor=next.edges.find(e=>e.from===fromID),end=next.anchors.find(a=>a.id===successor?.to),date=new Date((end?Math.floor((day(from.date)+day(end.date))/2):day(from.date)+7)*DAY).toISOString().slice(0,10),added=anchor(project.id,'New milestone',date,from.priority);
 added.note=noteName(project.title+'-'+added.title,[...occupied,...next.anchors.map(a=>a.note),...next.notes.filter(n=>!n.device).map(n=>n.note)]);next.anchors.push(added);next.edges.push(edge(project.id,fromID,added.id));normalizeTimeline(next);
 return {doc:validateMap(next),writes:[{name:added.note,text:noteText({title:added.title,date,priority:added.priority,kind:'milestone'})}]};
}
export function connectMilestones(doc,fromID,toID){
 const next=structuredClone(doc),from=next.anchors.find(a=>a.id===fromID),to=next.anchors.find(a=>a.id===toID);if(!from||!to)throw Error('Milestone no longer exists.');if(fromID===toID||from.project!==to.project)throw Error('Connect two different milestones in the same timeline.');if(day(from.date)>day(to.date))throw Error('Connect toward a milestone on the same or a later date.');if(milestonePath(next,from.project,toID,fromID))throw Error('This connection would create a milestone cycle.');
 const project=next.projects.find(p=>p.id===from.project);

 if(!next.edges.some(e=>e.from===fromID&&e.to===toID))next.edges.push(edge(project.id,fromID,toID));normalizeTimeline(next);return {doc:validateMap(next),writes:[]};
}
export function disconnectMilestones(doc,edgeID){
 const next=structuredClone(doc),removed=next.edges.find(e=>e.id===edgeID);if(!removed)throw Error('Connection no longer exists.');next.edges=next.edges.filter(e=>e.id!==edgeID);
 for(const note of next.notes)if(note.attach.kind==='edge'&&note.attach.id===edgeID)note.attach={kind:'anchor',id:removed.from};
 for(const device of next.devices)if(device.attachments)device.attachments=device.attachments.map(a=>a.kind==='edge'&&a.id===edgeID?{kind:'anchor',id:removed.from}:a);
 return {doc:validateMap(normalizeTimeline(next)),writes:[]};
}
export function linkLeaves(noteID,text){
  const {body}=readNote(text);const clean=body.replace(/```[\s\S]*?```|~~~[\s\S]*?~~~|`[^`]*`/g,'');const out=[];
  const re=/!?\[\[([^\n]+?)\]\]|!?\[([^\]\n]*)\]\(([^\s)]+)\)|\bhttps?:\/\/[^\s<>\])]+/g;
  for(const m of clean.matchAll(re)){const [target,alias]=(m[1]??'').split('|');const url=m[1]?target:m[3]??m[0];if(/^[a-z][a-z0-9+.-]*:/i.test(url)&&! /^(https?:|mailto:|file:)/i.test(url))continue;out.push({id:noteID+':link:'+m.index,owner:noteID,url,label:m[1]?alias||target:m[2]||url});}
  return out;
}
export function milestoneDisplayOrder(doc,project){
 const nodes=orderedMilestones(doc,project),fallback=new Map(nodes.map((n,i)=>[n.id,i])),orders=doc.view?.milestoneOrder??{};
 return nodes.sort((a,b)=>{const date=a.date.localeCompare(b.date);if(date)return date;const order=orders[project.id+':'+a.date];if(!Array.isArray(order))return fallback.get(a.id)-fallback.get(b.id);const rank=n=>{const i=order.indexOf(n.id);return i<0?order.length+fallback.get(n.id):i;};return rank(a)-rank(b);});
}
export function reorderMilestones(source,id,targetID){
 const doc=structuredClone(source),a=doc.anchors.find(n=>n.id===id),b=doc.anchors.find(n=>n.id===targetID),main=mainMilestoneIDs(doc);
 if(!a||!b||a.id===b.id||a.kind==='start'||b.kind==='start'||a.project!==b.project||a.date!==b.date||main.has(a.id)!==main.has(b.id))throw Error('Reorder milestones on the same date in the same timeline.');
 const nodes=milestoneDisplayOrder(doc,doc.projects.find(p=>p.id===a.project)).filter(n=>n.date===a.date),order=nodes.map(n=>n.id),i=order.indexOf(id),j=order.indexOf(targetID);[order[i],order[j]]=[order[j],order[i]];
 doc.view={...doc.view,milestoneOrder:{...doc.view?.milestoneOrder,[a.project+':'+a.date]:order}};
 return {doc,writes:[]};
}
export function layoutMap(doc,{dateWidths={}}={}){
  validateMap(doc);const all=[...doc.anchors,...doc.notes];const start=Math.min(...all.map(n=>day(n.date)),day(today())),end=Math.max(...all.map(n=>day(n.date)),start+14);const scale=Math.min(44,Math.max(4,1400/Math.max(14,end-start)));
  const widths=Object.entries(dateWidths).flatMap(([date,width])=>{try{const d=day(date);return Number.isFinite(width)&&width>0&&d>=start&&d<end?[[d,width]]:[];}catch{return [];}}).sort((a,b)=>a[0]-b[0]);
  const xAtDay=value=>100+(value-start)*scale+widths.reduce((extra,[d,width])=>extra+(width-scale)*Math.min(1,Math.max(0,value-d)),0);
  const x=date=>xAtDay(day(date)),dateAt=position=>{let extra=0,value;for(const [d,width]of widths){const left=100+(d-start)*scale+extra;if(position<left){value=start+(position-100-extra)/scale;break;}if(position<=left+width){value=d+(position-left)/width;break;}extra+=width-scale;}value??=start+(position-100-extra)/scale;return new Date(Math.round(value)*DAY).toISOString().slice(0,10);};
  const dateBounds=date=>({left:xAtDay(day(date)-.5),right:xAtDay(day(date)+.5)});const active=mainMilestoneIDs(doc);
  const anchorByID=new Map(doc.anchors.map(a=>[a.id,a])),ghostLanes=new Map();let laneCount=0;
  for(const project of doc.projects){let lane=0;for(const a of milestoneDisplayOrder(doc,project).filter(a=>!active.has(a.id)))ghostLanes.set(a.id,++lane);laneCount=Math.max(laneCount,lane);}
  const laneGap=56;let projectGap=250;const priorityY=priority=>100+(priority-1)*projectGap,priorityAt=y=>Math.max(1,Math.min(doc.projects.length,Math.round((y-100)/projectGap)+1));
  const events=doc.anchors.filter(a=>active.has(a.id)).sort((a,b)=>day(a.date)-day(b.date)||doc.projects.findIndex(p=>p.id===a.project)-doc.projects.findIndex(p=>p.id===b.project));
  let order=[];const ranks=[],priorities=new Map();
  for(const event of events){if(priorities.get(event.project)===event.priority)continue;priorities.set(event.project,event.priority);const index=order.indexOf(event.project);if(index>=0)order.splice(index,1);order.splice(Math.min(event.priority-1,order.length),0,event.project);ranks.push({date:event.date,order:[...order]});}
  function rank(project,date){const r=ranks.filter(r=>day(r.date)<=day(date)).at(-1);return Math.max(0,r?.order.indexOf(project)??0);}
  // Dates and priorities are data, not unique visual positions. Stack colliding milestones
  // (including parallel branches on one date) without changing either property.
  const mainLanes=new Map(),occupied=new Map();let mainLaneCount=0;
  for(const project of doc.projects)for(const node of milestoneDisplayOrder(doc,project).filter(a=>active.has(a.id))){const id=node.id,a=anchorByID.get(id),key=project.id+':'+rank(project.id,a.date),lanes=occupied.get(key)??[];
    const left=x(a.date)-14,right=x(a.date)+24+[...a.title].reduce((width,c)=>width+(c.codePointAt(0)>0x2e80?12:7),0);
    let lane=lanes.findIndex(ranges=>ranges.every(([l,r])=>right<l||left>r));if(lane<0){lane=lanes.length;lanes.push([]);}lanes[lane].push([left,right]);occupied.set(key,lanes);mainLanes.set(id,lane);mainLaneCount=Math.max(mainLaneCount,lane);
  }
  projectGap=Math.max(250,(mainLaneCount+laneCount)*laneGap+150);
  const points=new Map(doc.anchors.map(a=>[a.id,{x:x(a.date),y:priorityY(active.has(a.id)?rank(a.project,a.date)+1:a.priority)+(active.has(a.id)?mainLanes.get(a.id)??0:mainLaneCount+(ghostLanes.get(a.id)??1))*laneGap,...a}]));
  const edgePoints=new Map(doc.edges.map(e=>{const a=points.get(e.from),b=points.get(e.to),offset=0;
    const inner=[...new Set(ranks.map(r=>r.date))].filter(d=>day(d)>day(a.date)&&day(d)<day(b.date)).map(d=>({x:x(d),y:priorityY(rank(e.project,d)+1)+offset}));
    inner.sort((p,q)=>p.x-q.x);return [e.id,[a,...inner,b]];
  }));
  const notePoints=new Map(),devices=new Map(),slots=new Map();
  for(const n of [...doc.notes].sort((a,b)=>day(a.date)-day(b.date))){const a=n.attach.kind==='anchor'?points.get(n.attach.id):points.get(doc.edges.find(e=>e.id===n.attach.id).from);const edgeLine=edgePoints.get(n.attach.id);let y=a.y;
    if(edgeLine){const nx=x(n.date),i=Math.max(0,edgeLine.findIndex((p,i)=>i<edgeLine.length-1&&p.x<=nx&&edgeLine[i+1].x>=nx));const p=edgeLine[i],q=edgeLine[i+1]??p;y=timelineCurveY(p,q,nx);}
    const key=n.attach.id+':'+(n.device??'local'),slotKey=key+':'+Math.floor(x(n.date)/180),slot=slots.get(slotKey)??0;slots.set(slotKey,slot+1);const nx=x(n.date),ny=y+70+slot*48;
    if(n.device&&!devices.has(key))devices.set(key,{key,device:n.device,x:nx,y:y+42,origin:{x:nx,y},attach:n.attach});
    notePoints.set(n.id,{...n,x:nx,y:ny+(n.device?38:0),origin:n.device?devices.get(key):{x:nx,y}});
  }
  return {points,edgePoints,notePoints,devices,width:Math.max(1100,x(new Date(end*DAY).toISOString().slice(0,10))+240),height:Math.max(600,doc.projects.length*projectGap+180,...[...points.values()].map(n=>n.y+100),...[...notePoints.values()].map(n=>n.y+160)),start,end,scale,x,dateAt,dateBounds,priorityY,priorityAt,rankAt:(project,date)=>rank(project,date)+1};
}
export function timelineCurveY(a,b,x){
  if(a.x===b.x)return a.y;const fraction=Math.min(1,Math.max(0,(x-a.x)/(b.x-a.x)));let low=0,high=1;
  for(let i=0;i<24;i++){const t=(low+high)/2,at=1.5*t-1.5*t*t+t*t*t;if(at<fraction)low=t;else high=t;}
  const t=(low+high)/2;return a.y+(b.y-a.y)*(3*t*t-2*t*t*t);
}
