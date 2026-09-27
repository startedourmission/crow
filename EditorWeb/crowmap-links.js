import {readNote,validateMap,uid,day,flatNote,linkLeaves,normalizeTimeline,TIMELINE_COLORS,removeMilestone} from './crowmap-model.js';
import {editFrontmatter,valueType} from './frontmatter-model.js';

export const noteLink = node => '[[' + (/^[0-9a-f-]{32,36}\.md$/i.test(node.note)?node.title:node.note.replace(/\.md$/, '')) + ']]';
const normalized = value => value.normalize('NFC').toLocaleLowerCase();
export function noteName(title, occupied) {
  const base = title.normalize('NFC').replace(/[\/\\\0#|:*?"<>]/g, ' ').replace(/\s+/g, ' ').replace(/^\.+/, '').trim().slice(0,100) || 'Untitled';
  const used = new Set(occupied.map(normalized));
  let name=base+'.md',i=2;while(used.has(normalized(name)))name=base+' '+i+++'.md';return name;
}
export function noteResolver(texts) {
  const index=new Map();
  const add=(key,name)=>{key=normalized(key);if(!index.has(key))index.set(key,new Set());index.get(key).add(name);};
  for(const [name,text] of Object.entries(texts)){add(name.replace(/\.md$/,''),name);let meta;try{meta=readNote(text).meta;}catch{continue;}if(typeof meta.title==='string')add(meta.title,name);for(const alias of Array.isArray(meta.aliases)?meta.aliases:[])if(typeof alias==='string')add(alias,name);}
  return link=>{if(typeof link!=='string'||!/^\[\[.+\]\]$/.test(link))throw Error('Use a note link such as [[Prototype]].');const target=link.slice(2,-2).split('|')[0].split('#')[0].replace(/\.md$/,'');const exact=Object.keys(texts).filter(n=>normalized(n.replace(/\.md$/,''))===normalized(target));const matches=exact.length?exact:[...(index.get(normalized(target))??[])];if(matches.length!==1)throw Error(matches.length?'Ambiguous note link: '+link:'Missing note: '+link);return matches[0];};
}
const links=(meta,key)=>{const value=meta[key]??[];if(!Array.isArray(value)||value.some(v=>typeof v!=='string'))throw Error(key+' must be a list of [[note links]].');return value;};
export function patch(source,values,remove=[]) {
  let meta=readNote(source).meta;
  for(const key of remove)if(Object.hasOwn(meta,key))source=editFrontmatter(source,key,{remove:true});
  for(const [key,value] of Object.entries(values))if(JSON.stringify(meta[key])!==JSON.stringify(value))source=editFrontmatter(source,key,{value,type:valueType(key,value),add:!Object.hasOwn(meta,key)});
  return source;
}

// The JSON graph is a display cache. Markdown links are the editable source of connections.
export function linkedTransaction(result,texts={}) {
  const doc=normalizeTimeline(structuredClone(result.doc)),byID=new Map(doc.anchors.map(a=>[a.id,a]));
  const sources={...texts,...Object.fromEntries((result.writes??[]).map(w=>[w.name,w.text]))};
  const output=new Map((result.writes??[]).map(w=>[w.name,w]));
  function write(name,values,remove=[]){if(sources[name]==null)throw Error('Missing Markdown note: '+name);const text=patch(sources[name],values,remove);if(text!==texts[name])output.set(name,{name,text,...(texts[name]!=null?{expected:texts[name]}:{})});}
  for(const a of doc.anchors){
    const project=doc.projects.find(p=>p.id===a.project),start=byID.get(project.route[0]);
    const values={previous:doc.edges.filter(e=>e.to===a.id).map(e=>noteLink(byID.get(e.from))),next:doc.edges.filter(e=>e.from===a.id).map(e=>noteLink(byID.get(e.to)))};
    if(a.kind==='start')values.milestones=doc.anchors.filter(n=>n.project===a.project&&n.id!==a.id).map(noteLink);
    else values.project=noteLink(start);
    write(a.note,values,['crowmap',...(a.kind==='start'?['project']:[]),'rejoin','replaces','inactive_next',...(a.kind==='revision'?['milestones']:[])]);
  }
  for(const n of doc.notes){if(n.device)continue;const values={date:n.date};if(n.attach.kind==='edge'){const e=doc.edges.find(e=>e.id===n.attach.id);values.between=[noteLink(byID.get(e.from)),noteLink(byID.get(e.to))];}else values.milestone=noteLink(byID.get(n.attach.id));write(n.note,values,['crowmap','attach',...(n.attach.kind==='edge'?['milestone']:['between'])]);}
  doc.noteLinks=true;const writes=[...output.values()];return {doc:resolveMap(validateMap(doc),{...texts,...Object.fromEntries(writes.map(w=>[w.name,w.text]))}),writes};
}

function attachAtDate(doc,attach,date){
  if(attach?.kind!=='edge')return attach;
  const edge=doc.edges.find(e=>e.id===attach.id);if(!edge)return attach;
  const anchors=new Map(doc.anchors.map(a=>[a.id,a])),from=anchors.get(edge.from),to=anchors.get(edge.to);
  if(from&&to&&from.date<=date&&date<=to.date)return attach;
  const target=doc.edges.find(e=>e.project===edge.project&&e.state==='active'&&anchors.get(e.from)?.date<=date&&anchors.get(e.to)?.date>=date);
  if(target)return {kind:'edge',id:target.id};
  const nearest=doc.anchors.filter(a=>a.project===edge.project).sort((a,b)=>Math.abs(day(a.date)-day(date))-Math.abs(day(b.date)-day(date)))[0];
  return nearest?{kind:'anchor',id:nearest.id}:attach;
}
export function resolveAttachment(meta,doc,texts,resolve=noteResolver(texts),byName=new Map(doc.anchors.map(a=>[a.note,a]))) {
  if(meta.between){const names=links(meta,'between').map(resolve);if(names.length!==2)throw Error('between needs two milestone links.');const a=byName.get(names[0]),b=byName.get(names[1]),e=doc.edges.find(e=>e.from===a?.id&&e.to===b?.id);if(!e){if(a&&b)return {kind:'anchor',id:a.id};throw Error('The linked milestones do not share a segment.');}return {kind:'edge',id:e.id};}
  if(meta.milestone){const a=byName.get(resolve(meta.milestone));if(!a)throw Error('Unknown milestone.');return {kind:'anchor',id:a.id};}
  return null;
}

export function resolveMap(source,texts) {
  const unique=new Set();source={...source,notes:source.notes.filter(n=>{const key=(n.device??'local')+':'+normalized(n.note);if(unique.has(key))return false;unique.add(key);return true;})};
  const doc=structuredClone(source),resolve=noteResolver(texts),original=doc.anchors,oldByName=new Map(original.map(a=>[a.note,a]));
  // Start Markdown notes define projects even when the display cache is empty or stale.
  const represented=new Set();
  for(const project of doc.projects){const start=original.find(a=>a.id===project.route[0]);if(!start)continue;let name=start.note;if(texts[name]==null)try{name=resolve('[['+start.title+']]');}catch{}represented.add(normalized(name));}
  const discovered=new Set(),starts=[];
  for(const [name,text] of Object.entries(texts)){let meta;try{meta=readNote(text).meta;}catch{continue;}if(meta.kind==='start'&&!represented.has(normalized(name)))starts.push({name,meta});}
  starts.sort((a,b)=>(a.meta.priority??1)-(b.meta.priority??1)||a.name.localeCompare(b.name));
  for(const {name,meta} of starts){
    const id='project:'+name,start={id:'note:'+name,project:id,note:name,title:meta.title??name.slice(0,-3),date:meta.date,priority:meta.priority??1,kind:'start'};
    doc.projects.push({id,title:start.title,color:TIMELINE_COLORS[doc.projects.length%TIMELINE_COLORS.length],route:[start.id]});original.push(start);oldByName.set(name,start);discovered.add(id);
  }
  // Keep pre-link maps readable until their next successful save converts the properties.
  const linked=doc.noteLinks||discovered.size||original.some(a=>Object.hasOwn(readNote(texts[a.note]??'').meta,'next'));
  if(!linked){for(const n of [...doc.anchors,...doc.notes]){const meta=readNote(n.device?n.cachedText:texts[n.note]).meta;for(const key of ['title','date','priority'])if(meta[key]!=null)n[key]=meta[key];}return validateMap(normalizeTimeline(doc));}
  doc.anchors=[];doc.edges=[];const membership=new Map();let fullyLinked=true;
  for(const project of doc.projects){
    const oldStart=original.find(a=>a.id===project.route[0]);if(!oldStart)throw Error('Project has no start note.');
    const startName=texts[oldStart.note]!=null?oldStart.note:resolve('[['+oldStart.title+']]');
    if(!doc.noteLinks&&!discovered.has(project.id)&&!original.some(a=>a.project===project.id&&Object.hasOwn(readNote(texts[a.note]??'').meta,'next'))){
      fullyLinked=false;
      for(const node of original.filter(a=>a.project===project.id)){const meta=readNote(texts[node.note]).meta;for(const key of ['title','date','priority'])if(meta[key]!=null)node[key]=meta[key];doc.anchors.push(node);membership.set(node.note,project.id);}
      doc.edges.push(...structuredClone(source.edges.filter(e=>e.project===project.id)));continue;
    }
    const queue=[startName,...original.filter(a=>a.project===project.id&&texts[a.note]!=null).map(a=>a.note)],nodes=new Map();
    while(queue.length){const name=queue.shift();if(nodes.has(name))continue;if(membership.has(name)&&membership.get(name)!==project.id)throw Error('A milestone belongs to more than one project: '+name);membership.set(name,project.id);
      const text=texts[name];if(text==null)throw Error('Missing Markdown note: '+name);const meta=readNote(text).meta;day(meta.date);
      const existing=oldByName.get(name)??(name===startName?oldStart:null),node={id:existing?.id??'note:'+name,project:project.id,note:name,title:meta.title??name.slice(0,-3),date:meta.date,priority:meta.priority??1,kind:name===startName?'start':meta.kind==='revision'?'revision':'milestone'};
      nodes.set(name,node);doc.anchors.push(node);
      for(const key of ['previous','next',...(name===startName?['milestones']:[])])for(const link of links(meta,key))queue.push(resolve(link));
    }
    const connect=(a,b)=>{if(!a||!b)throw Error('Unresolved milestone.');if(doc.edges.some(e=>e.from===a.id&&e.to===b.id))return;const cached=source.edges.find(e=>e.from===a.id&&e.to===b.id);doc.edges.push({id:cached?.id??'edge:'+a.id+'>'+b.id,project:project.id,from:a.id,to:b.id,state:'active'});};
    for(const [name,n] of nodes){const meta=readNote(texts[name]).meta;for(const link of links(meta,'next'))connect(n,nodes.get(resolve(link)));for(const link of links(meta,'previous'))connect(nodes.get(resolve(link)),n);}
    project.title=nodes.get(startName).title;
  }
  if(fullyLinked)doc.noteLinks=true;
  const byName=new Map(doc.anchors.map(a=>[a.note,a]));
  const notes=[];for(const [name,text] of Object.entries(texts)){const meta=(()=>{try{return readNote(text).meta;}catch{return {};}})();const cached=source.notes.find(n=>!n.device&&n.note===name);if(!cached&&!meta.between&&!meta.milestone)continue;if(membership.has(name))continue;
    let attach;try{attach=resolveAttachment(meta,doc,texts,resolve,byName);}catch(error){if(cached)throw error;continue;}if(!attach){if(!cached)continue;attach=cached.attach;}const date=meta.date??cached?.date;notes.push({...cached,id:cached?.id??'note:'+name,note:name,title:meta.title??cached?.title??name.slice(0,-3),date,attach:attachAtDate(doc,attach,date)});}
  doc.notes=[...notes,...source.notes.filter(n=>n.device)];
  // A dated Markdown file reached through a body link is also a single shared node.
  const known=new Set([...doc.anchors,...notes].map(n=>n.note)),pending=[...doc.anchors,...notes];
  while(pending.length){const owner=pending.shift();for(const link of linkLeaves(owner.id,texts[owner.note])){
    if(/^[a-z][a-z0-9+.-]*:/i.test(link.url))continue;let name;try{name=resolve('[['+decodeURI(link.url)+']]');}catch{continue;}if(known.has(name))continue;
    const meta=readNote(texts[name]).meta;if(!meta.date)throw Error('Add a date property to '+name+' to place it on the timeline.');day(meta.date);known.add(name);
    const ownerAnchor=owner.kind?owner:doc.anchors.find(a=>a.id===(owner.attach.kind==='anchor'?owner.attach.id:doc.edges.find(e=>e.id===owner.attach.id).from));
    const segment=doc.edges.find(e=>e.project===ownerAnchor.project&&e.state==='active'&&doc.anchors.find(a=>a.id===e.from).date<=meta.date&&doc.anchors.find(a=>a.id===e.to).date>=meta.date);
    const note={id:'note:'+name,note:name,title:meta.title??name.slice(0,-3),date:meta.date,attach:segment?{kind:'edge',id:segment.id}:{kind:'anchor',id:ownerAnchor.id}};
    doc.notes.push(note);pending.push(note);
  }}
  return validateMap(normalizeTimeline(doc));
}

// Internal links connect canonical Markdown nodes; only external resources are leaves.
export function graphLinks(doc,texts) {
  const nodes=[...doc.anchors,...doc.notes],connections=[],leaves=new Map(),seen=new Set(),resolvers=new Map();
  const scope=node=>node.device??'local';
  for(const node of nodes){const key=scope(node);if(!resolvers.has(key))resolvers.set(key,noteResolver(key==='local'?texts:Object.fromEntries(nodes.filter(n=>scope(n)===key).map(n=>[n.note,n.cachedText??'']))));
    const external=[];for(const link of linkLeaves(node.id,node.device?node.cachedText:texts[node.note])){
      if(/^[a-z][a-z0-9+.-]*:/i.test(link.url)){external.push(link);continue;}
      let target,name;try{name=resolvers.get(key)('[['+decodeURI(link.url)+']]');target=nodes.find(n=>scope(n)===key&&n.note===name);}catch{}
      if(target){if(target.id!==node.id){const pair=[node.id,target.id].sort().join('|');if(!seen.has(pair)){seen.add(pair);connections.push({from:node.id,to:target.id});}}}
      else if(!name&&/\.[a-z0-9]{1,8}(?:[#?].*)?$/i.test(link.url)&&! /\.md(?:[#?].*)?$/i.test(link.url))external.push(link);
    }leaves.set(node.id,external);
  }
  return {connections,leaves};
}

export function deleteWorkNote(source,id,texts) {
  return deleteWorkNotes(source,[id],texts);
}
export function deleteMilestone(source,id,texts) {
 const node=source.anchors.find(a=>a.id===id);
 const result=removeMilestone(source,id);
 const linked=linkedTransaction(result,texts);
 const merged={...texts,...Object.fromEntries(linked.writes.map(w=>[w.name,w.text]))};
 const cleaned=removeNoteFiles(linked.doc,[node],merged);
 const writes=new Map(linked.writes.map(w=>[w.name,w]));
 for(const w of cleaned.writes)writes.set(w.name,{name:w.name,text:w.text,expected:texts[w.name]});
 return {doc:cleaned.doc,writes:[...writes.values()],deletes:cleaned.deletes};
}
export function deleteWorkNotes(source,ids,texts) {
  const doc=structuredClone(source),selected=new Set(ids),nodes=doc.notes.filter(n=>selected.has(n.id));if(!nodes.length||nodes.length!==selected.size)throw Error('Work note not found.');
  doc.notes=doc.notes.filter(n=>!selected.has(n.id));
  return removeNoteFiles(doc,nodes,texts);
}

export function timelineNodes(source,startID){
 const start=source.anchors.find(a=>a.id===startID&&a.kind==='start'),project=source.projects.find(p=>p.id===start?.project&&p.route[0]===startID);if(!project)throw Error('Select a timeline start note.');
 const anchors=source.anchors.filter(a=>a.project===project.id),anchorIDs=new Set(anchors.map(a=>a.id)),edges=source.edges.filter(e=>e.project===project.id),edgeIDs=new Set(edges.map(e=>e.id));
 const owns=attach=>attach?.kind==='anchor'?anchorIDs.has(attach.id):attach?.kind==='edge'&&edgeIDs.has(attach.id);
 return {project,anchors,edges,notes:source.notes.filter(n=>owns(n.attach)),owns};
}
export function deleteTimeline(source,startID,texts){
 const scope=timelineNodes(source,startID),doc=structuredClone(source),id=scope.project.id;
 doc.projects=doc.projects.filter(p=>p.id!==id);doc.anchors=doc.anchors.filter(a=>a.project!==id);doc.edges=doc.edges.filter(e=>e.project!==id);doc.notes=doc.notes.filter(n=>!scope.owns(n.attach));
 doc.devices=doc.devices.map(d=>({...d,...(d.attachments?{attachments:d.attachments.filter(a=>!scope.owns(a))}:{})})).filter(d=>doc.notes.some(n=>n.device===d.id)||d.attachments?.length);
 if(doc.view?.milestoneOrder)doc.view.milestoneOrder=Object.fromEntries(Object.entries(doc.view.milestoneOrder).filter(([key])=>!key.startsWith(id+':')));
 return {...removeNoteFiles(doc,[...scope.anchors,...scope.notes],texts),deletingProject:id};
}
function removeNoteFiles(doc,nodes,texts){
  const removed=new Set(nodes.filter(n=>!n.device).map(n=>n.note));
  const resolve=noteResolver(texts),remaining={...texts},writes=[];for(const name of removed)delete remaining[name];
  const owned=new Set([...doc.anchors,...doc.notes.filter(n=>!n.device)].map(n=>n.note));
  for(const name of owned){const before=remaining[name];if(before==null)continue;
    const text=before.replace(/!?\[\[([^\n]+?)\]\]/g,(whole,value)=>{let target;try{target=resolve('[['+value+']]');}catch{return whole;}return removed.has(target)?(value.split('|')[1]??value.split('#')[0]):whole;});
    if(text!==before){remaining[name]=text;writes.push({name,text,expected:before});}
  }
  return {doc:resolveMap(doc,remaining),writes,deletes:[...removed].map(name=>({name,expected:texts[name]}))};
}

const isoDay=d=>new Date(d*86400000).toISOString().slice(0,10);
function connectedMilestoneIDs(doc,id,forward){
 const found=new Set(),queue=[id],seen=new Set([id]);
 while(queue.length){const current=queue.shift();for(const e of doc.edges){const next=forward?e.from===current&&e.to:e.to===current&&e.from;if(!next||seen.has(next))continue;seen.add(next);found.add(next);queue.push(next);}}
 return found;
}
export function followingMilestoneIDs(doc,id){return connectedMilestoneIDs(doc,id,true);}
export function precedingMilestoneIDs(doc,id){return connectedMilestoneIDs(doc,id,false);}
export function movedDate(doc,id,requested){
 const node=[...doc.anchors,...doc.notes].find(n=>n.id===id);if(!node)throw Error('Note no longer exists.');let value=day(requested);
 if(node.kind){
  let min=-Infinity,max=Infinity;const anchors=new Map(doc.anchors.map(a=>[a.id,a]));
  const following=followingMilestoneIDs(doc,id),preceding=precedingMilestoneIDs(doc,id);
  if(![...preceding].some(fid=>day(anchors.get(fid).date)>value)){
   for(const edge of doc.edges){if(edge.to===id)min=Math.max(min,day(anchors.get(edge.from).date));}
  }
  if(![...following].some(fid=>day(anchors.get(fid).date)<value)){
   for(const edge of doc.edges){if(edge.from===id)max=Math.min(max,day(anchors.get(edge.to).date));}
  }
  value=Math.min(max,Math.max(min,value));
 }
 return isoDay(value);
}
function applyDateShift(doc,id,requested,preserveGaps=false){
 const node=doc.anchors.find(a=>a.id===id);if(!node)return new Set();
 const from=day(node.date),to=day(requested),delta=to-from,following=followingMilestoneIDs(doc,id),preceding=precedingMilestoneIDs(doc,id),changed=new Set([id]);
 node.date=requested;
 const chain=delta>0?following:delta<0?preceding:new Set();
 const crosses=delta>0?[...following].some(fid=>day(doc.anchors.find(a=>a.id===fid).date)<to):delta<0?[...preceding].some(fid=>day(doc.anchors.find(a=>a.id===fid).date)>to):false;
 if(crosses){
  if(preserveGaps){
   for(const a of doc.anchors){if(!chain.has(a.id))continue;a.date=isoDay(day(a.date)+delta);changed.add(a.id);}
   const shifted=new Set([id,...chain]);
   for(const n of doc.notes){if(n.device)continue;const edge=n.attach.kind==='edge'?doc.edges.find(e=>e.id===n.attach.id):null,toward=delta>0?edge?.from:edge?.to;if(edge&&shifted.has(toward)||n.attach.kind==='anchor'&&chain.has(n.attach.id)){n.date=isoDay(day(n.date)+delta);changed.add(n.id);}}
  }else{
   const gathered=new Set([id]);
   for(const a of doc.anchors){if(!chain.has(a.id)||(delta>0?day(a.date)>=to:day(a.date)<=to))continue;a.date=requested;changed.add(a.id);gathered.add(a.id);}
   for(const n of doc.notes){if(!n.device&&n.attach.kind==='anchor'&&gathered.has(n.attach.id)&&n.attach.id!==id){n.date=requested;changed.add(n.id);}}
  }
 }
 const anchors=new Map(doc.anchors.map(a=>[a.id,a]));
 for(const n of doc.notes){
  if(n.device||n.attach.kind!=='edge')continue;
  const edge=doc.edges.find(e=>e.id===n.attach.id),start=anchors.get(edge?.from),end=anchors.get(edge?.to);if(!start||!end)continue;
  let date=n.date;if(day(date)<day(start.date))date=start.date;if(day(date)>day(end.date))date=end.date;
  if(date!==n.date){n.date=date;changed.add(n.id);}
 }
 return changed;
}
export function shiftFollowingDates(source,id,requested,texts){
 const doc=structuredClone(source),node=doc.anchors.find(a=>a.id===id);if(!node)return null;
 const from=day(node.date),to=day(requested),following=followingMilestoneIDs(doc,id),preceding=precedingMilestoneIDs(doc,id);
 if(!(to>from&&[...following].some(fid=>day(doc.anchors.find(a=>a.id===fid).date)<to)||to<from&&[...preceding].some(fid=>day(doc.anchors.find(a=>a.id===fid).date)>to)))return null;
 const changed=applyDateShift(doc,id,requested),writes=[];
 for(const cid of changed){const n=[...doc.anchors,...doc.notes].find(x=>x.id===cid),before=texts[n.note];if(before==null)throw Error('Markdown note not found.');const text=patch(before,{date:n.date});if(text!==before)writes.push({name:n.note,expected:before,text});}
 return linkedTransaction({doc:validateMap(doc),writes},texts);
}
export function applyNoteDate(doc,name,source,texts){
 const next={...texts,[name]:source};
 try{return {doc:resolveMap(doc,next),source,writes:[{name,text:source,expected:texts[name]}]};}
 catch(error){
  const item=doc.anchors.find(a=>a.note===name);if(!item)throw error;
  const requested=readNote(source).meta.date,cascaded=shiftFollowingDates(doc,item.id,requested,texts);
  if(cascaded){
   const writes=[{name,text:source,expected:texts[name]},...cascaded.writes.filter(w=>w.name!==name)];
   const combined={...texts,...Object.fromEntries(writes.map(w=>[w.name,w.text]))};
   return {doc:resolveMap(doc,combined),source,writes};
  }
  const clamped=movedDate(doc,item.id,requested);if(clamped===requested)throw error;
  source=editFrontmatter(source,'date',{value:clamped,type:'date'});
  return {doc:resolveMap(doc,{...texts,[name]:source}),source,writes:[{name,text:source,expected:texts[name]}]};
 }
}

export function moveNodes(source,ids,{days=0,priority,cascadePriority=false,preserveGaps=false},texts){
 const doc=structuredClone(source),writes=[],changed=new Set();
 for(const id of new Set(ids)){
  const node=[...doc.anchors,...doc.notes].find(n=>n.id===id);if(!node||node.device)throw Error('Only local Markdown notes can be moved.');
  const date=movedDate(doc,id,isoDay(day(node.date)+days));
  if(node.kind)for(const cid of applyDateShift(doc,id,date,preserveGaps))changed.add(cid);
  else node.date=date;
  if(node.kind&&priority!=null){const value=Math.max(1,Math.min(doc.projects.length,Math.round(priority)));for(const sibling of doc.anchors.filter(a=>a.project===node.project&&(cascadePriority?a.date>=date:a.date===date))){sibling.priority=value;changed.add(sibling.id);}}
  if(!node.kind&&node.attach.kind==='edge'){
   const current=doc.edges.find(e=>e.id===node.attach.id),anchors=new Map(doc.anchors.map(a=>[a.id,a]));
   if(date<anchors.get(current.from).date||date>anchors.get(current.to).date){const target=doc.edges.find(e=>e.project===current.project&&e.state==='active'&&anchors.get(e.from).date<=date&&anchors.get(e.to).date>=date);node.attach=target?{kind:'edge',id:target.id}:{kind:'anchor',id:doc.anchors.filter(a=>a.project===current.project).sort((a,b)=>Math.abs(day(a.date)-day(date))-Math.abs(day(b.date)-day(date)))[0].id};}
  }
  changed.add(node.id);
 }
 for(const id of changed){const node=[...doc.anchors,...doc.notes].find(n=>n.id===id),before=texts[node.note];if(before==null)throw Error('Markdown note not found.');writes.push({name:node.note,expected:before,text:patch(before,{date:node.date,...(node.kind?{priority:node.priority}:{})})});}
 return linkedTransaction({doc:validateMap(doc),writes},texts);
}
