import {copyNodes,duplicateNodes} from './crowmap-copy.js';
import {fileTitle,renamedNoteSource} from './file-title.js';
import {embeddedNoteEditor} from './crowmap-note-editor.js';
import {linkedTransaction,resolveMap,resolveAttachment,noteResolver,graphLinks,noteLink,deleteWorkNotes,deleteMilestone,moveNodes,applyNoteDate,timelineNodes,deleteTimeline,patch} from './crowmap-links.js';
import {uid,validateMap,createProject,addMilestone,connectMilestones,disconnectMilestones,mainMilestoneIDs,reorderMilestones,addNote,linkLeaves,layoutMap,readNote,today,day,DATE_UNITS,dateLabelStride,mapCamera,timelineCurveY,TIMELINE_COLORS,setProjectColor,PRIORITY_GAP,PRIORITY_GAP_MIN,PRIORITY_GAP_MAX,clampPriorityGap,NOTE_TENSION,NOTE_TENSION_MIN,NOTE_TENSION_MAX,clampNoteTension} from './crowmap-model.js';
import {el,button,input,select,field,dialog,actions,iconButton} from './obsidian-ui.js';
import {animateNotes,nodeDegrees,nodeRadius} from './crowmap-motion.js';
import {graphGestures} from './crowmap-gestures.js';
const send=body=>window.webkit.messageHandlers.crowmap.postMessage(body),main=document.querySelector('main');
const markdownCache=new Map();
let popupPoint={x:100,y:120},previewID=null,embedded=null;
let fitNext=true,controlsOpen=false,viewActive=true;
const selectedNotes=new Set();let stopGestures=()=>{};
function persistView(){send({action:'setView',dateUnit,edgeScale,priorityGap,noteTension,showHistory,showNoteTitles});}
function publishSelection(){send({action:'selectNode',id:selected?.kind==='anchor'?selected.id:''});}
let edgeScale=1,stopMotion=()=>{};
let dateUnit='day',priorityGap=PRIORITY_GAP,noteTension=NOTE_TENSION,focusDate=null;
const dateString=d=>new Date(d*86400000).toISOString().slice(0,10);
let data,selected=null,zoom=1,showHistory=true,showNoteTitles=true,search='',pending=null,camera=null,graphError=null;
let undoStack=[],redoStack=[];
const svgNS='http://www.w3.org/2000/svg';
function svg(tag,attrs={},text){const node=document.createElementNS(svgNS,tag);for(const [k,v]of Object.entries(attrs))node.setAttribute(k,v);if(text!=null)node.textContent=text;return node;}
function setViewBox(node,x,y,w,h){node.setAttribute('viewBox',`${x} ${y} ${w} ${h}`);node.setAttribute('preserveAspectRatio','none');}
function curvePath(points){return 'M '+points[0].x+' '+points[0].y+points.slice(1).map((b,i)=>{const a=points[i],dx=b.x-a.x,dy=b.y-a.y;if(Math.abs(dy)<.5||Math.abs(dx)<14)return ` L ${b.x} ${b.y}`;const pull=Math.min(Math.abs(dx)*.42,Math.abs(dy)*.5);const dir=dx<0?-1:1;return ` C ${a.x+dir*pull} ${a.y}, ${b.x-dir*pull} ${b.y}, ${b.x} ${b.y}`;}).join('');}
function straightPath(points){const a=points[0],b=points.at(-1);return `M ${a.x} ${a.y} L ${b.x} ${b.y}`;}
function edgePath(points,straight){return straight?straightPath(points):curvePath(points);}
function notice(message){document.querySelector('.map-error')?.remove();const e=el('div',message,'map-error');e.setAttribute('role','alert');main.prepend(e);}
function forgetMoves(){undoStack=[];redoStack=[];}
function snapshotTexts(names){return Object.fromEntries(names.map(name=>[name,data.texts[name]]).filter(([,text])=>text!=null));}
function restoreWrites(texts){
 const writes=[];
 for(const [name,old] of Object.entries(texts)){
  const current=data.texts[name];if(current===old)continue;
  if(current==null){writes.push({name,text:old});continue;}
  const meta=readNote(old).meta,now=readNote(current).meta,values={date:meta.date},remove=[];
  if(meta.priority!=null)values.priority=meta.priority;
  if(Object.hasOwn(meta,'between'))values.between=meta.between;else if(Object.hasOwn(now,'between'))remove.push('between');
  if(Object.hasOwn(meta,'milestone'))values.milestone=meta.milestone;else if(Object.hasOwn(now,'milestone'))remove.push('milestone');
  const text=patch(current,values,remove);if(text!==current)writes.push({name,expected:current,text});
 }
 return writes;
}
function captureState(result){
 const names=new Set([...(result.writes??[]).map(w=>w.name),...(result.deletes??[])]);
 return {doc:structuredClone(data.doc),texts:snapshotTexts([...names].filter(name=>data.texts[name]!=null)),files:Object.keys(data.texts)};
}
function restorePatch(state){
 return {doc:structuredClone(state.doc),writes:restoreWrites(state.texts),deletes:Object.keys(data.texts).filter(name=>!state.files.includes(name)).map(name=>({name,expected:data.texts[name]}))};
}
async function travelMoves(undo){
 if(pending||!data||!viewActive)return;
 const from=undo?undoStack:redoStack,to=undo?redoStack:undoStack,entry=from.at(-1);if(!entry)return;
 try{if(!await flushNote())return;await applyChange(()=>restorePatch(undo?entry.before:entry.after),{links:false,record:false});from.pop();to.push(entry);}catch(e){notice(e.message);render();}
}
async function applyChange(compute,{links=true,record=true}={}){
 if(!await flushNote())return false;
 const before=record?{doc:structuredClone(data.doc),texts:{},files:Object.keys(data.texts)}:null;
 let result=compute();if(links){if(graphError)throw Error('Fix the note links before changing the plan. '+graphError);result=linkedTransaction(result,data.texts);}
 if(before)before.texts=snapshotTexts([...(result.writes??[]).map(w=>w.name),...(result.deletes??[])].filter(name=>data.texts[name]!=null));
 const previous={doc:data.doc,texts:data.texts,source:data.source};
 const texts={...data.texts};for(const w of result.writes??[])texts[w.name]=w.text;for(const name of result.deletes??[])delete texts[name];
 data.doc=result.doc;data.texts=texts;data.source=JSON.stringify(result.doc,null,2)+'\n';
 render();
 try{
  await transaction(result,{links:false,silent:true,expected:previous.source});
  if(record){undoStack.push({before,after:{doc:structuredClone(data.doc),texts:snapshotTexts(Object.keys(before.texts).concat((result.writes??[]).map(w=>w.name)).filter(name=>data.texts[name]!=null)),files:Object.keys(data.texts)}});if(undoStack.length>50)undoStack.shift();redoStack=[];}
  return true;
 }catch(e){data.doc=previous.doc;data.texts=previous.texts;data.source=previous.source;throw e;}
}
function transaction(result,{links=true,draftNote=null,forget=false,silent=false,expected}={}){if(links&&graphError)throw Error('Fix the note links before changing the plan. '+graphError);if(links)result=linkedTransaction(result,data.texts);if(pending)return Promise.reject(Error('Wait for the current change to save.'));validateMap(result.doc);return new Promise((resolve,reject)=>{pending={resolve:value=>{if(forget)forgetMoves();if(silent&&value?.source)data.source=value.source;resolve(value);},reject,silent};send({action:'save',draftNote,source:JSON.stringify(result.doc,null,2)+'\n',expected:expected??data.source,writes:result.writes??[],deletes:result.deletes??[],reads:result.reads??[],deletingProject:result.deletingProject??null});});}
async function sampleProject(){
 if(!await flushNote())return;
 const date=today(),offset=days=>new Date((day(date)+days)*86400000).toISOString().slice(0,10);
 try {const result=createProject(data.doc,{title:'Sample project'+(data.doc.projects.length?' '+(data.doc.projects.length+1):''),date,priority:data.doc.projects.length+1,milestones:[
  {title:'Research',date:offset(7)},{title:'Prototype',date:offset(14)},
  {title:'Build',date:offset(21)},{title:'Release',date:offset(28)}]},Object.keys(data.texts));let id;await applyChange(()=>{id=result.doc.projects.at(-1).route[0];return result;});selected=null;selectedNotes.clear();focusTimeline(id);}
 catch(e){notice(e.message);}
}
function focusRect(id){
 const node=document.querySelector('[data-node-id="'+CSS.escape(id)+'"]'),circle=node?.querySelector('circle:not(.connection-handle)');
 if(!circle)return null;
 const r=circle.getBoundingClientRect();
 return {left:r.left-16,right:r.right+88,top:r.top-28,bottom:r.bottom+28};
}
function focusTimeline(id){
 const viewport=mapView.viewport??document.querySelector('.map-viewport'),node=document.querySelector('[data-node-id="'+CSS.escape(id)+'"]'),circle=node?.querySelector('circle:not(.connection-handle)');
 if(!viewport||!circle)return;
 node.removeAttribute('display');
 const x=Number(circle.getAttribute('cx')),y=Number(circle.getAttribute('cy'));
 if(!Number.isFinite(x)||!Number.isFinite(y))return;
 const room=Math.min(560,Math.max(240,viewport.clientWidth*.48));
 viewport.scrollLeft=Math.max(0,x*zoom-Math.max(80,viewport.clientWidth-room)*.45);
 viewport.scrollTop=Math.max(0,y*zoom-viewport.clientHeight*.4);
 commitCamera();
 const popup=document.querySelector('.map-popup:not(.node-menu)');
 if(popup)placePopup(popup,focusRect(id));
 node.focus?.({preventScroll:true});
}
function dateAtPopup(){
 const layout=mapView.layout,canvas=mapView.canvas;if(!layout||!canvas)return today();
 const r=canvas.getBoundingClientRect(),vb=canvas.viewBox.baseVal,z=r.width/Math.max(1,vb.width);
 return layout.dateAt(vb.x+(popupPoint.x-r.left)/z);
}
async function newMilestone(fromID,edgeID){try{let date;if(edgeID){date=dateAtPopup();const edge=data.doc.edges.find(e=>e.id===edgeID),a=data.doc.anchors.find(n=>n.id===edge?.from),b=data.doc.anchors.find(n=>n.id===edge?.to);if(a&&date<a.date)date=a.date;if(b&&date>b.date)date=b.date;}let id;await applyChange(()=>{const result=addMilestone(data.doc,fromID,Object.keys(data.texts),edgeID?{edgeID,date}:undefined);id=result.doc.anchors.at(-1).id;return result;});selected={kind:'anchor',id};render();}catch(e){notice(e.message);}}
async function addWork(attach){
 try{if(!await flushNote())return;let date=today();if(attach.kind==='edge'){const edge=data.doc.edges.find(e=>e.id===attach.id),a=data.doc.anchors.find(a=>a.id===edge.from),b=data.doc.anchors.find(a=>a.id===edge.to);date=date<a.date?a.date:date>b.date?b.date:date;}
 let id;await applyChange(()=>{const result=addNote(data.doc,{title:'New note',date,body:'',attach},Object.keys(data.texts));id=result.doc.notes.at(-1).id;return result;});selected={kind:'note',id};render();if(viewActive)embedded?.editor.commands.focus('end');
 }catch(e){notice(e.message);}
}
async function linkedNote(item){
 try{let id;await applyChange(()=>{const result=addNote(data.doc,{title:'New note',date:item.date,body:noteLink(item),attach:item.attach},Object.keys(data.texts));id=result.doc.notes.at(-1).id;return result;});selected={kind:'note',id};render();if(viewActive)embedded?.editor.commands.focus('end');
 }catch(e){notice(e.message);}
}
async function confirmTimelineDeletion(startID){
 try{
  if(!await flushNote())return;if(graphError)throw Error(graphError);
  const scope=timelineNodes(data.doc,startID),expected=data.source;
  const modal=dialog('Delete timeline?',(form,close)=>{
   form.closest('dialog').setAttribute('aria-label','Delete timeline');
   form.append(el('p','“'+scope.project.title+'” and its '+(scope.anchors.length-1)+' milestones and '+scope.notes.length+' attached notes will be removed from this map.'));
   form.append(el('p','Local Markdown files will be moved to Crowmap’s deleted-notes folder. Remote originals will stay on their devices.','muted'));
   const row=el('div',null,'dialog-actions'),error=el('p','','field-error'),cancel=button('Cancel',close),submit=button('Delete timeline',null,'danger');submit.type='submit';submit.dataset.confirm='true';error.setAttribute('role','alert');row.append(cancel,submit);form.append(error,row);let busy=false;
   form.onsubmit=async event=>{event.preventDefault();if(busy)return;busy=true;submit.disabled=true;cancel.disabled=true;
    try{if(data.source!==expected)throw Error('The timeline changed. Close this dialog and review it before deleting.');await applyChange(()=>deleteTimeline(data.doc,startID,data.texts),{links:false});selected=null;selectedNotes.clear();close();}
    catch(e){error.textContent=e.message;}finally{busy=false;submit.disabled=false;cancel.disabled=false;}
   };
   form.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.isComposing&&event.target!==cancel){event.preventDefault();if(!event.repeat&&!busy)form.requestSubmit(submit);}});
   form.closest('dialog').addEventListener('cancel',event=>{if(busy)event.preventDefault();});
  });modal.querySelector('[data-confirm]').focus();
 }catch(e){notice(e.message);}
}
function timelineColorPicker(menu,projectID){
 const current=data.doc.projects.find(p=>p.id===projectID)?.color,label=el('p','Timeline color','muted');label.style.padding='4px 8px 0';menu.append(label);
 const row=el('div',null,'color-swatches');row.setAttribute('role','group');row.setAttribute('aria-label','Timeline color');
 const apply=async color=>{menu.remove();try{await applyChange(()=>setProjectColor(data.doc,projectID,color),{links:false});}catch(e){notice(e.message);}};
 for(const color of TIMELINE_COLORS){const swatch=button('');swatch.className='color-swatch';swatch.style.background=color;swatch.setAttribute('aria-label',color);if(color===current)swatch.setAttribute('aria-pressed','true');swatch.onclick=()=>apply(color);row.append(swatch);}
 const custom=input(current??TIMELINE_COLORS[0],'color');custom.setAttribute('aria-label','Custom timeline color');custom.onchange=()=>apply(custom.value);row.append(custom);menu.append(row);
}
async function nodeMenu(event,item){
 event.preventDefault();event.stopPropagation();if(!await flushNote())return;
 if(item.kind)selectedNotes.clear();else if(!selectedNotes.has(item.id)){selectedNotes.clear();selectedNotes.add(item.id);}selected=null;render({selection:true});
 const ids=item.kind?[item.id]:[...selectedNotes],items=data.doc.notes.filter(n=>selectedNotes.has(n.id)),menu=el('section',null,'map-popup node-menu');menu.setAttribute('role','menu');menu.setAttribute('aria-label','Note actions');
 const action=(title,callback)=>{const control=button(title,callback);control.setAttribute('role','menuitem');menu.append(control);return control;};
 if(item.kind)timelineColorPicker(menu,item.project);
 action('Copy',()=>{menu.remove();try{const nodes=copyNodes(data.doc,ids);for(const n of nodes)if(data.drafts?.[n.note]&&!n.device)throw Error('Save the selected notes before copying.');send({action:'copyNotes',files:nodes.map(n=>({name:n.note,...(n.device?{text:n.cachedText??''}:{expected:data.texts[n.note]})}))});}catch(e){notice(e.message);}});
 action('Duplicate',async()=>{menu.remove();try{if(graphError)throw Error(graphError);const nodes=copyNodes(data.doc,ids);for(const n of nodes)if(data.drafts?.[n.note]&&!n.device)throw Error('Save the selected notes before duplicating.');let copied;await applyChange(()=>{const result=duplicateNodes(data.doc,ids,data.texts);copied=result.copiedIDs;return result;},{links:false});selectedNotes.clear();for(const id of copied)if(data.doc.notes.some(n=>n.id===id))selectedNotes.add(id);selected=copied.length===1?{kind:item.kind?'anchor':'note',id:copied[0]}:null;render();}catch(e){notice(e.message);}});
 if(item.kind&&!data.doc.edges.some(e=>e.from===item.id))action('Add next milestone',()=>{menu.remove();newMilestone(item.id);});
 if(item.kind==='start')action('Delete timeline',()=>{menu.remove();confirmTimelineDeletion(item.id);}).classList.add('danger');
 else if(item.kind)action('Delete milestone',async()=>{menu.remove();try{await applyChange(()=>deleteMilestone(data.doc,item.id,data.texts),{links:false});selected=null;render();}catch(e){notice(e.message);}}).classList.add('danger');
 if(!item.kind){
  if(ids.length===1)action('Create linked note',()=>{menu.remove();linkedNote(item);}).disabled=!!item.device;
  for(const provider of data.agentProviders??[])action('Run '+provider.title+' with '+ids.length+' note'+(ids.length===1?'':'s'),()=>{menu.remove();send({action:'runAgent',provider:provider.id,nodeIDs:ids});}).disabled=items.some(n=>n.device);
  action(ids.length>1?'Delete '+ids.length+' notes':item.device?'Remove from map':'Delete note',async()=>{menu.remove();try{await applyChange(()=>deleteWorkNotes(data.doc,ids,data.texts),{links:false});selectedNotes.clear();render();}catch(e){notice(e.message);}});
 }
 main.append(menu);popupPoint={x:event.clientX,y:event.clientY};placePopup(menu);menu.querySelector('button')?.focus();
}
async function edgeMenu(event,edge){
 event.preventDefault();event.stopPropagation();if(!await flushNote())return;
 selectedNotes.clear();selected=null;render({selection:true});
 const menu=el('section',null,'map-popup node-menu');menu.setAttribute('role','menu');menu.setAttribute('aria-label','Timeline actions');
 timelineColorPicker(menu,edge.project);
 main.append(menu);popupPoint={x:event.clientX,y:event.clientY};placePopup(menu);menu.querySelector('button')?.focus();
}
async function attachDevice(attach){if(!await flushNote())return;dialog('Attach notes from a device',(form,close)=>{const available=data.hosts??[],host=select(available.map(h=>[h.id,h.label]),available[0]?.id??'');const list=el('div',null,'remote-notes');let loaded=[],selectedHost=null;
 form.append(field('Connected device / account',host),button('Load Crowmap notes',()=>{selectedHost=host.value;if(!selectedHost)return;send({action:'remoteNotes',hostID:selectedHost});list.textContent='Reading ~/.crow/crowmap…';}),list);
 const receive=e=>{if(e.detail.hostID!==selectedHost)return;loaded=e.detail.notes??[];list.replaceChildren();if(e.detail.error){list.textContent=e.detail.error;return;}loaded.forEach((n,i)=>{const row=el('label'),check=input('','checkbox');check.dataset.index=i;row.append(check,el('span',n.title+' · '+n.date));list.append(row);});if(!loaded.length)list.textContent='No dated Markdown notes found.';};document.addEventListener('crowmap-remote',receive);
 form.closest('dialog').addEventListener('close',()=>document.removeEventListener('crowmap-remote',receive),{once:true});
 actions(form,close,async()=>{const chosen=[...list.querySelectorAll('input:checked')].map(c=>loaded[Number(c.dataset.index)]);if(!chosen.length)throw Error('Select notes to attach.');await applyChange(()=>{let doc=structuredClone(data.doc);let device=doc.devices.find(d=>d.hostID===selectedHost);if(!device){device={id:uid(),hostID:selectedHost,label:available.find(h=>h.id===selectedHost).label};doc.devices.push(device);}device.attachments=[...(device.attachments??[]).filter(a=>a.id!==attach.id),attach];for(const n of chosen){doc=addNote(doc,{title:n.title,date:n.date,body:'',attach,device:device.id,note:n.name,cachedText:n.text}).doc;}return {doc,writes:[]};});},'Attach notes');});}
function textFor(item){return item.device?item.cachedText??'':data.texts?.[item.note]??'';}
async function openNote(item){if(!await flushNote())return;send({action:'openNote',name:item.note,...(item.device?{hostID:data.doc.devices.find(d=>d.id===item.device).hostID}:{})});}
async function openLink(url,item){
 if(!await flushNote())return;
 if(!item.device&&/^\[\[/.test(url))try{const name=noteResolver(data.texts)(url),node=[...data.doc.anchors,...data.doc.notes].find(n=>!n.device&&n.note===name);if(node){selected={kind:node.kind?'anchor':'note',id:node.id};render();return;}}catch{}
 send({action:'openLink',url:url.replace(/^\[\[|\]\]$/g,''),...(item.device?{hostID:data.doc.devices.find(d=>d.id===item.device).hostID}:{})});
}
let renamePending=null;
function noteDetails(panel,item){
 const text=data.drafts?.[item.note]??textFor(item),heading=el('div',null,'popup-heading');
 heading.append(el('h2',item.device?item.title:''),el('span',null,'spacer'),iconButton('fit','Open note in editor',()=>openNote(item)),iconButton('close','Close',closePopup));panel.append(heading);
 const body=el('article',null,'note-markdown'),status=el('div',null,'muted note-save-status');panel.append(body,status);
 if(item.device){body.textContent=readNote(text).body;previewID=uid();body.dataset.preview=previewID;send({action:'markdown',id:previewID,text:readNote(text).body});return;}
 const title=fileTitle(async value=>{
  if(!await flushNote())throw Error('Save the note before renaming.');
  const source=renamedNoteSource(data.texts[item.note],value);
  return new Promise((resolve,reject)=>{renamePending={resolve,reject};send({action:'rename',name:item.note,title:value,source,expected:data.texts[item.note]});});
 });title.set(item.note);panel.insertBefore(title.dom,body);
 const state={id:item.id,name:item.note,status,dirty:text!==textFor(item),timer:null,saving:null,lastDraft:text};embedded=state;
 const editor=embeddedNoteEditor(body,text,{paths:Object.keys(data.texts),onOpenLink:url=>openLink(/^(?:[a-z]+:|\[\[)/i.test(url)?url:'[['+url+']]',item),onSave:()=>flushNote(),onChange(source){state.dirty=true;status.textContent='Saving…';send({action:'draft',name:item.note,source,expected:state.lastDraft});state.lastDraft=source;clearTimeout(state.timer);state.timer=setTimeout(()=>flushNote(),400);}});
 Object.assign(state,editor,{destroy:()=>{editor.destroy();title.destroy();}});if(state.dirty){status.textContent='Unsaved changes';state.timer=setTimeout(()=>flushNote(),400);}
}
async function flushNote(){
 const state=embedded;if(!state?.dirty)return true;if(state.blocked)return false;clearTimeout(state.timer);
 if(state.saving){const okay=await state.saving;return okay&&state.dirty?flushNote():okay;}
 let source=state.read();state.saving=(async()=>{try{
  if(pending){state.status.textContent='Waiting to save…';state.timer=setTimeout(()=>flushNote(),100);return false;}
  const applied=applyNoteDate(data.doc,state.name,source,data.texts);
  source=applied.source;
  let texts={...data.texts,...Object.fromEntries(applied.writes.map(w=>[w.name,w.text]))},doc=applied.doc;
  const previous=data.doc.notes.find(n=>n.note===state.name&&!n.device),next=doc.notes.find(n=>n.note===state.name&&!n.device);
  let result={doc,writes:applied.writes};
  if(previous&&next&&JSON.stringify(previous.attach)!==JSON.stringify(next.attach))result=linkedTransaction(result,texts);
  state.dirty=false;
  try{await transaction(result,{links:false,draftNote:state.name});state.status.textContent='Saved';return true;}
  catch(e){state.dirty=true;throw e;}
 }catch(e){state.status.textContent=e.message;return false;}})();try{return await state.saving;}finally{state.saving=null;}
}
async function closePopup(){if(!await flushNote())return;selected=null;render({selection:true});}
function placePopup(panel,anchor){
 const margin=10,gap=16,width=panel.offsetWidth,height=panel.offsetHeight;
 const box=anchor||(!panel.classList.contains('node-menu')&&selected?.id&&focusRect(selected.id))||{left:popupPoint.x,right:popupPoint.x,top:popupPoint.y,bottom:popupPoint.y};
 const fits=(x,y)=>x>=margin&&y>=58&&x+width<=innerWidth-margin&&y+height<=innerHeight-margin;
 const hits=(x,y)=>x<box.right+gap&&x+width>box.left-gap&&y<box.bottom+gap&&y+height>box.top-gap;
 const candidates=[
  {x:box.right+gap,y:box.top},
  {x:box.left-width-gap,y:box.top},
  {x:box.right+gap,y:box.bottom-height},
  {x:box.left-width-gap,y:box.bottom-height},
  {x:box.left,y:box.bottom+gap},
  {x:box.left,y:box.top-height-gap}
 ];
 const pick=candidates.find(p=>fits(p.x,p.y)&&!hits(p.x,p.y))||candidates.find(p=>fits(p.x,p.y))||{x:innerWidth-width-margin,y:58};
 const x=Math.max(margin,Math.min(pick.x,innerWidth-width-margin)),y=Math.max(58,Math.min(pick.y,innerHeight-height-margin));
 panel.style.left=x+'px';panel.style.top=y+'px';
}
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&selectedNotes.size&&!selected&&!document.querySelector('.node-menu')){selectedNotes.clear();render({selection:true});e.preventDefault();return;}if(e.key==='Escape'&&document.querySelector('.node-menu')){document.querySelector('.node-menu').remove();e.preventDefault();return;}if(e.key==='Escape'&&controlsOpen){controlsOpen=false;document.querySelector('.map-toolbar').hidden=true;document.querySelector('.map-controls-toggle').setAttribute('aria-expanded','false');e.preventDefault();return;}if(e.key==='Escape'&&!document.querySelector('dialog')&&selected){e.preventDefault();closePopup();return;}if((e.metaKey||e.ctrlKey)&&!e.altKey&&e.key.toLowerCase()==='z'&&!e.isComposing){if(e.target.closest('input,textarea,select,.tiptap,[contenteditable="true"]'))return;e.preventDefault();travelMoves(!e.shiftKey);}});
document.addEventListener('pointerdown',e=>{if(!e.target.closest('.node-menu'))document.querySelector('.node-menu')?.remove();if(controlsOpen&&!e.target.closest('.map-toolbar,.map-controls-toggle')){controlsOpen=false;document.querySelector('.map-toolbar').hidden=true;document.querySelector('.map-controls-toggle').setAttribute('aria-expanded','false');}if(selected&&!e.target.closest('.map-popup,.note-completions,dialog,[role="button"],button'))closePopup();});
window.addEventListener('resize',()=>{const popup=document.querySelector('.map-popup');if(popup)placePopup(popup);requestCamera('commit');});
const mapView={labels:new Map(),layers:[],baked:{x:0,y:0,z:1},hover:0,pinned:new Set()};
function worldView(){
 const viewport=mapView.viewport;if(!viewport)return {vw:1,vh:1,vx:0,vy:0,ww:1,wh:1,z:zoom,date:{x:0,y:0,w:1,h:32}};
 const vw=Math.max(1,viewport.clientWidth),vh=Math.max(1,viewport.clientHeight),cam=mapCamera(viewport.scrollLeft,viewport.scrollTop,zoom,vw,vh);
 return {vw,vh,vx:cam.x,vy:cam.y,ww:cam.w,wh:cam.h,z:zoom,date:cam.date};
}
const LANE_WIDTH=168;
function timelineYAt(projectID,x){
 const layout=mapView.layout;if(!layout)return null;
 let y=null;
 for(const edge of data.doc.edges){
  if(edge.project!==projectID)continue;
  const pts=layout.edgePoints.get(edge.id);if(!pts||pts.length<2)continue;
  const minX=Math.min(...pts.map(p=>p.x)),maxX=Math.max(...pts.map(p=>p.x));
  if(x<minX-1||x>maxX+1)continue;
  for(let i=0;i<pts.length-1;i++){
   const a=pts[i],b=pts[i+1],lo=Math.min(a.x,b.x),hi=Math.max(a.x,b.x);
   if(x<lo-0.5||x>hi+0.5)continue;
   y=timelineCurveY(a,b,x,a.kind==='start');
  }
 }
 return y;
}
function paintLanes(){
 const layout=mapView.layout,lanes=mapView.lanes,host=mapView.laneLabels;if(!layout||!lanes||!host||!data?.doc)return;
 const v=worldView(),z=v.z,font=12/z,pad=6/z,edgeX=v.vx+8/z;
 mapView.laneBg.setAttribute('fill','none');mapView.laneEdge.setAttribute('d','');
 host.replaceChildren();
 const used=[];
 for(const project of data.doc.projects){
  const start=layout.points.get(project.route[0]);if(!start)continue;
  if(start.x>=v.vx-4)continue;
  const y=timelineYAt(project.id,edgeX);if(y==null||y<v.vy-20||y>v.vy+v.wh+20)continue;
  let gy=y;
  for(const other of used)if(Math.abs(other-gy)<18/z)gy=other+(gy>=other?18/z:-18/z);
  used.push(gy);
  const label=svg('text',{x:10/z,y:gy+4/z,class:'lane-project','font-size':font,fill:project.color},project.title);
  host.append(label);
  const width=Math.max(24/z,(label.getComputedTextLength?.()||project.title.length*7/z));
  const chip=svg('rect',{x:10/z-pad,y:gy-11/z,width:width+pad*2,height:18/z,rx:4/z,class:'lane-chip'});
  host.insertBefore(chip,label);
 }
}
function paintGrid(){
 const layout=mapView.layout,grid=mapView.grid,bounds=mapView.bounds,yearLabel=mapView.yearLabel;if(!layout||!grid)return;
 const v=worldView(),stride=dateLabelStride(v.z),firstX=layout.tickAt(0).x,last=layout.tickCount-1,bar=32/v.z,labelY=23/v.z,font=12/v.z;
 let i=Math.max(0,Math.min(last,Math.floor((v.vx-firstX)/layout.scale)));
 const start=i,shown=new Set();let d='',bd='';
 for(;i<=last;i++){
  const tick=layout.tickAt(i);if(tick.x>v.vx+v.ww+1)break;
  d+=`M${tick.x} 0V${mapView.height}`;bd+=`M${tick.x} 0V${bar}`;
  if(i%stride||i===last)continue;
  const next=i+1<=last?layout.tickAt(i+1):tick,center=(tick.x+next.x)/2;if(center-v.vx<72/v.z)continue;
  shown.add(tick.date);let lab=mapView.labels.get(tick.date);
  if(!lab){lab=svg('text',{class:'date-label','text-anchor':'middle','aria-label':tick.date},tick.label);mapView.dateLabels.append(lab);mapView.labels.set(tick.date,lab);}
  lab.setAttribute('x',center);lab.setAttribute('y',labelY);lab.setAttribute('font-size',font);lab.style.display='';
 }
 const key=start+'|'+i+'|'+stride+'|'+(v.ww|0)+'|'+v.z.toFixed(3);
 if(mapView.gridKey!==key){
  for(const [date,lab] of mapView.labels)if(!shown.has(date))lab.style.display='none';
  grid.setAttribute('d',d);bounds.setAttribute('d',bd);mapView.gridKey=key;
 }
 yearLabel.setAttribute('x',v.vx+12/v.z);yearLabel.setAttribute('y',labelY);yearLabel.setAttribute('font-size',font);yearLabel.style.display=layout.unit==='year'?'none':'';
 if(layout.unit!=='year')yearLabel.textContent=layout.dateAt(Math.max(layout.x(dateString(layout.start)),Math.min(layout.x(dateString(layout.end)),v.vx))).slice(0,4);
}
function cullLayers(){
 if(mapView.cullPaused)return;
 const v=worldView(),pad=180/v.z,l=v.vx-pad,r=v.vx+v.ww+pad,t=v.vy-pad,b=v.vy+v.wh+pad;
 for(const item of mapView.layers){
  const hide=(item.x2??item.x)<l||(item.x1??item.x)>r||(item.y2??item.y)<t||(item.y1??item.y)>b;
  if(item.hidden!==hide){item.hidden=hide;if(hide)item.el.setAttribute('display','none');else item.el.removeAttribute('display');}
 }
}
function showAllLayers(){for(const item of mapView.layers){if(item.hidden){item.hidden=false;item.el.removeAttribute('display');}}}
function commitCamera(){
 const viewport=mapView.viewport,canvas=mapView.canvas,dateLabels=mapView.dateLabels;if(!viewport||!canvas)return;
 if(mapView.zoomLive!=null&&mapView.zoomLive!==zoom){
  const anchor=mapView.zoomAnchor??{x:viewport.clientWidth/2,y:viewport.clientHeight/2};
  const world={x:(viewport.scrollLeft+anchor.x)/zoom,y:(viewport.scrollTop+anchor.y)/zoom};
  zoom=mapView.zoomLive;mapView.zoomLive=null;
  mapView.sizer.style.width=mapView.width*zoom+'px';mapView.sizer.style.height=mapView.height*zoom+'px';
  viewport.scrollLeft=world.x*zoom-anchor.x;viewport.scrollTop=world.y*zoom-anchor.y;
 }
 mapView.zooming=false;
 const v=worldView();
 if(mapView.sizedW!==v.vw||mapView.sizedH!==v.vh){
  mapView.sizedW=v.vw;mapView.sizedH=v.vh;
  canvas.setAttribute('width',v.vw);canvas.setAttribute('height',v.vh);
  canvas.style.width=v.vw+'px';canvas.style.height=v.vh+'px';
  dateLabels.setAttribute('width',v.vw);dateLabels.style.width=v.vw+'px';
  if(mapView.lanes){mapView.lanes.setAttribute('height',v.vh);mapView.lanes.style.height=v.vh+'px';}
 }
 canvas.style.transform='';dateLabels.style.transform='';canvas.style.willChange='';dateLabels.style.willChange='';
 if(mapView.lanes)mapView.lanes.style.transform='';
 if(mapView.camera){mapView.camera.style.transform='';mapView.camera.style.willChange='';}
 setViewBox(canvas,v.vx,v.vy,v.ww,v.wh);
 setViewBox(dateLabels,v.vx,0,v.ww,v.date.h);
 if(mapView.lanes)setViewBox(mapView.lanes,0,v.vy,LANE_WIDTH/v.z,v.wh);
 mapView.baked={x:viewport.scrollLeft,y:viewport.scrollTop,z:zoom};
 paintGrid();paintLanes();cullLayers();
}
function livePan(){
 if(mapView.zooming||mapView.cullPaused)return;
 const viewport=mapView.viewport,baked=mapView.baked,dx=baked.x-viewport.scrollLeft,dy=baked.y-viewport.scrollTop;
 mapView.canvas.style.transform=`translate(${dx}px, ${dy}px)`;
 mapView.dateLabels.style.transform=`translate(${dx}px, 0)`;
 if(mapView.lanes){
  const v=worldView();
  mapView.lanes.style.transform='';
  setViewBox(mapView.lanes,0,v.vy,LANE_WIDTH/v.z,v.wh);
  paintLanes();
 }
 if(Math.abs(dx)>viewport.clientWidth*.4||Math.abs(dy)>viewport.clientHeight*.4)commitCamera();
}
function requestCamera(mode){
 if(mode==='commit'){
  if(mapView.cameraFrame){cancelAnimationFrame(mapView.cameraFrame);mapView.cameraFrame=0;}
  clearTimeout(mapView.commitTimer);
  mapView.cameraFrame=requestAnimationFrame(()=>{mapView.cameraFrame=0;commitCamera();});
  return;
 }
 if(mapView.cameraFrame)return;
 mapView.cameraFrame=requestAnimationFrame(()=>{
  mapView.cameraFrame=0;livePan();
  clearTimeout(mapView.commitTimer);
  mapView.commitTimer=setTimeout(()=>commitCamera(),80);
 });
}
function setZoom(value,anchor,opts={}){
 const viewport=mapView.viewport;if(!viewport)return;
 const next=Math.max(.15,Math.min(3,value)),point=anchor??{x:viewport.clientWidth/2,y:viewport.clientHeight/2};
 if(opts.live){
  mapView.zoomLive=next;mapView.zoomAnchor=point;mapView.zooming=true;
  const scale=next/zoom,cam=mapView.camera;
  cam.style.willChange='transform';cam.style.transformOrigin=`${point.x}px ${point.y}px`;cam.style.transform=`scale(${scale})`;
  clearTimeout(mapView.zoomTimer);mapView.zoomTimer=setTimeout(()=>setZoom(mapView.zoomLive,mapView.zoomAnchor),50);
  return;
 }
 if(next===zoom&&!mapView.zooming&&mapView.zoomLive==null){commitCamera();return;}
 const world={x:(viewport.scrollLeft+point.x)/zoom,y:(viewport.scrollTop+point.y)/zoom};
 zoom=next;mapView.zoomLive=null;mapView.zooming=false;
 mapView.sizer.style.width=mapView.width*zoom+'px';mapView.sizer.style.height=mapView.height*zoom+'px';
 viewport.scrollLeft=world.x*zoom-point.x;viewport.scrollTop=world.y*zoom-point.y;
 commitCamera();
}
function bindViewport(viewport){
 if(mapView.bound===viewport)return;
 mapView.bound=viewport;
 viewport.addEventListener('scroll',()=>{if(!mapView.zooming&&!mapView.cullPaused)requestCamera('live');},{passive:true});
 viewport.addEventListener('wheel',e=>{if(e.metaKey||e.ctrlKey){e.preventDefault();const rect=viewport.getBoundingClientRect();setZoom((mapView.zoomLive??zoom)*Math.exp(-e.deltaY*.01),{x:e.clientX-rect.left-viewport.clientLeft,y:e.clientY-rect.top-viewport.clientTop},{live:true});}},{passive:false});
 if(mapView.ro)mapView.ro.disconnect();
 mapView.ro=new ResizeObserver(()=>{if(viewport.clientWidth===mapView.sizedW&&viewport.clientHeight===mapView.sizedH)return;requestCamera('commit');});mapView.ro.observe(viewport);
}
function trackLayer(el,box){mapView.layers.push({el,hidden:false,...box});}
function applyNoteTitles(){mapView.canvas?.classList.toggle('hide-note-titles',!showNoteTitles);}
function settleDrag(){
 const from=mapView.settleFrom;mapView.settleFrom=null;if(!from||!mapView.canvas||!mapView.layout)return;
 const canvas=mapView.canvas,layout=mapView.layout,items=[];
 for(const [id,last] of from){
  const group=canvas.querySelector('[data-node-id="'+id+'"]'),p=layout.points.get(id)??layout.notePoints.get(id);
  if(!group||!p)continue;const dx=last.x-p.x,dy=last.y-p.y;if(Math.hypot(dx,dy)<.5)continue;
  group.setAttribute('transform',`translate(${dx} ${dy})`);items.push({group,dx,dy});
 }
 if(!items.length)return;
 if(matchMedia('(prefers-reduced-motion: reduce)').matches){for(const it of items)it.group.removeAttribute('transform');return;}
 const t0=performance.now(),dur=220;
 const tick=now=>{const t=Math.min(1,(now-t0)/dur),e=1-Math.pow(1-t,3),s=1-e;
  for(const it of items)it.group.setAttribute('transform',`translate(${it.dx*s} ${it.dy*s})`);
  if(t<1)requestAnimationFrame(tick);else for(const it of items)it.group.removeAttribute('transform');
 };
 requestAnimationFrame(tick);
}
function resetGraphLayers(){
 mapView.layers=[];mapView.labels.clear();mapView.gridKey='';mapView.hover=0;
 if(mapView.canvas){mapView.canvas.replaceChildren();mapView.canvas.classList.remove('notes-hover');mapView.hovered=null;}
 if(mapView.dateLabels)mapView.dateLabels.replaceChildren(mapView.bounds,mapView.yearLabel);
}
function ensureViewport(){
 if(mapView.viewport?.isConnected)return mapView;
 mapView.bound=null;mapView.sizedW=0;mapView.sizedH=0;
 const viewport=el('div',null,'map-viewport'),content=el('div',null,'map-content'),camera=el('div',null,'map-camera');
 const dateLabels=svg('svg',{class:'map-dates',height:32,preserveAspectRatio:'none','aria-label':'Timeline dates'});
 const yearLabel=svg('text',{x:12,y:23,class:'date-year','aria-label':'Timeline year'});
 const grid=svg('path',{class:'date-grid',fill:'none'}),bounds=svg('path',{class:'date-boundary',fill:'none'});
 const lanes=svg('svg',{class:'map-lanes',width:LANE_WIDTH,preserveAspectRatio:'none','aria-label':'Priority lanes'});
 const laneBg=svg('rect',{class:'lane-bg'}),laneEdge=svg('path',{class:'lane-edge',fill:'none'}),laneLabels=svg('g',{class:'lane-labels'});
 const canvas=svg('svg',{class:'map-canvas',role:'group',preserveAspectRatio:'none','aria-label':'Project timeline'}),sizer=el('div',null,'map-sizer');
 dateLabels.append(bounds,yearLabel);lanes.append(laneBg,laneEdge,laneLabels);camera.append(dateLabels,canvas,lanes);viewport.append(camera,sizer);content.append(viewport);
 Object.assign(mapView,{viewport,content,camera,dateLabels,yearLabel,grid,bounds,canvas,sizer,lanes,laneBg,laneEdge,laneLabels,labels:new Map(),layers:[]});
 bindViewport(viewport);return mapView;
}
function render({selection=false}={}){
 if(!data?.doc)return;
 const retained=embedded&&embedded.id===selected?.id&&(embedded.dirty||embedded.lastDraft===data.texts[embedded.name]);const preserved=retained?document.querySelector('.map-popup'):null;if(!preserved&&embedded){clearTimeout(embedded.timer);embedded.destroy();embedded=null;}
 if(selection&&mapView.canvas?.isConnected&&mapView.layout){
  const layout=mapView.layout,links=mapView.links,canvas=mapView.canvas,doc=data.doc,detail=el('section',null,'map-popup');
  canvas.querySelectorAll('.selected').forEach(n=>n.classList.remove('selected'));
  canvas.querySelectorAll('.link-leaf').forEach(n=>n.remove());
  if(selected?.id)canvas.querySelector('[data-node-id="'+selected.id+'"]')?.classList.add('selected');
  const focusedNote=layout.notePoints.get(selected?.id)??layout.points.get(selected?.id),leaves=focusedNote?links.leaves.get(focusedNote.id)??[]:[];
  if(focusedNote)leaves.forEach((link,i)=>{const x=focusedNote.x+35,y=focusedNote.y+35+i*25,g=svg('g',{class:'link-leaf','data-link-id':link.id});g.append(svg('polyline',{points:focusedNote.x+','+focusedNote.y+' '+x+','+y,class:'weak-line',fill:'none',stroke:'#b8bdc4'}),svg('circle',{cx:x,cy:y,r:2.5}),svg('text',{x:x+8,y:y+4},link.label.length>45?link.label.slice(0,44)+'…':link.label));g.setAttribute('tabindex','0');g.setAttribute('role','button');g.setAttribute('aria-label','Open '+link.label);g.onclick=e=>{e.stopPropagation();openLink(link.url,focusedNote);};(canvas.querySelector('[data-node-id="'+focusedNote.id+'"]')??canvas).append(g);});
  const chosen=selected?.kind==='edge'?doc.edges.find(e=>e.id===selected.id):selected?.kind==='anchor'?doc.anchors.find(a=>a.id===selected.id):doc.notes.find(n=>n.id===selected?.id);
  document.querySelectorAll('.map-popup').forEach(p=>{if(p!==preserved)p.remove();});
  if(chosen&&selected.kind==='edge'){const a=layout.points.get(chosen.from),b=layout.points.get(chosen.to);const heading=el('div',null,'popup-heading');heading.append(el('h2',a.title+' → '+b.title),el('span',null,'spacer'),iconButton('close','Close',closePopup));detail.append(heading,el('p',a.date+' — '+b.date,'muted'),button('Add work note',()=>addWork({kind:'edge',id:chosen.id})),button('Attach device notes',()=>attachDevice({kind:'edge',id:chosen.id})));detail.append(button('Add milestone',()=>newMilestone(chosen.from,chosen.id)),button('Disconnect milestones',async()=>{try{await applyChange(()=>disconnectMilestones(data.doc,chosen.id));selected=null;render();}catch(e){notice(e.message);}}));}
  else if(chosen&&!preserved){noteDetails(detail,chosen);if(selected.kind==='anchor'){detail.append(button('Add memo',()=>addWork({kind:'anchor',id:chosen.id})));detail.append(button('Add milestone',()=>newMilestone(chosen.id)));}}
  if(chosen){detail.setAttribute('role','dialog');detail.setAttribute('aria-label',selected.kind==='edge'?'Segment actions':chosen.title);const popup=preserved??detail;if(preserved)preserved.querySelector('.popup-heading h2').textContent=chosen.device?chosen.title:'';if(!preserved)main.append(popup);placePopup(popup);}
  publishSelection();
  return;
 }
 stopMotion();stopGestures();
 let layout,links,degrees;
 try{layout=layoutMap(data.doc,{unit:dateUnit,priorityGap,noteTension});links=graphLinks(data.doc,data.texts);degrees=nodeDegrees(data.doc,links);}
 catch(e){notice(e.message);return;}
 const reuse=mapView.viewport?.isConnected;if(reuse&&!fitNext)camera={x:mapView.viewport.scrollLeft,y:mapView.viewport.scrollTop};
 if(!reuse){if(preserved){for(const child of [...main.children])if(child!==preserved)child.remove();}else main.replaceChildren();ensureViewport();}
 else{resetGraphLayers();document.querySelector('.map-empty')?.remove();mapView.add?.remove();mapView.toggle?.remove();mapView.toolbar?.remove();for(const popup of document.querySelectorAll('.map-popup'))if(popup!==preserved)popup.remove();}
 const doc=data.doc,floating=[],movingEdges=[],timelineShapes=[],toolbar=el('header',null,'map-toolbar'),name=el('strong',doc.title),viewport=mapView.viewport,content=mapView.content,canvas=mapView.canvas,sizer=mapView.sizer,detail=el('section',null,'map-popup');
 mapView.layout=layout;mapView.links=links;main.style.setProperty('--edge-scale',edgeScale);
 toolbar.append(name,el('span',doc.projects.length+' projects · '+(doc.anchors.length+doc.notes.length)+' notes','muted'));
 toolbar.id='map-controls';toolbar.setAttribute('role','dialog');toolbar.setAttribute('aria-label','Map controls');toolbar.hidden=!controlsOpen;
 const toggle=iconButton('sliders','Map controls',()=>{controlsOpen=!controlsOpen;toolbar.hidden=!controlsOpen;toggle.setAttribute('aria-expanded',String(controlsOpen));});toggle.classList.add('map-controls-toggle');toggle.setAttribute('aria-expanded',String(controlsOpen));toggle.setAttribute('aria-controls','map-controls');
 const history=iconButton('history','Show disconnected milestones',()=>{showHistory=!showHistory;persistView();render();});history.setAttribute('aria-pressed',String(showHistory));const find=input(search,'search');find.placeholder='Find notes';find.setAttribute('aria-label','Find notes');find.oninput=()=>{search=find.value;canvas.querySelectorAll('[data-search]').forEach(n=>n.classList.toggle('dimmed',!!search&&!n.dataset.search.toLocaleLowerCase().includes(search.toLocaleLowerCase())));};
 toolbar.append(find);const controls=el('div',null,'map-control-actions');controls.append(history,iconButton('minus','Zoom out',()=>setZoom(zoom/1.25)),iconButton('plus','Zoom in',()=>setZoom(zoom*1.25)),iconButton('fit','Fit timeline',()=>{setZoom(Math.min(1,(viewport.clientWidth-30)/layout.width),{x:0,y:0});viewport.scrollTo(0,0);commitCamera();}),iconButton('refresh','Refresh map',async()=>{if(await flushNote()){forgetMoves();selected=null;render();send({action:'refresh'});}}));toolbar.append(controls);
 const thickness=input(edgeScale,'range'),thicknessValue=el('output',edgeScale.toFixed(1)+'×'),thicknessLabel=el('label',null,'map-line-width');thickness.min='.5';thickness.max='3';thickness.step='.1';thickness.setAttribute('aria-label','Line thickness');thickness.oninput=()=>{edgeScale=Number(thickness.value);main.style.setProperty('--edge-scale',edgeScale);thicknessValue.textContent=edgeScale.toFixed(1)+'×';persistView();};thicknessLabel.append(el('span','Line thickness'),thickness,thicknessValue);toolbar.append(thicknessLabel);
 const gap=input(priorityGap,'range'),gapValue=el('output',String(priorityGap)),gapLabel=el('label',null,'map-line-width');gap.min=String(PRIORITY_GAP_MIN);gap.max=String(PRIORITY_GAP_MAX);gap.step='4';gap.setAttribute('aria-label','Priority spacing');gap.oninput=()=>{gapValue.textContent=gap.value;};gap.onchange=()=>{priorityGap=clampPriorityGap(gap.value);persistView();render();};gapLabel.append(el('span','Priority spacing'),gap,gapValue);toolbar.append(gapLabel);
 const pull=input(noteTension,'range'),pullValue=el('output',String(noteTension)),pullLabel=el('label',null,'map-line-width');pull.min=String(NOTE_TENSION_MIN);pull.max=String(NOTE_TENSION_MAX);pull.step='1';pull.setAttribute('aria-label','Note spacing');pull.oninput=()=>{pullValue.textContent=pull.value;};pull.onchange=()=>{noteTension=clampNoteTension(pull.value);persistView();render();};pullLabel.append(el('span','Note spacing'),pull,pullValue);toolbar.append(pullLabel);
 const names=button('Show names');names.setAttribute('aria-pressed',String(showNoteTitles));names.setAttribute('aria-label','Show note names');names.onclick=()=>{showNoteTitles=!showNoteTitles;names.setAttribute('aria-pressed',String(showNoteTitles));applyNoteTitles();persistView();};
 const namesLabel=el('label',null,'map-date-unit');namesLabel.append(el('span','Note names'),names);toolbar.append(namesLabel);
 const unit=select([['day','Day'],['week','Week'],['month','Month'],['year','Year']],dateUnit),unitLabel=el('label',null,'map-date-unit');unit.setAttribute('aria-label','Date scale');unit.onchange=()=>{focusDate=layout.dateAt((viewport.scrollLeft+Math.min(120,viewport.clientWidth*.25))/zoom);dateUnit=unit.value;persistView();render();};unitLabel.append(el('span','Date scale'),unit);toolbar.append(unitLabel);
 const add=iconButton('plus','Add timeline',sampleProject);add.classList.add('map-add-timeline');
 mapView.add=add;mapView.toggle=toggle;mapView.toolbar=toolbar;
 if(!content.isConnected)main.append(add,toggle,toolbar,content);else{main.insertBefore(add,content);main.insertBefore(toggle,content);main.insertBefore(toolbar,content);}
 if(fitNext||!camera)zoom=Math.min(1,Math.max(.15,(viewport.clientWidth-24)/layout.width));
 fitNext=false;
 const focusedNote=layout.notePoints.get(selected?.id)??layout.points.get(selected?.id),leaves=focusedNote?links.leaves.get(focusedNote.id)??[]:[];
 const width=Math.max(layout.width,focusedNote?focusedNote.x+430:0),height=Math.max(layout.height,focusedNote?focusedNote.y+60+leaves.length*25:0);
 mapView.width=width;mapView.height=height;applyNoteTitles();
 const todayBounds=layout.dateBounds(today());canvas.append(svg('rect',{x:todayBounds.left,y:0,width:Math.max(0,todayBounds.right-todayBounds.left),height,class:'today-column'}));
 canvas.append(mapView.grid);
 sizer.style.width=width*zoom+'px';sizer.style.height=height*zoom+'px';
 const laneGap=layout.priorityY(2)-layout.priorityY(1),lanes=Math.max(1,doc.projects.length)+1;
 canvas.append(svg('path',{d:Array.from({length:lanes},(_,i)=>`M0 ${layout.priorityY(i+1)-laneGap/2}H${width}`).join(''),class:'priority-grid',fill:'none'}));
 const projects=new Map(doc.projects.map(p=>[p.id,p])),active=mainMilestoneIDs(doc);
 const choose=async value=>{if(!await flushNote())return;selectedNotes.clear();selected=value;render({selection:true});};
 const interactive=(node,label,click)=>{node.setAttribute('tabindex','0');node.setAttribute('role','button');node.setAttribute('aria-label',label);node.onclick=e=>{e.stopPropagation();const r=node.getBoundingClientRect();popupPoint={x:e.clientX||r.x+r.width/2,y:e.clientY||r.y+r.height/2};click(e);};node.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();const r=node.getBoundingClientRect();popupPoint={x:r.x+r.width/2,y:r.y+r.height/2};click(e);}};};
 function line(points,cls,color){return svg('polyline',{points:points.map(p=>p.x+','+p.y).join(' '),class:cls,fill:'none',stroke:color});}
 function movingLine(from,to,cls,color){const element=line([from,to],cls,color);movingEdges.push({from,to,line:element});trackLayer(element,{x1:Math.min(from.x,to.x),y1:Math.min(from.y,to.y),x2:Math.max(from.x,to.x),y2:Math.max(from.y,to.y)});return element;}
 function timelineLine(points,cls,color,straight){const element=svg('path',{d:edgePath(points,straight),class:cls,fill:'none',stroke:color});timelineShapes.push({points,rest:points.map(p=>({x:p.x,y:p.y})),element,straight:!!straight,from:points[0].id,to:points.at(-1).id,live:!cls.includes('edge-hit')});const xs=points.map(p=>p.x),ys=points.map(p=>p.y);trackLayer(element,{x1:Math.min(...xs),y1:Math.min(...ys),x2:Math.max(...xs),y2:Math.max(...ys)});return element;}
 for(const edge of doc.edges){const points=layout.edgePoints.get(edge.id),stem=layout.points.get(edge.from).kind==='start';
 const color=projects.get(edge.project).color,visible=timelineLine(points,'timeline-edge active'+(stem?' start-stem':''),color,stem);canvas.append(visible);const hit=timelineLine(points,'edge-hit','transparent',stem);hit.dataset.edgeId=edge.id;interactive(hit,'Segment: '+layout.points.get(edge.from).title+' to '+layout.points.get(edge.to).title,()=>choose({kind:'edge',id:edge.id}));hit.oncontextmenu=e=>edgeMenu(e,edge);canvas.append(hit);
 }
 for(const connection of links.connections){const a=layout.points.get(connection.from)??layout.notePoints.get(connection.from),b=layout.points.get(connection.to)??layout.notePoints.get(connection.to);if(!a||!b)continue;canvas.append(movingLine(a,b,'weak-line note-connection','#788ca5'));}
 for(const anchor of doc.anchors){const ghost=!active.has(anchor.id);if(ghost&&!showHistory)continue;const p=layout.points.get(anchor.id),radius=nodeRadius(anchor.kind,degrees.get(anchor.id)),group=svg('g',{class:'anchor '+(ghost?'ghost':'')+(selected?.id===anchor.id?' selected':''),'data-node-id':anchor.id,'data-search':anchor.title});group.append(svg('circle',{cx:p.x,cy:p.y,r:radius,fill:projects.get(anchor.project).color}),svg('text',{x:p.x+radius+5,y:p.y-12,class:'anchor-title'},anchor.title));interactive(group,anchor.title,()=>choose({kind:'anchor',id:anchor.id}));const port=svg('circle',{cx:p.x,cy:p.y+radius+9,r:3.5,class:'connection-handle','aria-label':'Drag to connect milestone'});port.append(svg('title',{},'Drag to connect another milestone'));group.append(port);group.oncontextmenu=e=>nodeMenu(e,anchor);canvas.append(group);trackLayer(group,{x:p.x,y:p.y});}
 for(const device of layout.devices.values()){const label=doc.devices.find(d=>d.id===device.device)?.label??'Device';const stem=line([device.origin,device],'weak-line','#a5abb4'),text=svg('text',{x:device.x+10,y:device.y,class:'device-label'},'▣ '+label);canvas.append(stem,text);trackLayer(stem,{x1:Math.min(device.origin.x,device.x),y1:Math.min(device.origin.y,device.y),x2:Math.max(device.origin.x,device.x),y2:Math.max(device.origin.y,device.y)});trackLayer(text,{x:device.x,y:device.y});}
 for(const note of layout.notePoints.values()){const radius=nodeRadius('note',degrees.get(note.id)),group=svg('g',{class:'work-note'+(selected?.id===note.id?' selected':'')+(selectedNotes.has(note.id)?' multi-selected':''),'data-node-id':note.id,'aria-pressed':String(selectedNotes.has(note.id)),'data-search':note.title+' '+note.note}),dot=svg('circle',{cx:note.x,cy:note.y,r:radius,class:'work-dot'});canvas.append(movingLine(note.origin,note,'weak-line attachment-line','#a5abb4'));group.append(dot,svg('text',{x:note.x+radius+5,y:note.y+4,class:'work-title'},note.title));interactive(group,note.title,e=>{if(e.metaKey||e.ctrlKey){if(selectedNotes.has(note.id))selectedNotes.delete(note.id);else selectedNotes.add(note.id);group.classList.toggle('multi-selected',selectedNotes.has(note.id));group.setAttribute('aria-pressed',String(selectedNotes.has(note.id)));}else choose({kind:'note',id:note.id});});group.oncontextmenu=e=>nodeMenu(e,note);dot.addEventListener('pointerenter',()=>{if(mapView.hovered===group)return;mapView.hovered?.classList.remove('title-hover');mapView.hovered=group;group.classList.add('title-hover');canvas.classList.add('notes-hover');});dot.addEventListener('pointerleave',()=>{if(mapView.hovered!==group)return;group.classList.remove('title-hover');mapView.hovered=null;canvas.classList.remove('notes-hover');});canvas.append(group);trackLayer(group,{x:note.x,y:note.y});floating.push({id:note.id,x:note.x,y:note.y,point:note,group,origin:note.origin,orbit:note.orbit??0});
 }
 if(focusedNote){leaves.forEach((link,i)=>{const x=focusedNote.x+35,y=focusedNote.y+35+i*25,g=svg('g',{class:'link-leaf','data-link-id':link.id});g.append(line([focusedNote,{x,y}],'weak-line','#b8bdc4'),svg('circle',{cx:x,cy:y,r:2.5}),svg('text',{x:x+8,y:y+4},link.label.length>45?link.label.slice(0,44)+'…':link.label));interactive(g,'Open '+link.label,()=>openLink(link.url,focusedNote));(floating.find(n=>n.id===focusedNote.id)?.group??canvas).append(g);});}
 if(!doc.projects.length){const empty=el('div',null,'map-empty');empty.append(el('h2','Give your projects a timeline'),el('p','Start with a project and its milestones. Work notes attach to the time between them.'),button('Create first project',sampleProject,'primary'));viewport.append(empty);}
 const chosen=selected?.kind==='edge'?doc.edges.find(e=>e.id===selected.id):selected?.kind==='anchor'?doc.anchors.find(a=>a.id===selected.id):doc.notes.find(n=>n.id===selected?.id);
 if(chosen&&selected.kind==='edge'){const a=layout.points.get(chosen.from),b=layout.points.get(chosen.to);const heading=el('div',null,'popup-heading');heading.append(el('h2',a.title+' → '+b.title),el('span',null,'spacer'),iconButton('close','Close',closePopup));detail.append(heading,el('p',a.date+' — '+b.date,'muted'),button('Add work note',()=>addWork({kind:'edge',id:chosen.id})),button('Attach device notes',()=>attachDevice({kind:'edge',id:chosen.id})));detail.append(button('Add milestone',()=>newMilestone(chosen.from,chosen.id)),button('Disconnect milestones',async()=>{try{await applyChange(()=>disconnectMilestones(data.doc,chosen.id));selected=null;render();}catch(e){notice(e.message);}}));}
 else if(chosen&&!preserved){noteDetails(detail,chosen);if(selected.kind==='anchor'){detail.append(button('Add memo',()=>addWork({kind:'anchor',id:chosen.id})));detail.append(button('Add milestone',()=>newMilestone(chosen.id)));}}
 if(chosen){detail.setAttribute('role','dialog');detail.setAttribute('aria-label',selected.kind==='edge'?'Segment actions':chosen.title);const popup=preserved??detail;if(preserved)preserved.querySelector('.popup-heading h2').textContent=chosen.device?chosen.title:'';if(!preserved)main.append(popup);placePopup(popup);}
 if(focusDate){viewport.scrollLeft=Math.max(0,layout.x(focusDate)*zoom-Math.min(120,viewport.clientWidth*.25));focusDate=null;}
 else if(camera){viewport.scrollLeft=camera.x;viewport.scrollTop=camera.y;}
 mapView.floating=floating;mapView.movingEdges=movingEdges;mapView.timelineShapes=timelineShapes;mapView.hover=0;
 commitCamera();if(search)find.oninput();
 settleDrag();
 mapView.pinned.clear();
 const resumeMotion=()=>{mapView.cullPaused=false;stopMotion();if(!viewActive)return;stopMotion=animateNotes({canvas,viewport,notes:floating,edges:movingEdges,zoom:()=>zoom,tension:noteTension,pinned:mapView.pinned});};resumeMotion();
 stopGestures=graphGestures({canvas,viewport,notes:floating,selection:selectedNotes,doc,layout,zoom:()=>zoom,onCamera:commitCamera,pinned:mapView.pinned,onSelect:async()=>{if(!await flushNote()){resumeMotion();return;}selected=null;render({selection:true});},onConnect:async(from,to)=>{try{await applyChange(()=>connectMilestones(data.doc,from,to));}catch(e){notice(e.message);}if(canvas.isConnected)resumeMotion();},preview:(moving)=>{const ids=moving&&moving.size?moving:null;for(const edge of movingEdges){if(ids&&!ids.has(edge.from.id)&&!ids.has(edge.to.id))continue;const points=`${edge.from.x},${edge.from.y} ${edge.to.x},${edge.to.y}`;if(edge.points!==points){edge.points=points;edge.line.setAttribute('points',points);}}for(const edge of timelineShapes){if(!edge.live||ids&&!ids.has(edge.from)&&!ids.has(edge.to))continue;const pts=edge.points,rest=edge.rest,a=pts[0],b=pts.at(-1),a0=rest[0],b0=rest.at(-1);for(let i=1;i<pts.length-1;i++){const t=(rest[i].x-a0.x)/((b0.x-a0.x)||1);pts[i].x=rest[i].x+(a.x-a0.x)+((b.x-b0.x)-(a.x-a0.x))*t;pts[i].y=rest[i].y+(a.y-a0.y)+((b.y-b0.y)-(a.y-a0.y))*t;}edge.element.setAttribute('d',edgePath(pts,edge.straight));}},onReorder:async(id,target,from)=>{mapView.settleFrom=from;try{await applyChange(()=>reorderMilestones(data.doc,id,target));}catch(e){mapView.settleFrom=null;notice(e.message);render();}},onMove:async(ids,days,priority,cascadePriority,preserveGaps,from)=>{mapView.settleFrom=from;try{await applyChange(()=>moveNodes(data.doc,ids,{days,priority,cascadePriority,preserveGaps},data.texts),{links:false});}catch(e){mapView.settleFrom=null;notice(e.message);render();}},pause:()=>{mapView.cullPaused=true;showAllLayers();commitCamera();stopMotion();},resume:resumeMotion});
 publishSelection();
}
window.crowMap={flush:flushNote,setActive(active){viewActive=active;if(!active){stopMotion();document.activeElement?.blur();}else if(data)render();},focusNode(id){if(!data?.doc.anchors.some(a=>a.id===id))return false;viewActive=true;selected={kind:'anchor',id};render();focusTimeline(id);return true;},addSampleProject:sampleProject,renamed(value){const pending=renamePending;renamePending=null;if(value.error){pending?.reject(Error(value.error));return;}if(embedded){clearTimeout(embedded.timer);embedded.destroy();embedded=null;}this.receive(value);pending?.resolve(value.name);},draftError(name,message){if(embedded?.name===name){embedded.blocked=true;embedded.status.textContent=message;}},async refreshDevice(value){
 if(data?.doc.id!==value.mapID||pending)return;
 let doc=structuredClone(data.doc);const device=doc.devices.find(d=>d.hostID===value.hostID);if(!device)return;
 for(const incoming of value.notes){const matches=doc.notes.filter(n=>n.device===device.id&&n.note===incoming.name);for(const n of matches){n.cachedText=incoming.text;n.title=incoming.title;n.date=incoming.date;}
  if(!matches.length){const meta=readNote(incoming.text).meta;let attach;try{attach=resolveAttachment(meta,doc,data.texts)??(meta.crowmap===doc.id?meta.attach:null);}catch{}if(attach&&device.attachments?.some(a=>a.kind===attach.kind&&a.id===attach.id))doc=addNote(doc,{title:incoming.title,date:incoming.date,body:'',attach,device:device.id,note:incoming.name,cachedText:incoming.text}).doc;}
 }
 if(JSON.stringify(doc)!==JSON.stringify(data.doc))await transaction({doc,writes:[]},{forget:true});
 },markdown(id,html){const body=document.querySelector('[data-preview="'+id+'"]');if(!body)return;body.innerHTML=html;const item=[...data.doc.anchors,...data.doc.notes].find(n=>n.id===selected?.id);if(item)markdownCache.set(readNote(textFor(item)).body,html);const popup=body.closest('.map-popup');if(popup)placePopup(popup);},receive(value){try{graphError=null;const cached=JSON.parse(value.source),doc=resolveMap(cached,value.texts??{});
 validateMap(doc);if(!data?.doc.projects.length&&doc.projects.length)fitNext=true;const changed=data?.doc.id!==doc.id;if(changed){selectedNotes.clear();fitNext=true;selected=null;camera=null;zoom=1;forgetMoves();}if(DATE_UNITS.includes(value.dateUnit))dateUnit=value.dateUnit;if(Number.isFinite(value.edgeScale))edgeScale=Math.max(.5,Math.min(3,Number(value.edgeScale)));if(Number.isFinite(value.priorityGap))priorityGap=clampPriorityGap(value.priorityGap);if(Number.isFinite(value.noteTension))noteTension=clampNoteTension(value.noteTension);if(typeof value.showHistory==='boolean')showHistory=value.showHistory;if(typeof value.showNoteTitles==='boolean')showNoteTitles=value.showNoteTitles;main.style.setProperty('--edge-scale',edgeScale);data={...value,doc};render();if(doc.anchors.length&&!pending&&(!doc.noteLinks||['projects','anchors','edges','notes'].some(key=>{const known=new Set(cached[key].map(n=>n.id));return doc[key].some(n=>!known.has(n.id));})))queueMicrotask(()=>{if(!pending)try{transaction({doc:data.doc,writes:[]},{links:!data.doc.noteLinks}).catch(e=>notice(e.message));}catch(e){notice(e.message);}});}catch(e){graphError=e.message;try{data={...value,doc:data?.doc??validateMap(JSON.parse(value.source))};render();}catch{}notice(e.message);}},saved(value){if(!pending)return;const task=pending;pending=null;if(value.error){notice(value.error);task.reject(Error(value.error));}else{if(!task.silent)this.receive(value);task.resolve(value);}},remote(value){document.dispatchEvent(new CustomEvent('crowmap-remote',{detail:value}));},error:notice};

for(const event of ['pointerdown','focusin'])document.addEventListener(event,()=>{if(viewActive)send({action:'focus'});},{passive:true});
