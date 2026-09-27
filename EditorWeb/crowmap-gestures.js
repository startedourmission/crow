import {day,mainMilestoneIDs} from './crowmap-model.js';
import {movedDate,followingMilestoneIDs,precedingMilestoneIDs} from './crowmap-links.js';
const ns='http://www.w3.org/2000/svg';
const shape=(tag,cls)=>{const node=document.createElementNS(ns,tag);node.setAttribute('class',cls);return node;};
const attrs=(node,values)=>{for(const [key,value]of Object.entries(values))node.setAttribute(key,value);};
export function edgeScrollDelta(x,y,{left,top,right,bottom},margin=48,max=22){
 const along=(pos,min,maxEdge)=>{if(pos<=min)return -max;if(pos>=maxEdge)return max;if(pos<min+margin)return -max*(min+margin-pos)/margin;if(pos>maxEdge-margin)return max*(pos-(maxEdge-margin))/margin;return 0;};
 return {x:along(x,left,right),y:along(y,top,bottom)};
}
export function graphGestures({canvas,viewport,notes,selection,doc,layout,onSelect,onConnect,onMove,onReorder,preview,pause,resume,zoom,onCamera,pinned}){
 let cancel=()=>{},suppressClick=0;
 const ac=new AbortController(),{signal}=ac;
 const point=(e,rect)=>{const r=rect??canvas.getBoundingClientRect(),vb=canvas.viewBox.baseVal,z=typeof zoom==='function'?zoom():r.width/vb.width;return {x:vb.x+(e.clientX-r.left)/z,y:vb.y+(e.clientY-r.top)/z};};
 canvas.addEventListener('click',e=>{if(performance.now()<suppressClick){e.preventDefault();e.stopImmediatePropagation();}},{capture:true,signal});
 canvas.addEventListener('pointerdown',event=>{
  if(event.button!==0||event.ctrlKey)return;
  const group=event.target.closest('.anchor,.work-note'),port=event.target.closest('.connection-handle'),button=event.target.closest('[role=button]');if(button&&!group)return;
  if(event.target.closest('.link-leaf'))return;
  const node=group&&[...doc.anchors,...doc.notes].find(n=>n.id===group.dataset.nodeId);if(node?.device||event.metaKey&&!node?.kind)return;
  event.preventDefault();event.stopPropagation();
  const start=point(event),original=new Set(selection),overlay=shape(port?'line':'rect',port?'milestone-drag':node?'date-drop-column':'note-selection-box'),label=shape('text','date-drop-label'),lane=shape('rect','priority-drop-lane');
  overlay.style.display='none';canvas.append(overlay);if(node?.kind&&!port){canvas.prepend(lane);canvas.append(label);}let moved=false,target=null,reorder=null,days=0,priority,cascadePriority=event.metaKey,preserveGaps=event.shiftKey,axis=null,cascade=false,cascadeLater=false,cascadeEarlier=false;const main=mainMilestoneIDs(doc),originalPoints=new Map([...layout.points].map(([id,p])=>[id,{...p}]));
  const dragged=node&&!node.kind&&selection.has(node.id)?notes.filter(n=>selection.has(n.id)&&!n.point.device):node?[{id:node.id,group,point:layout.points.get(node.id)??layout.notePoints.get(node.id)}]:[],positions=dragged.map(n=>({...n.point})),transforms=dragged.map(n=>n.group.getAttribute('transform')??'');
  const following=node?.kind?followingMilestoneIDs(doc,node.id):new Set(),preceding=node?.kind?precedingMilestoneIDs(doc,node.id):new Set(),later=[],earlier=[];
  if(node?.kind){const collect=(ids,list,key)=>{for(const id of ids){const g=canvas.querySelector('[data-node-id="'+id+'"]'),point=layout.points.get(id);if(g&&point)list.push({kind:'milestone',anchorID:id,group:g,point,origin:{x:point.x,y:point.y,date:point.date},transform:g.getAttribute('transform')??''});}for(const n of notes){const item=doc.notes.find(x=>x.id===n.id);if(!item)continue;const edge=item.attach.kind==='edge'?doc.edges.find(e=>e.id===item.attach.id):null,anchorID=item.attach.kind==='anchor'?item.attach.id:edge?.[key];if(item.attach.kind==='anchor'?ids.has(item.attach.id):edge&&(ids.has(anchorID)||anchorID===node.id))list.push({kind:'work',anchorID,group:n.group,point:n.point,origin:{x:n.point.x,y:n.point.y,date:n.point.date},transform:n.group.getAttribute('transform')??''});}};collect(following,later,'from');collect(preceding,earlier,'to');}
  if(node&&!node.kind){for(const n of dragged)pinned?.add(n.id);}else pause();
  let pointer=event,frame=0,canvasRect=canvas.getBoundingClientRect(),viewRect=viewport.getBoundingClientRect();
  const followingDays=new Map(),precedingDays=new Map();
  for(const id of following){const a=doc.anchors.find(n=>n.id===id);if(a)followingDays.set(id,day(a.date));}
  for(const id of preceding){const a=doc.anchors.find(n=>n.id===id);if(a)precedingDays.set(id,day(a.date));}
  const laneStep=layout.priorityY(2)-layout.priorityY(1);
  const moving=new Set([node?.id,...later.map(n=>n.group.dataset.nodeId),...earlier.map(n=>n.group.dataset.nodeId)].filter(Boolean));
  const draw=()=>{
   frame=0;if(!pointer)return;
   const e=pointer;cascadePriority=e.metaKey;preserveGaps=e.shiftKey;
   let scrolled=false;
   if(moved){const d=edgeScrollDelta(e.clientX,e.clientY,viewRect);if(d.x||d.y){viewport.scrollLeft+=d.x;viewport.scrollTop+=d.y;scrolled=true;onCamera?.();canvasRect=canvas.getBoundingClientRect();viewRect=viewport.getBoundingClientRect();}}
   if(Math.hypot(e.clientX-event.clientX,e.clientY-event.clientY)<4&&!moved)return;moved=true;const p=point(e,canvasRect);
   const z=typeof zoom==='function'?zoom():canvasRect.width/canvas.viewBox.baseVal.width,vb=canvas.viewBox.baseVal;
   if(port){
    overlay.style.display='';
    const circle=group.querySelector('circle');attrs(overlay,{x1:circle.getAttribute('cx'),y1:circle.getAttribute('cy'),x2:p.x,y2:p.y});
    target?.classList.remove('connection-target');target=document.elementFromPoint(e.clientX,e.clientY)?.closest('.anchor');if(target===group)target=null;target?.classList.add('connection-target');
   }else if(node&&!node.kind){
    overlay.style.display='none';lane.style.display='none';
    const followX=p.x-start.x,followY=p.y-start.y;
    dragged.forEach((n,i)=>{n.point.x=positions[i].x+followX;n.point.y=positions[i].y+followY;n.vx=0;n.vy=0;n.transform=`translate(${n.point.x-n.x} ${n.point.y-n.y})`;n.group.setAttribute('transform',n.transform);});
    preview(moving);
   }else if(node){
    if(!axis){const dx=Math.abs(e.clientX-event.clientX),dy=Math.abs(e.clientY-event.clientY);if(dx>=12||dy>=12)axis=dx>=dy?'date':'priority';}
    reorder?.group.classList.remove('order-target');reorder=null;days=0;priority=undefined;cascade=false;cascadeLater=false;cascadeEarlier=false;overlay.style.display=axis==='date'?'':'none';lane.style.display='none';
    if(!axis){
     const followX=p.x-start.x,followY=p.y-start.y;
     dragged.forEach((n,i)=>{n.group.setAttribute('transform',`translate(${followX} ${followY}) ${transforms[i]}`);n.point.x=positions[i].x+followX;n.point.y=positions[i].y+followY;});
     preview(moving);
    }else if(axis==='date'){
     const requested=layout.dateAt(layout.x(node.date)+p.x-start.x),date=movedDate(doc,node.id,requested),x=layout.x(date),bounds=layout.dateBounds(date);
     days=day(date)-day(node.date);cascadeLater=node.kind&&[...followingDays].some(([,d])=>d<day(date));cascadeEarlier=node.kind&&[...precedingDays].some(([,d])=>d>day(date));cascade=cascadeLater||cascadeEarlier;
     attrs(overlay,{x:bounds.left,y:0,width:bounds.right-bounds.left,height:layout.height});
     attrs(label,{x:x+8/z,y:vb.y+48/z});label.style.fontSize=12/z+'px';label.textContent=cascade?date+(preserveGaps?' · Keep spacing':cascadeEarlier&&days<0?' · Previous milestones':' · Following milestones'):date;
    }else{
     const origin=originalPoints.get(node.id);
     if(node.kind&&node.kind!=='start'){const targetY=origin.y+p.y-start.y;
      const candidate=doc.anchors.filter(a=>a.id!==node.id&&a.kind!=='start'&&a.project===node.project&&a.date===node.date&&main.has(a.id)===main.has(node.id)).find(a=>{const q=originalPoints.get(a.id);return Math.abs(q.x-origin.x)<36&&Math.abs(q.y-targetY)<24;});
      if(candidate){const group=canvas.querySelector('[data-node-id="'+candidate.id+'"]');reorder={id:candidate.id,group};group.classList.add('order-target');}
     }
     priority=node.kind&&!reorder&&Math.abs(p.y-start.y)>=laneStep*.35?layout.priorityAt(p.y):undefined;
     attrs(label,{x:origin.x+8/z,y:vb.y+48/z});label.style.fontSize=12/z+'px';label.textContent=reorder?'Swap order':priority?'Priority '+priority+(cascadePriority?' · Following milestones':''):'';
     lane.style.display=priority?'':'none';
     if(priority)attrs(lane,{x:0,y:layout.priorityY(priority)-28,width:layout.width,height:56});
    }
    if(axis){
     const followX=p.x-start.x,followY=p.y-start.y;
     dragged.forEach((n,i)=>{const dx=axis==='date'?followX:0,dy=axis==='priority'?(reorder?originalPoints.get(reorder.id).y-positions[i].y:followY):0;n.group.setAttribute('transform',`translate(${dx} ${dy}) ${transforms[i]}`);n.point.x=positions[i].x+dx;n.point.y=positions[i].y+dy;});
     const nudge=(list,backward)=>{list.forEach(n=>{const drop=axis==='date'?new Date((day(node.date)+days)*86400000).toISOString().slice(0,10):null,active=backward?cascadeEarlier:cascadeLater;let dx=0;if(axis==='date'&&active&&drop){if(preserveGaps)dx=followX;else{const crossed=backward?day(n.origin.date)>day(drop):day(n.origin.date)<day(drop),anchorDay=followingDays.get(n.anchorID)??precedingDays.get(n.anchorID),chain=n.kind==='milestone'||n.anchorID===node.id||anchorDay!=null&&(backward?anchorDay>day(drop):anchorDay<day(drop));if(crossed&&chain)dx=positions[0].x+followX-n.origin.x;}}n.group.setAttribute('transform',`translate(${dx} 0) ${n.transform}`);n.point.x=n.origin.x+dx;n.point.y=n.origin.y;});};
     nudge(later,false);nudge(earlier,true);preview(moving);
    }
   }else{
    overlay.style.display='';
    const x=Math.min(start.x,p.x),y=Math.min(start.y,p.y),width=Math.abs(p.x-start.x),height=Math.abs(p.y-start.y);attrs(overlay,{x,y,width,height});
    selection.clear();if(event.shiftKey)for(const id of original)selection.add(id);
    for(const n of notes)if(n.point.x>=x&&n.point.x<=x+width&&n.point.y>=y&&n.point.y<=y+height)selection.add(n.id);
    for(const n of notes){const yes=selection.has(n.id);if(n.group.classList.contains('multi-selected')===yes)continue;n.group.classList.toggle('multi-selected',yes);n.group.setAttribute('aria-pressed',String(yes));}
   }
   if(scrolled)frame=requestAnimationFrame(draw);
  };
  const move=e=>{pointer=e;if(!frame)frame=requestAnimationFrame(draw);};
  const capture=()=>{const m=new Map();for(const n of dragged)if(n.id)m.set(n.id,{x:n.point.x,y:n.point.y});for(const n of [...later,...earlier]){const id=n.group?.dataset?.nodeId;if(id)m.set(id,{x:n.point.x,y:n.point.y});}return m;};
  const cleanup=(reset=true)=>{cancelAnimationFrame(frame);window.removeEventListener('pointermove',move);window.removeEventListener('pointerup',up);window.removeEventListener('pointercancel',abort);window.removeEventListener('blur',abort);overlay.remove();label.remove();lane.remove();target?.classList.remove('connection-target');reorder?.group.classList.remove('order-target');if(node&&!node.kind){for(const n of dragged){pinned?.delete(n.id);n.x=n.point.x;n.y=n.point.y;if(n.origin)n.orbit=Math.hypot(n.point.x-n.origin.x,n.point.y-n.origin.y);}}else if(reset){dragged.forEach((n,i)=>{n.group.setAttribute('transform',transforms[i]);n.point.x=positions[i].x;n.point.y=positions[i].y;});for(const n of [...later,...earlier]){n.group.setAttribute('transform',n.transform);n.point.x=n.origin.x;n.point.y=n.origin.y;}}preview(node&&!node.kind?moving:undefined);cancel=()=>{};};
  const up=e=>{if(e){cascadePriority=e.metaKey;preserveGaps=e.shiftKey;}const to=target?.dataset.nodeId;const last=capture();const commit=node?.kind&&moved&&!port;cleanup(!commit);if(moved)suppressClick=performance.now()+300;if(port&&moved&&to)onConnect(node.id,to);else if(node&&moved&&!port&&reorder)onReorder(node.id,reorder.id,last);else if(commit)onMove(dragged.map(n=>n.id),days,priority,cascadePriority,preserveGaps,last);else{if(!node){if(!moved&&!event.shiftKey){selection.clear();for(const n of notes){n.group.classList.remove('multi-selected');n.group.setAttribute('aria-pressed','false');}}onSelect();}resume();}};
  const abort=()=>{selection.clear();for(const id of original)selection.add(id);cleanup();resume();};
  cancel=()=>{selection.clear();for(const id of original)selection.add(id);cleanup();};window.addEventListener('pointermove',move,{signal});window.addEventListener('pointerup',up,{signal});window.addEventListener('pointercancel',abort,{signal});window.addEventListener('blur',abort,{signal});
 },{signal});
 return ()=>{cancel();ac.abort();};
}
