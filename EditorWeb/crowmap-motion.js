// Stable, gentle offsets keep work near its dated attachment without a running force solver.
export function floatOffset(id,time=0){
 let hash=2166136261;for(const c of id)hash=Math.imul(hash^c.charCodeAt(0),16777619);
 const seed=(hash>>>0)/4294967296,phase=seed*Math.PI*2;
 return {x:(seed<.5?-1:1)*(18+seed*18)+Math.sin(time*.6+phase)*7,y:Math.cos(time*.45+phase)*5};
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

export function animateNotes({canvas,viewport,notes,edges,zoom}){
 let frame=0,last=0,stopped=false;
 const reduced=matchMedia('(prefers-reduced-motion: reduce)');
 function update(time){
  const z=zoom(),left=viewport.scrollLeft/z-180,right=(viewport.scrollLeft+viewport.clientWidth)/z+180,top=viewport.scrollTop/z-100,bottom=(viewport.scrollTop+viewport.clientHeight)/z+100;
  for(const note of notes){
   const offset=floatOffset(note.id,time),p=note.point;p.x=note.x+offset.x;p.y=note.y+offset.y;
   note.visible=p.x>=left&&p.x<=right&&p.y>=top&&p.y<=bottom;
   if(note.visible)note.group.setAttribute('transform',`translate(${offset.x} ${offset.y})`);
  }
  for(const edge of edges){
   const a=edge.from,b=edge.to;
   if(Math.max(a.x,b.x)<left||Math.min(a.x,b.x)>right||Math.max(a.y,b.y)<top||Math.min(a.y,b.y)>bottom)continue;
   edge.line.setAttribute('points',`${a.x},${a.y} ${b.x},${b.y}`);
  }
 }
 function tick(time){frame=0;if(stopped||document.hidden||reduced.matches)return;if(time-last>=1000/30){update(time/1000);last=time;}frame=requestAnimationFrame(tick);}
 function resume(){cancelAnimationFrame(frame);frame=0;if(stopped)return;update(reduced.matches?0:performance.now()/1000);if(!document.hidden&&!reduced.matches&&notes.length)frame=requestAnimationFrame(tick);}
 const refresh=()=>{if(reduced.matches)update(0);};
 document.addEventListener('visibilitychange',resume);reduced.addEventListener('change',resume);viewport.addEventListener('scroll',refresh,{passive:true});resume();
 return ()=>{stopped=true;cancelAnimationFrame(frame);document.removeEventListener('visibilitychange',resume);reduced.removeEventListener('change',resume);viewport.removeEventListener('scroll',refresh);};
}
