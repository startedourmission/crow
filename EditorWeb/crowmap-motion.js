// Stable, gentle offsets keep work near its dated attachment without a running force solver.
export function floatOffset(id,time=0,tension=10){
 if(!(tension>0))return {x:0,y:0};
 let hash=2166136261;for(const c of id)hash=Math.imul(hash^c.charCodeAt(0),16777619);
 const seed=(hash>>>0)/4294967296,phase=seed*Math.PI*2,wobble=Math.min(2.5,tension*.25);
 return {x:Math.sin(time*.6+phase)*wobble,y:Math.cos(time*.45+phase)*wobble};
}

export function nodeDegrees(doc,links){
 const neighbors=new Map(),join=(a,b)=>{if(a===b)return;for(const [from,to]of [[a,b],[b,a]]){if(!neighbors.has(from))neighbors.set(from,new Set());neighbors.get(from).add(to);}};
 for(const edge of doc.edges)join(edge.from,edge.to);
 for(const note of doc.notes)join(note.id,note.device?'device:'+note.device+':'+note.attach.id:note.attach.kind+':'+note.attach.id);
 // An anchor attachment is an actual note-to-note connection.
 for(const note of doc.notes)if(!note.device&&note.attach.kind==='anchor'){neighbors.get(note.id).delete('anchor:'+note.attach.id);join(note.id,note.attach.id);}
 for(const link of links.connections)join(link.from,link.to);
 return new Map([...neighbors].map(([id,set])=>[id,set.size+(links.leaves.get(id)?.length??0)]).concat([...links.leaves].filter(([id])=>!neighbors.has(id)).map(([id,leaves])=>[id,leaves.length])));
}

export function nodeRadius(kind,degree=0){return (kind==='start'?7:kind==='note'?3.5:5)+Math.min(5,Math.log2(Math.max(1,degree))*1.4);}

export function stepNotes(notes,{pinned=new Set()}={}){
 let energy=0;
 for(const note of notes){
  if(note.point.device||pinned.has(note.id)){note.vx=0;note.vy=0;continue;}
  const origin=note.origin??{x:note.x,y:note.y},orbit=note.orbit??0,p=note.point;
  let fx=0,fy=0,dx=p.x-origin.x,dy=p.y-origin.y,dist=Math.hypot(dx,dy)||0.0001;
  const pull=0.05*(dist-orbit);fx-=pull*dx/dist;fy-=pull*dy/dist;
  if(orbit>0)for(const other of notes){
   if(other===note||other.point.device)continue;
   const rx=p.x-other.point.x,ry=p.y-other.point.y,d=Math.hypot(rx,ry)||0.0001;
   const reach=Math.max(18,orbit+(other.orbit??0)+8);
   if(d>reach)continue;const sep=Math.max(12,Math.min(orbit,other.orbit??orbit)*0.85);const push=Math.max(0,sep-d)*0.09;fx+=push*rx/d;fy+=push*ry/d;
  }
  note.vx=(note.vx??0)*0.72+fx;note.vy=(note.vy??0)*0.72+fy;
  const speed=Math.hypot(note.vx,note.vy);if(speed>7){note.vx*=7/speed;note.vy*=7/speed;}
  p.x+=note.vx;p.y+=note.vy;energy+=speed;
 }
 return energy;
}

export function animateNotes({canvas,viewport,notes,edges,zoom,tension=10,pinned}){
 let frame=0,last=0,stopped=false;
 const held=pinned??new Set();
 const reduced=matchMedia('(prefers-reduced-motion: reduce)');
 function paint(){
  const z=zoom(),left=viewport.scrollLeft/z-180,right=(viewport.scrollLeft+viewport.clientWidth)/z+180,top=viewport.scrollTop/z-100,bottom=(viewport.scrollTop+viewport.clientHeight)/z+100;
  for(const note of notes){
   const p=note.point;note.visible=p.x>=left&&p.x<=right&&p.y>=top&&p.y<=bottom;
   if(!note.visible)continue;
   const next=`translate(${p.x-note.x} ${p.y-note.y})`;
   if(note.transform!==next){note.transform=next;note.group.setAttribute('transform',next);}
  }
  for(const edge of edges){
   const a=edge.from,b=edge.to;
   if(Math.max(a.x,b.x)<left||Math.min(a.x,b.x)>right||Math.max(a.y,b.y)<top||Math.min(a.y,b.y)>bottom)continue;
   const points=`${a.x},${a.y} ${b.x},${b.y}`;
   if(edge.points!==points){edge.points=points;edge.line.setAttribute('points',points);}
  }
 }
 function update(){
  if(!reduced.matches&&tension>0)stepNotes(notes,{pinned:held});
  else for(const note of notes){if(held.has(note.id))continue;note.point.x=note.x;note.point.y=note.y;note.vx=0;note.vy=0;}
  paint();
 }
 function tick(time){frame=0;if(stopped||document.hidden)return;if(time-last>=1000/24){update();last=time;}frame=requestAnimationFrame(tick);}
 function resume(){cancelAnimationFrame(frame);frame=0;if(stopped)return;update();if(!document.hidden&&notes.length)frame=requestAnimationFrame(tick);}
 document.addEventListener('visibilitychange',resume);reduced.addEventListener('change',resume);resume();
 return ()=>{stopped=true;cancelAnimationFrame(frame);document.removeEventListener('visibilitychange',resume);reduced.removeEventListener('change',resume);};
}
