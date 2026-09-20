import {copyNodes,duplicateNodes} from './crowmap-copy.js';
import {fileTitle,renamedNoteSource} from './file-title.js';
import {embeddedNoteEditor} from './crowmap-note-editor.js';
import {linkedTransaction,resolveMap,resolveAttachment,noteResolver,graphLinks,noteLink,deleteWorkNotes,moveNodes,movedDate,timelineNodes,deleteTimeline,patch} from './crowmap-links.js';
import {uid,validateMap,createProject,addMilestone,connectMilestones,disconnectMilestones,mainMilestoneIDs,reorderMilestones,addNote,linkLeaves,layoutMap,readNote,today,day,DATE_UNITS,PRIORITY_GAP,PRIORITY_GAP_MIN,PRIORITY_GAP_MAX,clampPriorityGap} from './crowmap-model.js';
import {editFrontmatter} from './frontmatter-model.js';
import {el,button,input,select,field,dialog,actions,iconButton} from './obsidian-ui.js';
import {animateNotes,nodeDegrees,nodeRadius} from './crowmap-motion.js';
import {graphGestures} from './crowmap-gestures.js';
const send=body=>window.webkit.messageHandlers.crowmap.postMessage(body),main=document.querySelector('main');
const markdownCache=new Map();
let popupPoint={x:100,y:120},previewID=null,embedded=null;
let fitNext=true,controlsOpen=false,viewActive=true;
const selectedNotes=new Set();let stopGestures=()=>{};
function preference(key,fallback){try{const value=Number(localStorage.getItem(key));return Number.isFinite(value)&&value>0?value:fallback;}catch{return fallback;}}
function savePreference(key,value){try{localStorage.setItem(key,String(value));}catch{}}
let edgeScale=Math.max(.5,Math.min(3,preference('crowmap-edge-scale',1))),stopMotion=()=>{};
function loadDateUnit(){try{const value=localStorage.getItem('crowmap-date-unit');if(DATE_UNITS.includes(value))return value;}catch{}return 'day';}
let dateUnit=loadDateUnit(),priorityGap=clampPriorityGap(preference('crowmap-priority-gap',PRIORITY_GAP)),focusDate=null;
const dateString=d=>new Date(d*86400000).toISOString().slice(0,10);
let data,selected=null,zoom=1,showHistory=true,search='',pending=null,camera=null,graphError=null;
let undoStack=[],redoStack=[];
const svgNS='http://www.w3.org/2000/svg';
function svg(tag,attrs={},text){const node=document.createElementNS(svgNS,tag);for(const [k,v]of Object.entries(attrs))node.setAttribute(k,v);if(text!=null)node.textContent=text;return node;}
function notice(message){document.querySelector('.map-error')?.remove();const e=el('div',message,'map-error');e.setAttribute('role','alert');main.prepend(e);}
function forgetMoves(){undoStack=[];redoStack=[];}
function snapshotTexts(names){return Object.fromEntries(names.map(name=>[name,data.texts[name]]).filter(([,text])=>text!=null));}
function restoreWrites(texts){
 const writes=[];
 for(const [name,old] of Object.entries(texts)){
  const current=data.texts[name];if(current==null||current===old)continue;
  const meta=readNote(old).meta,now=readNote(current).meta,values={date:meta.date},remove=[];
  if(meta.priority!=null)values.priority=meta.priority;
  if(Object.hasOwn(meta,'between'))values.between=meta.between;else if(Object.hasOwn(now,'between'))remove.push('between');
  if(Object.hasOwn(meta,'milestone'))values.milestone=meta.milestone;else if(Object.hasOwn(now,'milestone'))remove.push('milestone');
  const text=patch(current,values,remove);if(text!==current)writes.push({name,expected:current,text});
 }
 return writes;
}
async function restoreMove(state){if(!await flushNote())return;await transaction({doc:structuredClone(state.doc),writes:restoreWrites(state.texts)},{links:false});}
async function travelMoves(backwards){
 if(pending||!data||!viewActive)return;
 const from=backwards?undoStack:redoStack,to=backwards?redoStack:undoStack,entry=from.at(-1);if(!entry)return;
 try{await restoreMove(backwards?entry.before:entry.after);from.pop();to.push(entry);render();}catch(e){notice(e.message);render();}
}
async function applyMove(compute){
 if(!await flushNote())return false;
 const before={doc:structuredClone(data.doc),texts:{}};
 const result=compute();
 before.texts=snapshotTexts((result.writes??[]).map(w=>w.name));
 await transaction(result,{links:false});
 undoStack.push({before,after:{doc:structuredClone(data.doc),texts:snapshotTexts(Object.keys(before.texts))}});
 if(undoStack.length>50)undoStack.shift();redoStack=[];
 return true;
}
function transaction(result,{links=true,draftNote=null,forget=false}={}){if(links&&graphError)throw Error('Fix the note links before changing the plan. '+graphError);if(links)result=linkedTransaction(result,data.texts);if(pending)return Promise.reject(Error('Wait for the current change to save.'));validateMap(result.doc);return new Promise((resolve,reject)=>{pending={resolve:()=>{if(forget)forgetMoves();resolve();},reject};send({action:'save',draftNote,source:JSON.stringify(result.doc,null,2)+'\n',expected:data.source,writes:result.writes??[],deletes:result.deletes??[],reads:result.reads??[],deletingProject:result.deletingProject??null});});}
async function sampleProject(){
 if(!await flushNote())return;
 const date=today(),offset=days=>new Date((day(date)+days)*86400000).toISOString().slice(0,10);
 try {const result=createProject(data.doc,{title:'Sample project'+(data.doc.projects.length?' '+(data.doc.projects.length+1):''),date,priority:data.doc.projects.length+1,milestones:[
  {title:'Research',date:offset(7)},{title:'Prototype',date:offset(14)},
  {title:'Build',date:offset(21)},{title:'Release',date:offset(28)}]},Object.keys(data.texts));await transaction(result,{forget:true});selected=null;selectedNotes.clear();render();focusTimeline(result.doc.projects.at(-1).route[0]);}
 catch(e){notice(e.message);}
}
function focusTimeline(id){
 if(!viewActive)return;
 const viewport=document.querySelector('.map-viewport'),node=document.querySelector('[data-node-id="'+id+'"]'),circle=node?.querySelector('circle');if(!viewport||!circle)return;
 viewport.scrollTo({left:Math.max(0,Number(circle.getAttribute('cx'))*zoom-viewport.clientWidth*.25),top:Math.max(0,Number(circle.getAttribute('cy'))*zoom-viewport.clientHeight*.35),behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
 node.focus({preventScroll:true});
}
async function newMilestone(fromID){try{if(!await flushNote())return;const result=addMilestone(data.doc,fromID,Object.keys(data.texts));await transaction(result,{forget:true});selected={kind:'anchor',id:result.doc.anchors.at(-1).id};render();}catch(e){notice(e.message);}}
async function addWork(attach){
 try{if(!await flushNote())return;let date=today();if(attach.kind==='edge'){const edge=data.doc.edges.find(e=>e.id===attach.id),a=data.doc.anchors.find(a=>a.id===edge.from),b=data.doc.anchors.find(a=>a.id===edge.to);date=date<a.date?a.date:date>b.date?b.date:date;}
 const result=addNote(data.doc,{title:'New note',date,body:'',attach},Object.keys(data.texts)),id=result.doc.notes.at(-1).id;
 await transaction(result,{forget:true});selected={kind:'note',id};render();if(viewActive)embedded?.editor.commands.focus('end');
 }catch(e){notice(e.message);}
}
async function linkedNote(item){
 try{if(!await flushNote())return;const result=addNote(data.doc,{title:'New note',date:item.date,body:noteLink(item),attach:item.attach},Object.keys(data.texts)),id=result.doc.notes.at(-1).id;
 await transaction(result,{forget:true});selected={kind:'note',id};render();if(viewActive)embedded?.editor.commands.focus('end');
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
    try{if(data.source!==expected)throw Error('The timeline changed. Close this dialog and review it before deleting.');await transaction(deleteTimeline(data.doc,startID,data.texts),{links:false,forget:true});selected=null;selectedNotes.clear();close();render();}
    catch(e){error.textContent=e.message;}finally{busy=false;submit.disabled=false;cancel.disabled=false;}
   };
   form.addEventListener('keydown',event=>{if(event.key==='Enter'&&!event.isComposing&&event.target!==cancel){event.preventDefault();if(!event.repeat&&!busy)form.requestSubmit(submit);}});
   form.closest('dialog').addEventListener('cancel',event=>{if(busy)event.preventDefault();});
  });modal.querySelector('[data-confirm]').focus();
 }catch(e){notice(e.message);}
}
async function nodeMenu(event,item){
 event.preventDefault();event.stopPropagation();if(!await flushNote())return;
 if(item.kind)selectedNotes.clear();else if(!selectedNotes.has(item.id)){selectedNotes.clear();selectedNotes.add(item.id);}selected=null;render();
 const ids=item.kind?[item.id]:[...selectedNotes],items=data.doc.notes.filter(n=>selectedNotes.has(n.id)),menu=el('section',null,'map-popup node-menu');menu.setAttribute('role','menu');menu.setAttribute('aria-label','Note actions');
 const action=(title,callback)=>{const control=button(title,callback);control.setAttribute('role','menuitem');menu.append(control);return control;};
 action('Copy',()=>{menu.remove();try{const nodes=copyNodes(data.doc,ids);for(const n of nodes)if(data.drafts?.[n.note]&&!n.device)throw Error('Save the selected notes before copying.');send({action:'copyNotes',files:nodes.map(n=>({name:n.note,...(n.device?{text:n.cachedText??''}:{expected:data.texts[n.note]})}))});}catch(e){notice(e.message);}});
 action('Duplicate',async()=>{menu.remove();try{if(graphError)throw Error(graphError);const nodes=copyNodes(data.doc,ids);for(const n of nodes)if(data.drafts?.[n.note]&&!n.device)throw Error('Save the selected notes before duplicating.');const result=duplicateNodes(data.doc,ids,data.texts);await transaction(result,{links:false,forget:true});selectedNotes.clear();for(const id of result.copiedIDs)if(data.doc.notes.some(n=>n.id===id))selectedNotes.add(id);selected=result.copiedIDs.length===1?{kind:item.kind?'anchor':'note',id:result.copiedIDs[0]}:null;render();}catch(e){notice(e.message);}});
 if(item.kind==='start')action('Delete timeline',()=>{menu.remove();confirmTimelineDeletion(item.id);}).classList.add('danger');
 if(!item.kind){
  if(ids.length===1)action('Create linked note',()=>{menu.remove();linkedNote(item);}).disabled=!!item.device;
  for(const provider of data.agentProviders??[])action('Run '+provider.title+' with '+ids.length+' note'+(ids.length===1?'':'s'),()=>{menu.remove();send({action:'runAgent',provider:provider.id,nodeIDs:ids});}).disabled=items.some(n=>n.device);
  action(ids.length>1?'Delete '+ids.length+' notes':item.device?'Remove from map':'Delete note',async()=>{menu.remove();try{await transaction(deleteWorkNotes(data.doc,ids,data.texts),{links:false,forget:true});selectedNotes.clear();render();}catch(e){notice(e.message);}});
 }
 main.append(menu);popupPoint={x:event.clientX,y:event.clientY};placePopup(menu);menu.querySelector('button')?.focus();
}
async function attachDevice(attach){if(!await flushNote())return;dialog('Attach notes from a device',(form,close)=>{const available=data.hosts??[],host=select(available.map(h=>[h.id,h.label]),available[0]?.id??'');const list=el('div',null,'remote-notes');let loaded=[],selectedHost=null;
 form.append(field('Connected device / account',host),button('Load Crowmap notes',()=>{selectedHost=host.value;if(!selectedHost)return;send({action:'remoteNotes',hostID:selectedHost});list.textContent='Reading ~/.crow/crowmap…';}),list);
 const receive=e=>{if(e.detail.hostID!==selectedHost)return;loaded=e.detail.notes??[];list.replaceChildren();if(e.detail.error){list.textContent=e.detail.error;return;}loaded.forEach((n,i)=>{const row=el('label'),check=input('','checkbox');check.dataset.index=i;row.append(check,el('span',n.title+' · '+n.date));list.append(row);});if(!loaded.length)list.textContent='No dated Markdown notes found.';};document.addEventListener('crowmap-remote',receive);
 form.closest('dialog').addEventListener('close',()=>document.removeEventListener('crowmap-remote',receive),{once:true});
 actions(form,close,async()=>{const chosen=[...list.querySelectorAll('input:checked')].map(c=>loaded[Number(c.dataset.index)]);if(!chosen.length)throw Error('Select notes to attach.');let doc=structuredClone(data.doc);let device=doc.devices.find(d=>d.hostID===selectedHost);if(!device){device={id:uid(),hostID:selectedHost,label:available.find(h=>h.id===selectedHost).label};doc.devices.push(device);}device.attachments=[...(device.attachments??[]).filter(a=>a.id!==attach.id),attach];for(const n of chosen){doc=addNote(doc,{title:n.title,date:n.date,body:'',attach,device:device.id,note:n.name,cachedText:n.text}).doc;}await transaction({doc,writes:[]},{forget:true});render();},'Attach notes');});}
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
  let texts={...data.texts,[state.name]:source},doc;
  try{doc=resolveMap(data.doc,texts);}
  catch(error){
    const item=data.doc.anchors.find(a=>a.note===state.name);
    if(!item)throw error;
    const requested=readNote(source).meta.date,clamped=movedDate(data.doc,item.id,requested);
    if(clamped===requested)throw error;
    source=editFrontmatter(source,'date',{value:clamped,type:'date'});
    texts={...data.texts,[state.name]:source};doc=resolveMap(data.doc,texts);
  }
  const previous=data.doc.notes.find(n=>n.note===state.name&&!n.device),next=doc.notes.find(n=>n.note===state.name&&!n.device);
  let result={doc,writes:[{name:state.name,text:source,expected:data.texts[state.name]}]};
  if(previous&&next&&JSON.stringify(previous.attach)!==JSON.stringify(next.attach))result=linkedTransaction(result,texts);
  state.dirty=false;
  try{await transaction(result,{links:false,draftNote:state.name});state.status.textContent='Saved';return true;}
  catch(e){state.dirty=true;throw e;}
 }catch(e){state.status.textContent=e.message;return false;}})();try{return await state.saving;}finally{state.saving=null;}
}
async function closePopup(){if(!await flushNote())return;selected=null;render();}
function placePopup(panel){
 const margin=10,width=panel.offsetWidth,height=panel.offsetHeight;
 let x=popupPoint.x+12,y=popupPoint.y+12;
 if(x+width>innerWidth-margin)x=popupPoint.x-width-12;
 if(y+height>innerHeight-margin)y=popupPoint.y-height-12;
 panel.style.left=Math.max(margin,Math.min(x,innerWidth-width-margin))+'px';panel.style.top=Math.max(58,Math.min(y,innerHeight-height-margin))+'px';
}
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&selectedNotes.size&&!selected&&!document.querySelector('.node-menu')){selectedNotes.clear();render();e.preventDefault();return;}if(e.key==='Escape'&&document.querySelector('.node-menu')){document.querySelector('.node-menu').remove();e.preventDefault();return;}if(e.key==='Escape'&&controlsOpen){controlsOpen=false;document.querySelector('.map-toolbar').hidden=true;document.querySelector('.map-controls-toggle').setAttribute('aria-expanded','false');e.preventDefault();return;}if(e.key==='Escape'&&!document.querySelector('dialog')&&selected){e.preventDefault();closePopup();return;}if((e.metaKey||e.ctrlKey)&&!e.altKey&&e.key.toLowerCase()==='z'&&!e.isComposing){if(e.target.closest('input,textarea,select,.tiptap,[contenteditable="true"]'))return;e.preventDefault();travelMoves(e.shiftKey);}});
document.addEventListener('pointerdown',e=>{if(!e.target.closest('.node-menu'))document.querySelector('.node-menu')?.remove();if(controlsOpen&&!e.target.closest('.map-toolbar,.map-controls-toggle')){controlsOpen=false;document.querySelector('.map-toolbar').hidden=true;document.querySelector('.map-controls-toggle').setAttribute('aria-expanded','false');}if(selected&&!e.target.closest('.map-popup,.note-completions,dialog,[role="button"],button'))closePopup();});
window.addEventListener('resize',()=>{const popup=document.querySelector('.map-popup');if(popup)placePopup(popup);});
function render(){
 stopMotion();stopGestures();
 if(!data?.doc)return;
 let layout,links,degrees;
 try{layout=layoutMap(data.doc,{unit:dateUnit,priorityGap});links=graphLinks(data.doc,data.texts);degrees=nodeDegrees(data.doc,links);}
 catch(e){notice(e.message);return;}
 const retained=embedded&&embedded.id===selected?.id&&(embedded.dirty||embedded.lastDraft===data.texts[embedded.name]);const preserved=retained?document.querySelector('.map-popup'):null;if(!preserved&&embedded){clearTimeout(embedded.timer);embedded.destroy();embedded=null;}const oldViewport=document.querySelector('.map-viewport');if(oldViewport&&!fitNext)camera={x:oldViewport.scrollLeft,y:oldViewport.scrollTop};if(preserved){for(const child of [...main.children])if(child!==preserved)child.remove();}else main.replaceChildren();
 const doc=data.doc,floating=[],movingEdges=[],timelineShapes=[],toolbar=el('header',null,'map-toolbar'),name=el('strong',doc.title),viewport=el('div',null,'map-viewport'),content=el('div',null,'map-content'),detail=el('section',null,'map-popup');
 main.style.setProperty('--edge-scale',edgeScale);
 toolbar.append(name,el('span',doc.projects.length+' projects · '+(doc.anchors.length+doc.notes.length)+' notes','muted'));
 toolbar.id='map-controls';toolbar.setAttribute('role','dialog');toolbar.setAttribute('aria-label','Map controls');toolbar.hidden=!controlsOpen;
 const toggle=iconButton('sliders','Map controls',()=>{controlsOpen=!controlsOpen;toolbar.hidden=!controlsOpen;toggle.setAttribute('aria-expanded',String(controlsOpen));});toggle.classList.add('map-controls-toggle');toggle.setAttribute('aria-expanded',String(controlsOpen));toggle.setAttribute('aria-controls','map-controls');
 const history=iconButton('history','Show disconnected milestones',()=>{showHistory=!showHistory;render();});history.setAttribute('aria-pressed',String(showHistory));const find=input(search,'search');find.placeholder='Find notes';find.setAttribute('aria-label','Find notes');find.oninput=()=>{search=find.value;document.querySelectorAll('[data-search]').forEach(n=>n.classList.toggle('dimmed',!!search&&!n.dataset.search.toLocaleLowerCase().includes(search.toLocaleLowerCase())));};
 toolbar.append(find);const controls=el('div',null,'map-control-actions');controls.append(history,iconButton('minus','Zoom out',()=>setZoom(zoom/1.25)),iconButton('plus','Zoom in',()=>setZoom(zoom*1.25)),iconButton('fit','Fit timeline',()=>{setZoom(Math.min(1,(viewport.clientWidth-30)/layout.width),{x:0,y:0});viewport.scrollTo(0,0);updateTicks();}),iconButton('refresh','Refresh map',async()=>{if(await flushNote()){forgetMoves();selected=null;render();send({action:'refresh'});}}));toolbar.append(controls);
 const thickness=input(edgeScale,'range'),thicknessValue=el('output',edgeScale.toFixed(1)+'×'),thicknessLabel=el('label',null,'map-line-width');thickness.min='.5';thickness.max='3';thickness.step='.1';thickness.setAttribute('aria-label','Line thickness');thickness.oninput=()=>{edgeScale=Number(thickness.value);main.style.setProperty('--edge-scale',edgeScale);thicknessValue.textContent=edgeScale.toFixed(1)+'×';savePreference('crowmap-edge-scale',edgeScale);};thicknessLabel.append(el('span','Line thickness'),thickness,thicknessValue);toolbar.append(thicknessLabel);
 const gap=input(priorityGap,'range'),gapValue=el('output',String(priorityGap)),gapLabel=el('label',null,'map-line-width');gap.min=String(PRIORITY_GAP_MIN);gap.max=String(PRIORITY_GAP_MAX);gap.step='10';gap.setAttribute('aria-label','Priority spacing');gap.oninput=()=>{gapValue.textContent=gap.value;};gap.onchange=()=>{priorityGap=clampPriorityGap(gap.value);savePreference('crowmap-priority-gap',priorityGap);render();};gapLabel.append(el('span','Priority spacing'),gap,gapValue);toolbar.append(gapLabel);
 const unit=select([['day','Day'],['week','Week'],['month','Month'],['year','Year']],dateUnit),unitLabel=el('label',null,'map-date-unit');unit.setAttribute('aria-label','Date scale');unit.onchange=()=>{focusDate=layout.dateAt((viewport.scrollLeft+Math.min(120,viewport.clientWidth*.25))/zoom);dateUnit=unit.value;savePreference('crowmap-date-unit',dateUnit);render();};unitLabel.append(el('span','Date scale'),unit);toolbar.append(unitLabel);
 const add=iconButton('plus','Add timeline',sampleProject);add.classList.add('map-add-timeline');main.append(add,toggle,toolbar,content);content.append(viewport);
 if(fitNext||!camera)zoom=Math.min(1,Math.max(.15,(viewport.clientWidth-24)/layout.width));
 fitNext=false;
 const focusedNote=layout.notePoints.get(selected?.id)??layout.points.get(selected?.id),leaves=focusedNote?links.leaves.get(focusedNote.id)??[]:[];
 const width=Math.max(layout.width,focusedNote?focusedNote.x+430:0),height=Math.max(layout.height,focusedNote?focusedNote.y+60+leaves.length*25:0);
 const dateAxis=el('div',null,'map-date-axis'),dateLabels=svg('svg',{width:width*zoom,height:32,'aria-label':'Timeline dates'}),yearLabel=svg('text',{x:12,y:23,class:'date-year','aria-label':'Timeline year'}),ticks=[];
 dateAxis.style.width=width*zoom+'px';dateAxis.append(dateLabels);if(doc.projects.length)viewport.append(dateAxis);
 const canvas=svg('svg',{width:width*zoom,height:height*zoom,viewBox:`0 0 ${width} ${height}`,role:'group','aria-label':'Project timeline'});viewport.append(canvas);
 function updateTicks(){const left=viewport.scrollLeft;yearLabel.setAttribute('x',left+12);yearLabel.style.display=layout.unit==='year'?'none':'';if(layout.unit!=='year')yearLabel.textContent=layout.dateAt(Math.max(layout.x(dateString(layout.start)),Math.min(layout.x(dateString(layout.end)),left/zoom))).slice(0,4);let previous=-Infinity;for(const tick of ticks){const x=tick.x*zoom,center=tick.center*zoom;tick.label?.setAttribute('x',center);tick.border.setAttribute('x1',x);tick.border.setAttribute('x2',x);if(!tick.label)continue;const visible=center-left>=72&&center-previous>=54;tick.label.style.display=visible?'':'none';if(visible)previous=center;}}
 viewport.addEventListener('scroll',updateTicks,{passive:true});
 function setZoom(value,anchor={x:viewport.clientWidth/2,y:viewport.clientHeight/2}){
  const next=Math.max(.15,Math.min(3,value));if(next===zoom)return;
  // Capture before resizing: shrinking the SVG can clamp the current scroll offset.
  const point={x:(viewport.scrollLeft+anchor.x)/zoom,y:(viewport.scrollTop+anchor.y)/zoom};
  zoom=next;canvas.setAttribute('width',width*zoom);canvas.setAttribute('height',height*zoom);dateAxis.style.width=width*zoom+'px';dateLabels.setAttribute('width',width*zoom);
  viewport.scrollLeft=point.x*zoom-anchor.x;viewport.scrollTop=point.y*zoom-anchor.y;updateTicks();
 }
 viewport.addEventListener('wheel',e=>{if(e.metaKey||e.ctrlKey){e.preventDefault();const rect=viewport.getBoundingClientRect();setZoom(zoom*Math.exp(-e.deltaY*.01),{x:e.clientX-rect.left-viewport.clientLeft,y:e.clientY-rect.top-viewport.clientTop});}},{passive:false});
 for(const [index,tick]of layout.ticks.entries()){
  const next=layout.ticks[index+1],border=svg('line',{y1:0,y2:32,class:'date-boundary','data-date':tick.date});
  canvas.append(svg('line',{x1:tick.x,x2:tick.x,y1:32,y2:layout.height,class:'date-grid'}));dateLabels.append(border);
  let label=null;if(next){label=svg('text',{y:23,class:'date-label','text-anchor':'middle','aria-label':tick.date},tick.label);dateLabels.append(label);}
  ticks.push({x:tick.x,center:next?(tick.x+next.x)/2:tick.x,label,border});
 }dateLabels.append(yearLabel);updateTicks();
 const projects=new Map(doc.projects.map(p=>[p.id,p])),active=mainMilestoneIDs(doc);
 const choose=async value=>{if(!await flushNote())return;selectedNotes.clear();selected=value;render();};
 const interactive=(node,label,click)=>{node.setAttribute('tabindex','0');node.setAttribute('role','button');node.setAttribute('aria-label',label);node.onclick=e=>{e.stopPropagation();const r=node.getBoundingClientRect();popupPoint={x:e.clientX||r.x+r.width/2,y:e.clientY||r.y+r.height/2};click(e);};node.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();const r=node.getBoundingClientRect();popupPoint={x:r.x+r.width/2,y:r.y+r.height/2};click(e);}};};
 function line(points,cls,color){return svg('polyline',{points:points.map(p=>p.x+','+p.y).join(' '),class:cls,fill:'none',stroke:color});}
 function movingLine(from,to,cls,color){const element=line([from,to],cls,color);movingEdges.push({from,to,line:element});return element;}
 function curvePath(points){return 'M '+points[0].x+' '+points[0].y+points.slice(1).map((b,i)=>{const a=points[i],middle=(a.x+b.x)/2;return ` C ${middle} ${a.y}, ${middle} ${b.y}, ${b.x} ${b.y}`;}).join('');}
 function straightPath(points){const a=points[0],b=points.at(-1);return `M ${a.x} ${a.y} L ${b.x} ${b.y}`;}
 function edgePath(points,straight){return straight?straightPath(points):curvePath(points);}
 function timelineLine(points,cls,color,straight){const element=svg('path',{d:edgePath(points,straight),class:cls,fill:'none',stroke:color});timelineShapes.push({points,element,straight:!!straight});return element;}
 for(const edge of doc.edges){const points=layout.edgePoints.get(edge.id),stem=layout.points.get(edge.from).kind==='start';
 const color=projects.get(edge.project).color,visible=timelineLine(points,'timeline-edge active'+(stem?' start-stem':''),color,stem);canvas.append(visible);const hit=timelineLine(points,'edge-hit','transparent',stem);hit.dataset.edgeId=edge.id;interactive(hit,'Segment: '+layout.points.get(edge.from).title+' to '+layout.points.get(edge.to).title,()=>choose({kind:'edge',id:edge.id}));canvas.append(hit);

 }
 for(const connection of links.connections){const a=layout.points.get(connection.from)??layout.notePoints.get(connection.from),b=layout.points.get(connection.to)??layout.notePoints.get(connection.to);if(!a||!b)continue;canvas.append(movingLine(a,b,'weak-line note-connection','#788ca5'));}
 for(const anchor of doc.anchors){const ghost=!active.has(anchor.id);if(ghost&&!showHistory)continue;const p=layout.points.get(anchor.id),radius=nodeRadius(anchor.kind,degrees.get(anchor.id)),group=svg('g',{class:'anchor '+(ghost?'ghost':'')+(selected?.id===anchor.id?' selected':''),'data-node-id':anchor.id,'data-search':anchor.title});group.append(svg('circle',{cx:p.x,cy:p.y,r:radius,fill:projects.get(anchor.project).color}),svg('text',{x:p.x+radius+5,y:p.y-12,class:'anchor-title'},anchor.title));interactive(group,anchor.title,()=>choose({kind:'anchor',id:anchor.id}));const port=svg('circle',{cx:p.x,cy:p.y+radius+9,r:3.5,class:'connection-handle','aria-label':'Drag to connect milestone'});port.append(svg('title',{},'Drag to connect another milestone'));group.append(port);group.oncontextmenu=e=>nodeMenu(e,anchor);canvas.append(group);}
 for(const device of layout.devices.values()){const label=doc.devices.find(d=>d.id===device.device)?.label??'Device';canvas.append(line([device.origin,device],'weak-line','#a5abb4'),svg('text',{x:device.x+10,y:device.y,class:'device-label'},'▣ '+label));}
 for(const note of layout.notePoints.values()){const radius=nodeRadius('note',degrees.get(note.id)),group=svg('g',{class:'work-note'+(selected?.id===note.id?' selected':'')+(selectedNotes.has(note.id)?' multi-selected':''),'data-node-id':note.id,'aria-pressed':String(selectedNotes.has(note.id)),'data-search':note.title+' '+textFor(note)});canvas.append(movingLine(note.origin,note,'weak-line attachment-line','#a5abb4'));group.append(svg('circle',{cx:note.x,cy:note.y,r:radius}),svg('text',{x:note.x+radius+5,y:note.y+4},note.title));interactive(group,note.title,e=>{if(e.metaKey||e.ctrlKey){if(selectedNotes.has(note.id))selectedNotes.delete(note.id);else selectedNotes.add(note.id);group.classList.toggle('multi-selected',selectedNotes.has(note.id));group.setAttribute('aria-pressed',String(selectedNotes.has(note.id)));}else choose({kind:'note',id:note.id});});group.oncontextmenu=e=>nodeMenu(e,note);canvas.append(group);floating.push({id:note.id,x:note.x,y:note.y,point:note,group});
 }
 if(focusedNote){leaves.forEach((link,i)=>{const x=focusedNote.x+35,y=focusedNote.y+35+i*25,g=svg('g',{class:'link-leaf','data-link-id':link.id});g.append(line([focusedNote,{x,y}],'weak-line','#b8bdc4'),svg('circle',{cx:x,cy:y,r:2.5}),svg('text',{x:x+8,y:y+4},link.label.length>45?link.label.slice(0,44)+'…':link.label));interactive(g,'Open '+link.label,()=>openLink(link.url,focusedNote));(floating.find(n=>n.id===focusedNote.id)?.group??canvas).append(g);});}
 if(!doc.projects.length){const empty=el('div',null,'map-empty');empty.append(el('h2','Give your projects a timeline'),el('p','Start with a project and its milestones. Work notes attach to the time between them.'),button('Create first project',sampleProject,'primary'));viewport.append(empty);}
 const chosen=selected?.kind==='edge'?doc.edges.find(e=>e.id===selected.id):selected?.kind==='anchor'?doc.anchors.find(a=>a.id===selected.id):doc.notes.find(n=>n.id===selected?.id);
 if(chosen&&selected.kind==='edge'){const a=layout.points.get(chosen.from),b=layout.points.get(chosen.to);const heading=el('div',null,'popup-heading');heading.append(el('h2',a.title+' → '+b.title),el('span',null,'spacer'),iconButton('close','Close',closePopup));detail.append(heading,el('p',a.date+' — '+b.date,'muted'),button('Add work note',()=>addWork({kind:'edge',id:chosen.id})),button('Attach device notes',()=>attachDevice({kind:'edge',id:chosen.id})));detail.append(button('Add milestone',()=>newMilestone(chosen.from)),button('Disconnect milestones',async()=>{try{if(!await flushNote())return;await transaction(disconnectMilestones(data.doc,chosen.id),{forget:true});selected=null;render();}catch(e){notice(e.message);}}));}
 else if(chosen&&!preserved){noteDetails(detail,chosen);if(selected.kind==='anchor'){detail.append(button('Add memo',()=>addWork({kind:'anchor',id:chosen.id})));detail.append(button('Add milestone',()=>newMilestone(chosen.id)));}}
 if(chosen){detail.setAttribute('role','dialog');detail.setAttribute('aria-label',selected.kind==='edge'?'Segment actions':chosen.title);const popup=preserved??detail;if(preserved)preserved.querySelector('.popup-heading h2').textContent=chosen.device?chosen.title:'';if(!preserved)main.append(popup);placePopup(popup);}
 if(focusDate){viewport.scrollLeft=Math.max(0,layout.x(focusDate)*zoom-Math.min(120,viewport.clientWidth*.25));focusDate=null;}
 else if(camera){viewport.scrollLeft=camera.x;viewport.scrollTop=camera.y;}updateTicks();if(search)find.oninput();
 const resumeMotion=()=>{stopMotion();if(!viewActive)return;stopMotion=animateNotes({canvas,viewport,notes:floating,edges:movingEdges,zoom:()=>zoom});};resumeMotion();
 stopGestures=graphGestures({canvas,viewport,notes:floating,selection:selectedNotes,doc,layout,onSelect:async()=>{if(!await flushNote()){resumeMotion();return;}selected=null;render();},onConnect:async(from,to)=>{try{if(await flushNote())await transaction(connectMilestones(data.doc,from,to),{forget:true});}catch(e){notice(e.message);}if(canvas.isConnected)resumeMotion();},preview:()=>{for(const edge of movingEdges)edge.line.setAttribute('points',`${edge.from.x},${edge.from.y} ${edge.to.x},${edge.to.y}`);for(const edge of timelineShapes)edge.element.setAttribute('d',edgePath(edge.points,edge.straight));},onReorder:async(id,target)=>{try{await applyMove(()=>reorderMilestones(data.doc,id,target));}catch(e){notice(e.message);}render();},onMove:async(ids,days,priority,cascadePriority)=>{try{await applyMove(()=>moveNodes(data.doc,ids,{days,priority,cascadePriority},data.texts));}catch(e){render();notice(e.message);return;}render();},pause:()=>stopMotion(),resume:resumeMotion});
}
window.crowMap={flush:flushNote,setActive(active){viewActive=active;if(!active){stopMotion();document.activeElement?.blur();}else if(data)render();},addSampleProject:sampleProject,renamed(value){const pending=renamePending;renamePending=null;if(value.error){pending?.reject(Error(value.error));return;}if(embedded){clearTimeout(embedded.timer);embedded.destroy();embedded=null;}this.receive(value);pending?.resolve(value.name);},draftError(name,message){if(embedded?.name===name){embedded.blocked=true;embedded.status.textContent=message;}},async refreshDevice(value){
 if(data?.doc.id!==value.mapID||pending)return;
 let doc=structuredClone(data.doc);const device=doc.devices.find(d=>d.hostID===value.hostID);if(!device)return;
 for(const incoming of value.notes){const matches=doc.notes.filter(n=>n.device===device.id&&n.note===incoming.name);for(const n of matches){n.cachedText=incoming.text;n.title=incoming.title;n.date=incoming.date;}
  if(!matches.length){const meta=readNote(incoming.text).meta;let attach;try{attach=resolveAttachment(meta,doc,data.texts)??(meta.crowmap===doc.id?meta.attach:null);}catch{}if(attach&&device.attachments?.some(a=>a.kind===attach.kind&&a.id===attach.id))doc=addNote(doc,{title:incoming.title,date:incoming.date,body:'',attach,device:device.id,note:incoming.name,cachedText:incoming.text}).doc;}
 }
 if(JSON.stringify(doc)!==JSON.stringify(data.doc))await transaction({doc,writes:[]},{forget:true});
 },markdown(id,html){const body=document.querySelector('[data-preview="'+id+'"]');if(!body)return;body.innerHTML=html;const item=[...data.doc.anchors,...data.doc.notes].find(n=>n.id===selected?.id);if(item)markdownCache.set(readNote(textFor(item)).body,html);const popup=body.closest('.map-popup');if(popup)placePopup(popup);},receive(value){try{graphError=null;const cached=JSON.parse(value.source),doc=resolveMap(cached,value.texts??{});
 validateMap(doc);if(!data?.doc.projects.length&&doc.projects.length)fitNext=true;const changed=data?.doc.id!==doc.id;if(changed){selectedNotes.clear();fitNext=true;selected=null;camera=null;zoom=1;forgetMoves();}data={...value,doc};render();if(doc.anchors.length&&!pending&&(!doc.noteLinks||['projects','anchors','edges','notes'].some(key=>{const known=new Set(cached[key].map(n=>n.id));return doc[key].some(n=>!known.has(n.id));})))queueMicrotask(()=>{if(!pending)try{transaction({doc:data.doc,writes:[]},{links:!data.doc.noteLinks}).catch(e=>notice(e.message));}catch(e){notice(e.message);}});}catch(e){graphError=e.message;try{data={...value,doc:data?.doc??validateMap(JSON.parse(value.source))};render();}catch{}notice(e.message);}},saved(value){if(!pending)return;const task=pending;pending=null;if(value.error){notice(value.error);task.reject(Error(value.error));}else{this.receive(value);task.resolve();}},remote(value){document.dispatchEvent(new CustomEvent('crowmap-remote',{detail:value}));},error:notice};

for(const event of ['pointerdown','focusin'])document.addEventListener(event,()=>{if(viewActive)send({action:'focus'});},{passive:true});
