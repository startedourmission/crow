import {parse, stringify} from 'yaml';
import {noteName} from './crowmap-links.js';
import {editFrontmatter} from './frontmatter-model.js';
const DAY=86400000,MONTHS=['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
export const DATE_UNITS=['day','week','month','year'],UNIT_WIDTH=56,PRIORITY_GAP=80,PRIORITY_GAP_MIN=28,PRIORITY_GAP_MAX=400,NOTE_TENSION=10,NOTE_TENSION_MIN=0,NOTE_TENSION_MAX=60;
export function clampNoteTension(value){const n=Math.round(Number(value));return Number.isFinite(n)?Math.max(NOTE_TENSION_MIN,Math.min(NOTE_TENSION_MAX,n)):NOTE_TENSION;}
export function noteOrbitRadius(count,tension){const t=clampNoteTension(tension);return t>0&&count>0?t:0;}
export const TIMELINE_COLORS=['#476fa8','#9d6b48','#6b8d63','#9575aa','#b77582','#3f8a86','#c08a3e','#5d7394'];
export function setProjectColor(doc,projectID,color){
 if(!/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(color))throw Error('Choose a color.');
 const next=structuredClone(doc),project=next.projects.find(p=>p.id===projectID);if(!project)throw Error('Project no longer exists.');
 project.color=color.length===4?'#'+[...color.slice(1)].map(c=>c+c).join(''):color.toLowerCase();
 return {doc:validateMap(next),writes:[]};
}
export function clampPriorityGap(value){const n=Math.round(Number(value));return Number.isFinite(n)?Math.max(PRIORITY_GAP_MIN,Math.min(PRIORITY_GAP_MAX,n)):PRIORITY_GAP;}
export function dateLabelStride(zoom,minPx=54){return Math.max(1,Math.ceil(minPx/(UNIT_WIDTH*Math.max(0.01,Number(zoom)||1))));}
export function mapCamera(scrollLeft,scrollTop,zoom,vw,vh){
 const z=Math.max(0.01,Number(zoom)||1),x=scrollLeft/z,w=Math.max(1,vw)/z;
 return {x,y:scrollTop/z,w,h:Math.max(1,vh)/z,date:{x,y:0,w,h:32/z}};
}
export const uid=()=>Array.from(crypto.getRandomValues(new Uint8Array(16)),byte=>byte.toString(16).padStart(2,'0')).join('');
export function day(value){if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(value)||new Date(value+'T00:00:00Z').toISOString().slice(0,10)!==value)throw Error('Choose a valid date.');return Date.parse(value+'T00:00:00Z')/DAY;}
export const today=()=>new Date().toLocaleDateString('en-CA');
const utc=d=>new Date(d*DAY),iso=d=>utc(d).toISOString().slice(0,10);
function unitOrigin(d,unit){const t=utc(d);if(unit==='week')return d-((t.getUTCDay()+6)%7);if(unit==='month')return Date.UTC(t.getUTCFullYear(),t.getUTCMonth(),1)/DAY;if(unit==='year')return Date.UTC(t.getUTCFullYear(),0,1)/DAY;return d;}
function nextUnit(d,unit){const origin=unitOrigin(d,unit),t=utc(origin);let next=origin+1;if(unit==='week')next=origin+7;else if(unit==='month')next=Date.UTC(t.getUTCFullYear(),t.getUTCMonth()+1,1)/DAY;else if(unit==='year')next=Date.UTC(t.getUTCFullYear()+1,0,1)/DAY;return Number.isFinite(next)&&next>origin?next:origin+1;}
function unitIndex(d,unit){const t=utc(d);if(unit==='week')return unitOrigin(d,'week')/7;if(unit==='month')return t.getUTCFullYear()*12+t.getUTCMonth();if(unit==='year')return t.getUTCFullYear();return d;}
function unitProgress(d,unit){const origin=unitOrigin(d,unit),span=nextUnit(origin,unit)-origin;return span? (d-origin)/span:0;}
function tickLabel(d,unit){const t=utc(d);if(unit==='month')return MONTHS[t.getUTCMonth()];if(unit==='year')return String(t.getUTCFullYear());return String(t.getUTCMonth()+1).padStart(2,'0')+'/'+String(t.getUTCDate()).padStart(2,'0');}
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
export function readNote(text){
  const match=String(text??'').match(/^\uFEFF?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);let meta={};
  if(match)meta=parse(match[1],{maxAliasCount:20})??{};
  if(meta&&typeof meta==='object'){
    if(meta.date instanceof Date&&Number.isFinite(+meta.date))meta.date=new Date(+meta.date).toISOString().slice(0,10);
    const priority=Number(meta.priority);
    if(meta.priority!=null&&meta.priority!==''&&Number.isInteger(priority)&&priority>=1)meta.priority=priority;
  }
  return {meta,body:match?text.slice(match[0].length).replace(/^\r?\n/,''):String(text??'')};
}
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
  next.projects.push({id,title:start.title,color:TIMELINE_COLORS[next.projects.length%TIMELINE_COLORS.length],route:anchors.map(a=>a.id)});next.anchors.push(...anchors);
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
export function addMilestone(doc,fromID,occupied=[],options={}){
 const next=structuredClone(doc),from=next.anchors.find(a=>a.id===fromID);if(!from)throw Error('Milestone no longer exists.');const project=next.projects.find(p=>p.id===from.project);
 const segment=options.edgeID?next.edges.find(e=>e.id===options.edgeID&&e.from===fromID):null;
 const end=segment?next.anchors.find(a=>a.id===segment.to):next.anchors.find(a=>a.id===next.edges.find(e=>e.from===fromID)?.to);
 let date=options.date||(end?new Date(Math.floor((day(from.date)+day(end.date))/2)*DAY).toISOString().slice(0,10):new Date((day(from.date)+7)*DAY).toISOString().slice(0,10));
 if(end){const lo=day(from.date),hi=day(end.date);date=new Date(Math.min(hi,Math.max(lo,day(date)))*DAY).toISOString().slice(0,10);}
 const added=anchor(project.id,'New milestone',date,from.priority);
 added.note=noteName(project.title+'-'+added.title,[...occupied,...next.anchors.map(a=>a.note),...next.notes.filter(n=>!n.device).map(n=>n.note)]);next.anchors.push(added);
 if(segment){
  const oldTo=segment.to,neu=edge(project.id,added.id,oldTo);next.edges.push(neu);segment.to=added.id;
  for(const n of next.notes)if(n.attach.kind==='edge'&&n.attach.id===segment.id&&day(n.date)>=day(date))n.attach={kind:'edge',id:neu.id};
 }else next.edges.push(edge(project.id,fromID,added.id));
 normalizeTimeline(next);
 return {doc:validateMap(next),writes:[{name:added.note,text:noteText({title:added.title,date,priority:added.priority,kind:'milestone'})}]};
}
export function connectMilestones(doc,fromID,toID){
 const next=structuredClone(doc),from=next.anchors.find(a=>a.id===fromID),to=next.anchors.find(a=>a.id===toID);if(!from||!to)throw Error('Milestone no longer exists.');if(fromID===toID||from.project!==to.project)throw Error('Connect two different milestones in the same timeline.');if(day(from.date)>day(to.date))throw Error('Connect toward a milestone on the same or a later date.');if(milestonePath(next,from.project,toID,fromID))throw Error('This connection would create a milestone cycle.');
 const project=next.projects.find(p=>p.id===from.project);

 if(!next.edges.some(e=>e.from===fromID&&e.to===toID))next.edges.push(edge(project.id,fromID,toID));normalizeTimeline(next);return {doc:validateMap(next),writes:[]};
}
export function removeMilestone(doc,id){
 const next=structuredClone(doc),node=next.anchors.find(a=>a.id===id);
 if(!node||node.kind==='start')throw Error('Select a milestone to delete.');
 const incoming=next.edges.filter(e=>e.to===id),outgoing=next.edges.filter(e=>e.from===id);
 const fromIDs=[...new Set(incoming.map(e=>e.from))],toIDs=[...new Set(outgoing.map(e=>e.to))];
 const incident=new Set([...incoming,...outgoing].map(e=>e.id));
 const existing=new Set(next.edges.filter(e=>e.from!==id&&e.to!==id).map(e=>e.from+'>'+e.to));
 const byID=new Map(next.anchors.map(a=>[a.id,a]));
 for(const from of fromIDs)for(const to of toIDs){
  if(from===to||existing.has(from+'>'+to))continue;
  const a=byID.get(from),b=byID.get(to);if(!a||!b||a.project!==node.project||b.project!==node.project||b.kind==='start'||day(a.date)>day(b.date))continue;
  next.edges.push(edge(node.project,from,to));existing.add(from+'>'+to);
 }
 const remap=attach=>{
  if(attach?.kind==='anchor'&&attach.id===id){const fallback=fromIDs[0]??toIDs[0];return fallback?{kind:'anchor',id:fallback}:attach;}
  if(attach?.kind==='edge'&&incident.has(attach.id)){
   const old=incoming.find(e=>e.id===attach.id)??outgoing.find(e=>e.id===attach.id);
   const from=old.from===id?fromIDs[0]:old.from,to=old.to===id?toIDs[0]:old.to;
   const neu=from&&to&&from!==to?next.edges.find(e=>e.from===from&&e.to===to):null;
   if(neu)return {kind:'edge',id:neu.id};
   const fallback=fromIDs[0]??toIDs[0];return fallback?{kind:'anchor',id:fallback}:attach;
  }
  return attach;
 };
 for(const note of next.notes){
  note.attach=remap(note.attach);
  if(note.attach.kind==='edge'){const e=next.edges.find(x=>x.id===note.attach.id),a=byID.get(e?.from),b=byID.get(e?.to);
   if(a&&b){if(day(note.date)<day(a.date))note.date=a.date;if(day(note.date)>day(b.date))note.date=b.date;}}
 }
 for(const device of next.devices)if(device.attachments)device.attachments=device.attachments.map(remap);
 next.edges=next.edges.filter(e=>e.from!==id&&e.to!==id);
 next.anchors=next.anchors.filter(a=>a.id!==id);
 if(next.view?.milestoneOrder)next.view={...next.view,milestoneOrder:Object.fromEntries(Object.entries(next.view.milestoneOrder).map(([key,value])=>[key,Array.isArray(value)?value.filter(item=>item!==id):value]))};
 return {doc:validateMap(normalizeTimeline(next)),writes:[]};
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
 const swap=value=>value===id?targetID:value===targetID?id:value;
 for(const e of doc.edges){e.from=swap(e.from);e.to=swap(e.to);if(e.from===e.to)throw Error('Those milestones cannot swap order.');}
 const keep=new Map(),remap=new Map(),edges=[];
 for(const e of doc.edges){const key=e.from+'>'+e.to;if(keep.has(key))remap.set(e.id,keep.get(key));else{keep.set(key,e.id);edges.push(e);}}
 doc.edges=edges;
 for(const n of doc.notes)if(n.attach.kind==='edge'&&remap.has(n.attach.id))n.attach={kind:'edge',id:remap.get(n.attach.id)};
 for(const device of doc.devices)if(device.attachments)device.attachments=device.attachments.map(item=>item.kind==='edge'&&remap.has(item.id)?{kind:'edge',id:remap.get(item.id)}:item);
 if(doc.view?.milestoneOrder){const key=a.project+':'+a.date,{[key]:_,...rest}=doc.view.milestoneOrder;doc.view={...doc.view,milestoneOrder:rest};}
 return {doc:validateMap(normalizeTimeline(doc)),writes:[]};
}
function noteSeed(id){let hash=2166136261;for(const c of id)hash=Math.imul(hash^c.charCodeAt(0),16777619);return (hash>>>0)/4294967296;}
export function layoutMap(doc,{unit='day',priorityGap=PRIORITY_GAP,noteTension=NOTE_TENSION}={}){
  validateMap(doc);const scaleUnit=DATE_UNITS.includes(unit)?unit:'day',all=[...doc.anchors,...doc.notes];
  const rawStart=Math.min(...all.map(n=>day(n.date)),day(today())),rawEnd=Math.max(...all.map(n=>day(n.date)),rawStart+14);
  const start=unitOrigin(rawStart,scaleUnit);let end=unitOrigin(rawEnd,scaleUnit);if(end<=rawEnd)end=nextUnit(end,scaleUnit);if(end<=start)end=nextUnit(start,scaleUnit);
  const origin=unitIndex(start,scaleUnit);
  const scale=UNIT_WIDTH;
  const xAtDay=value=>100+(unitIndex(value,scaleUnit)+unitProgress(value,scaleUnit)-origin)*scale;
  const x=date=>xAtDay(day(date));
  const dateAt=position=>{
    const t=(position-100)/scale+origin;let d;
    if(scaleUnit==='day')d=Math.round(t);
    else if(scaleUnit==='week')d=Math.round(t*7);
    else if(scaleUnit==='month'){const idx=Math.floor(t),frac=t-idx,year=Math.floor(idx/12),month=((idx%12)+12)%12,first=Date.UTC(year,month,1)/DAY,days=nextUnit(first,'month')-first;d=first+Math.min(days-1,Math.max(0,Math.round(frac*days)));}
    else {const year=Math.floor(t),frac=t-year,first=Date.UTC(year,0,1)/DAY,days=nextUnit(first,'year')-first;d=first+Math.min(days-1,Math.max(0,Math.round(frac*days)));}
    return iso(d);
  };
  const dateBounds=date=>{const originDay=unitOrigin(day(date),scaleUnit);return {left:xAtDay(originDay),right:xAtDay(nextUnit(originDay,scaleUnit))};};
  const tickCount=Math.min(20000,Math.max(1,Math.round(unitIndex(end,scaleUnit)-unitIndex(start,scaleUnit))+1));
  const tickAt=i=>{
    const t=utc(start);let d=start;
    if(scaleUnit==='week')d=start+i*7;
    else if(scaleUnit==='month')d=Date.UTC(t.getUTCFullYear(),t.getUTCMonth()+i,1)/DAY;
    else if(scaleUnit==='year')d=Date.UTC(t.getUTCFullYear()+i,0,1)/DAY;
    else d=start+i;
    return {date:iso(d),x:xAtDay(d),label:tickLabel(d,scaleUnit)};
  };
  const active=mainMilestoneIDs(doc);
  const anchorByID=new Map(doc.anchors.map(a=>[a.id,a])),ghostLanes=new Map();let laneCount=0;
  // Each same-priority branch is its own lane for the whole segment, not a stroke
  // that shares the parent line until the destination node.
  const branchLane=new Map();
  for(const project of doc.projects){
    const outs=new Map();
    for(const e of doc.edges.filter(e=>e.project===project.id)){const list=outs.get(e.from)??[];list.push(e);outs.set(e.from,list);}
    const nodes=orderedMilestones(doc,project);
    if(!nodes.length)continue;
    branchLane.set(nodes[0].id,0);
    let spare=0;
    for(const node of nodes){
      const fromLane=branchLane.get(node.id)??0;
      if(!branchLane.has(node.id))branchLane.set(node.id,fromLane);
      const targets=(outs.get(node.id)??[]).slice().sort((a,b)=>anchorByID.get(a.to).date.localeCompare(anchorByID.get(b.to).date)||a.id.localeCompare(b.id));
      const same=targets.filter(e=>anchorByID.get(e.to).priority===node.priority);
      const primary=same.reduce((best,e)=>!best||anchorByID.get(e.to).date>anchorByID.get(best.to).date?e:best,null);
      for(const e of same){
        const id=e.to;
        if(e===primary){if(!branchLane.has(id))branchLane.set(id,fromLane);}
        else if(!branchLane.has(id))branchLane.set(id,++spare);
      }
      for(const e of targets)if(anchorByID.get(e.to).priority!==node.priority&&!branchLane.has(e.to))branchLane.set(e.to,0);
    }
  }
  for(const project of doc.projects){let lane=0;for(const a of milestoneDisplayOrder(doc,project).filter(a=>!active.has(a.id)))ghostLanes.set(a.id,++lane);laneCount=Math.max(laneCount,lane);}
  const laneGap=56,minProjectGap=clampPriorityGap(priorityGap),stackStride=96,topPad=200;let projectGap=minProjectGap;
  const events=doc.anchors.filter(a=>active.has(a.id)).sort((a,b)=>day(a.date)-day(b.date)||doc.projects.findIndex(p=>p.id===a.project)-doc.projects.findIndex(p=>p.id===b.project));
  const ranks=[],priorities=new Map(),claimed=new Map();
  for(const event of events){if(priorities.get(event.project)===event.priority)continue;priorities.set(event.project,event.priority);claimed.set(event.project,event.date);ranks.push({date:event.date,priorities:new Map(priorities),claimed:new Map(claimed)});}
  function snapshot(date){return ranks.filter(r=>day(r.date)<=day(date)).at(-1);}
  function rank(project,date){return Math.max(0,(snapshot(date)?.priorities.get(project)??1)-1);}
  const claimedAt=new Map();
  for(const a of doc.anchors.filter(n=>active.has(n.id))){
    const key=a.project+':'+a.priority,prev=claimedAt.get(key);
    if(!prev||a.date<prev)claimedAt.set(key,a.date);
  }
  const byPriority=new Map();
  for(const [key,first] of claimedAt){
    const sep=key.lastIndexOf(':'),id=key.slice(0,sep),priority=Number(key.slice(sep+1));
    const list=byPriority.get(priority)??[];list.push({id,first});byPriority.set(priority,list);
  }
  const mainLanes=new Map(),occupied=new Map();let mainLaneCount=0;
  for(const project of doc.projects)for(const node of milestoneDisplayOrder(doc,project).filter(a=>active.has(a.id))){const id=node.id,a=anchorByID.get(id),key=project.id+':'+a.priority+':'+(branchLane.get(id)??0),lanes=occupied.get(key)??[];
    const left=x(a.date)-14,right=x(a.date)+24+[...a.title].reduce((width,c)=>width+(c.codePointAt(0)>0x2e80?12:7),0);
    let lane=lanes.findIndex(ranges=>ranges.every(([l,r])=>right<l||left>r));if(lane<0){lane=lanes.length;lanes.push([]);}lanes[lane].push([left,right]);occupied.set(key,lanes);mainLanes.set(id,lane);mainLaneCount=Math.max(mainLaneCount,lane);
  }
  const spanAt=new Map();
  for(const a of doc.anchors.filter(n=>active.has(n.id))){
    const key=a.project+':'+a.priority,need=(branchLane.get(a.id)??0)+(mainLanes.get(a.id)??0)+1;
    spanAt.set(key,Math.max(spanAt.get(key)??1,need));
  }
  const startRow=new Map();
  for(const [priority,list] of byPriority){
    list.sort((a,b)=>b.first.localeCompare(a.first)||doc.projects.findIndex(p=>p.id===a.id)-doc.projects.findIndex(p=>p.id===b.id));
    let row=0;
    for(const item of list){startRow.set(item.id+':'+priority,row);row+=spanAt.get(item.id+':'+priority)??1;}
  }
  function projectLane(project,priority){return startRow.get(project+':'+priority)??0;}
  const extraByPriority=new Map();
  for(const [priority,list] of byPriority){
    let used=0;
    for(const item of list)used=Math.max(used,(startRow.get(item.id+':'+priority)??0)+(spanAt.get(item.id+':'+priority)??1));
    extraByPriority.set(priority,Math.max(0,used-1));
  }
  const bandHeight=p=>minProjectGap+(extraByPriority.get(p)||0)*stackStride;
  const priorityY=priority=>{let y=topPad;for(let p=1;p<priority;p++)y+=bandHeight(p);return y;};
  const priorityAt=y=>{let p=1,edge=topPad,maxP=Math.max(1,doc.projects.length);while(p<maxP){const next=edge+bandHeight(p);if(y<next)return p;edge=next;p++;}return maxP;};
  projectGap=minProjectGap;
  const spine=(project,priority)=>priorityY(priority)+projectLane(project,priority)*stackStride;
  const points=new Map(doc.anchors.map(a=>{
    const pri=a.priority;
    const y=priorityY(pri)+(active.has(a.id)?projectLane(a.project,pri)+(branchLane.get(a.id)??0)+(mainLanes.get(a.id)??0):mainLaneCount+(ghostLanes.get(a.id)??1))*stackStride;
    return [a.id,{x:x(a.date),y,...a}];
  }));
  const drop=Math.min(scale*.9,52);
  const rankDates=[...new Set(ranks.map(r=>r.date))].sort((p,q)=>day(p)-day(q));
  const fanAt=new Map();
  for(const e of doc.edges){
    const a=points.get(e.from),b=points.get(e.to);if(!a||!b||a.kind==='start')continue;
    if(rank(e.project,a.date)===rank(e.project,b.date))continue;
    const key=e.from+':'+b.date;const list=fanAt.get(key)??[];list.push(e);fanAt.set(key,list);
  }
  for(const list of fanAt.values())list.sort((p,q)=>points.get(p.to).y-points.get(q.to).y);
  const rawEdges=new Map(doc.edges.map(e=>{const a=points.get(e.from),b=points.get(e.to);
    if(a.kind==='start')return [e.id,[a,b]];
    const pts=[a];
    if(rank(e.project,a.date)===rank(e.project,b.date)){
      if(Math.abs(a.y-b.y)>=.5){
        const room=b.x-a.x,xEnter=Math.min(a.x+Math.min(drop,Math.max(18,room*.35)),b.x-2);
        if(room>8&&xEnter>a.x+1&&xEnter<b.x-1)pts.push({x:xEnter,y:b.y});
      }
      if(pts.at(-1)!==b)pts.push(b);
      return [e.id,pts];
    }
    let prevY=a.y,prevRank=rank(e.project,a.date);
    for(const d of rankDates){
      if(day(d)<=day(a.date)||day(d)>day(b.date))continue;
      const nextRank=rank(e.project,d);if(nextRank===prevRank)continue;
      const yNew=day(d)===day(b.date)?b.y:spine(e.project,nextRank+1);
      if(Math.abs(yNew-prevY)<.5){prevRank=nextRank;continue;}
      const bounds=dateBounds(d),atEnd=day(d)===day(b.date),room=b.x-pts.at(-1).x;
      const sib=fanAt.get(e.from+':'+b.date),slot=sib&&sib.length>1?sib.findIndex(item=>item.id===e.id):0;
      const spread=sib&&sib.length>1?Math.min(22,(bounds.right-bounds.left-12)/sib.length):0;
      if(atEnd){
        if(room>scale*.6){const xHold=b.x-Math.min(drop,room*.45)-slot*spread;if(xHold>pts.at(-1).x+1)pts.push({x:xHold,y:prevY});}
      }else{
        const xHold=Math.max(pts.at(-1).x+2,bounds.left),xDrop=Math.min(bounds.left+drop,bounds.right-2);
        if(xHold>pts.at(-1).x+1)pts.push({x:xHold,y:prevY});
        pts.push({x:Math.max(xHold+2,xDrop),y:yNew});
      }
      prevY=yNew;prevRank=nextRank;
    }
    if(Math.abs(prevY-b.y)>=.5){
      const room=b.x-pts.at(-1).x,sib=fanAt.get(e.from+':'+b.date),slot=sib&&sib.length>1?sib.findIndex(item=>item.id===e.id):0;
      const spread=sib&&sib.length>1?Math.min(22,drop/2):0;
      if(room>scale*.6){const xHold=b.x-Math.min(drop,room*.45)-slot*spread;if(xHold>pts.at(-1).x+1)pts.push({x:xHold,y:prevY});}
    }
    if(pts.at(-1)!==b)pts.push(b);return [e.id,pts];
  }));
  const edgePoints=rawEdges;
  const notePoints=new Map(),devices=new Map(),slots=new Map(),clusters=new Map();
  const tension=clampNoteTension(noteTension);
  for(const n of [...doc.notes].sort((a,b)=>day(a.date)-day(b.date)||a.id.localeCompare(b.id))){
    const edge=n.attach.kind==='edge'?doc.edges.find(e=>e.id===n.attach.id):null,a=n.attach.kind==='anchor'?points.get(n.attach.id):points.get(edge.from);
    const edgeLine=edgePoints.get(n.attach.id);let y=a.y;
    if(edgeLine){const nx=x(n.date),i=Math.max(0,edgeLine.findIndex((p,i)=>i<edgeLine.length-1&&p.x<=nx&&edgeLine[i+1].x>=nx));const p=edgeLine[i],q=edgeLine[i+1]??p;y=timelineCurveY(p,q,nx,points.get(edge?.from)?.kind==='start');}
    const ox=x(n.date);
    if(n.device){
      const key=n.attach.id+':'+n.device,slot=slots.get(key)??0;slots.set(key,slot+1);
      if(!devices.has(key))devices.set(key,{key,device:n.device,x:ox,y:y+42,origin:{x:ox,y},attach:n.attach});
      notePoints.set(n.id,{...n,x:ox,y:y+108+slot*48,origin:devices.get(key),orbit:0});
      continue;
    }
    const key=n.attach.kind+':'+n.attach.id+':'+n.date,ids=clusters.get(key)??[];ids.push(n.id);clusters.set(key,ids);
    notePoints.set(n.id,{...n,x:ox,y,origin:{x:ox,y},orbit:0});
  }
  for(const ids of clusters.values()){
    const count=ids.length,radius=noteOrbitRadius(count,tension);
    ids.forEach((id,i)=>{const note=notePoints.get(id),angle=-Math.PI/2+(count?i*2*Math.PI/count:0);note.orbit=radius;note.x=note.origin.x+radius*Math.cos(angle);note.y=note.origin.y+radius*Math.sin(angle);});
  }
  return {points,edgePoints,notePoints,devices,width:Math.max(1100,xAtDay(end)+240),height:Math.max(600,doc.projects.length*projectGap+topPad+80,...[...points.values()].map(n=>n.y+100),...[...notePoints.values()].map(n=>n.y+160)),start,end,scale,unit:scaleUnit,tickCount,tickAt,x,dateAt,dateBounds,priorityY,priorityAt,rankAt:(project,date)=>rank(project,date)+1};
}
export function timelineCurveY(a,b,x,straight=false){
  if(a.x===b.x)return a.y;const fraction=Math.min(1,Math.max(0,(x-a.x)/(b.x-a.x)));if(straight)return a.y+(b.y-a.y)*fraction;let low=0,high=1;
  for(let i=0;i<24;i++){const t=(low+high)/2,at=1.5*t-1.5*t*t+t*t*t;if(at<fraction)low=t;else high=t;}
  const t=(low+high)/2;return a.y+(b.y-a.y)*(3*t*t-2*t*t*t);
}
