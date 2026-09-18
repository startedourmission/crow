import {uid,validateMap,readNote,flatNote} from './crowmap-model.js';
import {linkedTransaction,noteName,noteResolver} from './crowmap-links.js';
import {editFrontmatter} from './frontmatter-model.js';

// Selection expands through project milestones only. Weak links and attached work
// never imply file ownership and therefore never expand a copy operation.
export function copyNodes(doc,ids){
 const all=[...doc.anchors,...doc.notes],selected=new Set(ids);
 if(!selected.size||[...selected].some(id=>!all.some(n=>n.id===id)))throw Error('Select existing notes to copy.');
 const projects=new Set(doc.anchors.filter(a=>a.kind==='start'&&selected.has(a.id)).map(a=>a.project));
 return all.filter(n=>selected.has(n.id)||n.kind&&projects.has(n.project));
}
function setProperties(source,values){
 for(const [key,value]of Object.entries(values))source=editFrontmatter(source,key,{value,type:Array.isArray(value)?'list':typeof value==='number'?'number':'text',add:!Object.hasOwn(readNote(source).meta,key)});
 return source;
}
function rewriteLinks(text,resolve,names){
 // Keep headings, aliases, embedding syntax, comments and ordinary body text intact.
 return text.replace(/\[\[([^\]\n]+)\]\]/g,(whole,target)=>{
  let old;try{old=resolve('[['+target+']]');}catch{return whole;}
  const name=names.get(old);if(!name)return whole;
  const suffix=target.search(/[#|]/),extension=target.split(/[#|]/)[0].endsWith('.md')?'.md':'';
  return '[['+name.slice(0,-3)+extension+(suffix<0?'':target.slice(suffix))+']]';
 });
}
export function duplicateNodes(source,ids,texts){
 const nodes=copyNodes(source,ids),doc=structuredClone(source),used=Object.keys(texts),copies=new Map(),projects=new Map(),names=new Map(),writes=[],reads=[];
 const resolve=noteResolver(texts);
 for(const start of nodes.filter(n=>n.kind==='start')){
  const original=doc.projects.find(p=>p.id===start.project),name=noteName(start.note.slice(0,-3),used),id=uid(),priority=doc.projects.length+1;
  used.push(name);names.set(start.note,name);projects.set(start.project,{...original,id,title:name.slice(0,-3),route:[],priorityOffset:priority-start.priority});
  doc.projects.push(projects.get(start.project));
 }
 for(const node of nodes){
  const project=projects.get(node.project),originalStart=project&&source.anchors.find(a=>a.id===source.projects.find(p=>p.id===node.project).route[0]);
  let base=node.note.slice(0,-3);
  if(project&&node.kind!=='start'&&base.startsWith(originalStart.note.slice(0,-3)+'-'))base=project.title+base.slice(originalStart.note.length-3);
  const name=node.kind==='start'?names.get(node.note):noteName(base,used);if(node.kind!=='start')used.push(name);
  if(!node.device)names.set(node.note,name);
  const copy={...structuredClone(node),id:uid(),note:name};
  if(project){copy.project=project.id;copy.priority=Math.max(1,node.priority+project.priorityOffset);if(node.kind==='start'){copy.title=project.title;project.route=[copy.id];}}
  // A remote note is copied as a local Markdown snapshot, not another device reference.
  delete copy.device;delete copy.cachedText;copies.set(node.id,copy);
  (node.kind?doc.anchors:doc.notes).push(copy);
 }
 for(const e of source.edges){
  const from=copies.get(e.from),to=copies.get(e.to),project=projects.get(e.project);
  if(project){if(from&&to)doc.edges.push({...e,id:uid(),project:project.id,from:from.id,to:to.id});}
  else if(from||to)doc.edges.push({...e,id:uid(),from:from?.id??e.from,to:to?.id??e.to});
 }
 for(const node of nodes){
  const copy=copies.get(node.id),before=node.device?node.cachedText:texts[node.note];
  if(typeof before!=='string'||!flatNote(copy.note))throw Error('Markdown note is unavailable: '+node.note);
  let text=node.device?before:rewriteLinks(before,resolve,names);
  const values={};if(node.kind==='start')values.title=copy.title;
  if(copy.priority!==node.priority)values.priority=copy.priority;
  if(node.device){values.date=copy.date;values.title=copy.title;}
  text=setProperties(text,values);writes.push({name:copy.note,text});
  if(!node.device)reads.push({name:node.note,expected:before});
 }
 for(const p of projects.values())delete p.priorityOffset;
 const result=linkedTransaction({doc:validateMap(doc),writes},texts);
 return {...result,reads,copiedIDs:nodes.filter(n=>ids.includes(n.id)).map(n=>copies.get(n.id).id)};
}
