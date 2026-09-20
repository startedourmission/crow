import {day,mainMilestoneIDs} from './crowmap-model.js';
import {movedDate} from './crowmap-links.js';
const ns='http://www.w3.org/2000/svg';
const shape=(tag,cls)=>{const node=document.createElementNS(ns,tag);node.setAttribute('class',cls);return node;};
const attrs=(node,values)=>{for(const [key,value]of Object.entries(values))node.setAttribute(key,value);};
export function graphGestures({canvas,viewport,notes,selection,doc,layout,onSelect,onConnect,onMove,onReorder,preview,pause,resume}){
 let cancel=()=>{},suppressClick=0;
 const point=e=>{const r=canvas.getBoundingClientRect(),scale=canvas.viewBox.baseVal.width/r.width;return {x:(e.clientX-r.left)*scale,y:(e.clientY-r.top)*scale};};
 canvas.addEventListener('click',e=>{if(performance.now()<suppressClick){e.preventDefault();e.stopImmediatePropagation();}},true);
 canvas.addEventListener('pointerdown',event=>{
  if(event.button!==0||event.ctrlKey)return;
  const group=event.target.closest('.anchor,.work-note'),port=event.target.closest('.connection-handle'),button=event.target.closest('[role=button]');if(button&&!group)return;
  if(event.target.closest('.link-leaf'))return;
  const node=group&&[...doc.anchors,...doc.notes].find(n=>n.id===group.dataset.nodeId);if(node?.device||event.metaKey&&!node?.kind)return;
  event.preventDefault();event.stopPropagation();
  const start=point(event),original=new Set(selection),overlay=shape(port?'line':'rect',port?'milestone-drag':node?'date-drop-column':'note-selection-box'),label=shape('text','date-drop-label'),lane=shape('rect','priority-drop-lane');
  overlay.style.display='none';canvas.append(overlay);if(node&&!port){canvas.prepend(lane);canvas.append(label);}let moved=false,target=null,reorder=null,days=0,priority,cascadePriority=event.metaKey,axis=null;const main=mainMilestoneIDs(doc),originalPoints=new Map([...layout.points].map(([id,p])=>[id,{...p}]));
  const dragged=node&&!node.kind&&selection.has(node.id)?notes.filter(n=>selection.has(n.id)&&!n.point.device):node?[{id:node.id,group,point:layout.points.get(node.id)??layout.notePoints.get(node.id)}]:[],positions=dragged.map(n=>({...n.point})),transforms=dragged.map(n=>n.group.getAttribute('transform')??'');
  pause();
  const move=e=>{
   if(Math.hypot(e.clientX-event.clientX,e.clientY-event.clientY)<4&&!moved)return;moved=true;cascadePriority=e.metaKey;const p=point(e);
   if(port){
    overlay.style.display='';
    const circle=group.querySelector('circle');attrs(overlay,{x1:circle.getAttribute('cx'),y1:circle.getAttribute('cy'),x2:p.x,y2:p.y});
    target?.classList.remove('connection-target');target=document.elementFromPoint(e.clientX,e.clientY)?.closest('.anchor');if(target===group)target=null;target?.classList.add('connection-target');
   }else if(node){
    if(!axis)axis=!node.kind||Math.abs(e.clientX-event.clientX)>=Math.abs(e.clientY-event.clientY)?'date':'priority';
    reorder?.group.classList.remove('order-target');reorder=null;days=0;priority=undefined;overlay.style.display=axis==='date'?'':'none';lane.style.display='none';
    if(axis==='date'){
     const requested=layout.dateAt(layout.x(node.date)+p.x-start.x),date=movedDate(doc,node.id,requested),x=layout.x(date),bounds=layout.dateBounds(date);
     days=day(date)-day(node.date);
     attrs(overlay,{x:bounds.left,y:0,width:bounds.right-bounds.left,height:canvas.viewBox.baseVal.height});
     const z=canvas.getBoundingClientRect().width/canvas.viewBox.baseVal.width;attrs(label,{x:x+8,y:viewport.scrollTop/z+50});label.textContent=date;
    }else{
     const origin=originalPoints.get(node.id);
     if(node.kind&&node.kind!=='start'){const targetY=origin.y+p.y-start.y;
      const candidate=doc.anchors.filter(a=>a.id!==node.id&&a.kind!=='start'&&a.project===node.project&&a.date===node.date&&main.has(a.id)===main.has(node.id)).find(a=>{const q=originalPoints.get(a.id);return Math.abs(q.x-origin.x)<36&&Math.abs(q.y-targetY)<24;});
      if(candidate){const group=canvas.querySelector('[data-node-id="'+candidate.id+'"]');reorder={id:candidate.id,group};group.classList.add('order-target');}
     }
     priority=node.kind&&!reorder&&Math.abs(p.y-start.y)>=(layout.priorityY(2)-layout.priorityY(1))*.35?layout.priorityAt(p.y):undefined;
     const z=canvas.getBoundingClientRect().width/canvas.viewBox.baseVal.width;attrs(label,{x:origin.x+8,y:viewport.scrollTop/z+50});label.textContent=reorder?'Swap order':priority?'Priority '+priority+(cascadePriority?' · Following milestones':''):'';
     lane.style.display=priority?'':'none';
     if(priority)attrs(lane,{x:0,y:layout.priorityY(priority)-28,width:canvas.viewBox.baseVal.width,height:56});
    }
    dragged.forEach((n,i)=>{const dx=axis==='date'?layout.x(new Date((day(positions[i].date)+days)*86400000).toISOString().slice(0,10))-layout.x(positions[i].date):0,dy=axis==='priority'?(reorder?originalPoints.get(reorder.id).y-positions[i].y:priority!=null&&priority!==layout.rankAt(node.project,node.date)?layout.priorityY(priority)-positions[i].y:0):0;n.group.setAttribute('transform',`translate(${dx} ${dy}) ${transforms[i]}`);n.point.x=positions[i].x+dx;n.point.y=positions[i].y+dy;});preview();
   }else{
    overlay.style.display='';
    const x=Math.min(start.x,p.x),y=Math.min(start.y,p.y),width=Math.abs(p.x-start.x),height=Math.abs(p.y-start.y);attrs(overlay,{x,y,width,height});
    selection.clear();if(event.shiftKey)for(const id of original)selection.add(id);
    for(const n of notes)if(n.point.x>=x&&n.point.x<=x+width&&n.point.y>=y&&n.point.y<=y+height)selection.add(n.id);
    for(const n of notes){const yes=selection.has(n.id);n.group.classList.toggle('multi-selected',yes);n.group.setAttribute('aria-pressed',String(yes));}
   }
  };
  const cleanup=()=>{window.removeEventListener('pointermove',move);window.removeEventListener('pointerup',up);window.removeEventListener('pointercancel',abort);window.removeEventListener('blur',abort);overlay.remove();label.remove();lane.remove();target?.classList.remove('connection-target');reorder?.group.classList.remove('order-target');dragged.forEach((n,i)=>{n.group.setAttribute('transform',transforms[i]);n.point.x=positions[i].x;n.point.y=positions[i].y;});preview();cancel=()=>{};};
  const up=()=>{const to=target?.dataset.nodeId;cleanup();if(moved)suppressClick=performance.now()+300;if(port&&moved&&to)onConnect(node.id,to);else if(node&&moved&&!port&&reorder)onReorder(node.id,reorder.id);else if(node&&moved&&!port)onMove(dragged.map(n=>n.id),days,priority,cascadePriority);else if(!node){if(!moved&&!event.shiftKey)selection.clear();onSelect();}else resume();};
  const abort=()=>{selection.clear();for(const id of original)selection.add(id);cleanup();resume();};
  cancel=()=>{selection.clear();for(const id of original)selection.add(id);cleanup();};window.addEventListener('pointermove',move);window.addEventListener('pointerup',up);window.addEventListener('pointercancel',abort);window.addEventListener('blur',abort);
 });
 return ()=>cancel();
}
