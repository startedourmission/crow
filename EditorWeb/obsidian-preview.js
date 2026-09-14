import {canvas,base,yaml} from './obsidian-model.js';
const send = body => window.webkit.messageHandlers.obsidian.postMessage(body);
const el = (name, text, cls) => { const e=document.createElement(name); if(text!=null)e.textContent=String(text); if(cls)e.className=cls;return e; };
const main=document.querySelector('main');let data, viewIndex=0, generation=0, assets=new Map();
function button(title, action) { const b=el('button',title);b.onclick=action;return b; }
function open(path) { send({action:'open',path}); }
function fileButton(path,label) { return button(label??path,()=>open(path)); }
function color(value) { return /^#[0-9a-f]{6}$/i.test(value??'')?value:({1:'#d85f62',2:'#da8b45',3:'#b49e37',4:'#48a273',5:'#4495b5',6:'#9471bf'}[value]??'#8190a5'); }
function asset(path, target, background=false, style='cover') {
  const id=String(generation)+':'+String(assets.size);assets.set(id,{target,background,style});send({action:'asset',path,id});
}
function canvasView() {
  const doc=canvas(data.source), tools=el('header'), viewport=el('div',null,'viewport'), world=el('div',null,'world');
  main.append(tools,viewport);viewport.append(world);
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.classList.add('edges');world.append(svg);
  const byID=new Map(doc.nodes.map(n=>[n.id,n])); let zoom=1,tx=0,ty=0;
  const transform=()=>{world.style.transform=`translate(${tx}px,${ty}px) scale(${zoom})`; scale.textContent=Math.round(zoom*100)+'%';};
  const scale=el('span','100%');
  function zoomTo(next) {next=Math.min(4,Math.max(.03,next));const x=viewport.clientWidth/2,y=viewport.clientHeight/2;tx=x-(x-tx)*next/zoom;ty=y-(y-ty)*next/zoom;zoom=next;transform();}
  function fit(){if(!doc.nodes.length)return;const minX=Math.min(...doc.nodes.map(n=>n.x)),minY=Math.min(...doc.nodes.map(n=>n.y)),maxX=Math.max(...doc.nodes.map(n=>n.x+n.width)),maxY=Math.max(...doc.nodes.map(n=>n.y+n.height));zoom=Math.min(1.5,Math.max(.03,Math.min((viewport.clientWidth-64)/(maxX-minX),(viewport.clientHeight-64)/(maxY-minY))));tx=(viewport.clientWidth-(maxX-minX)*zoom)/2-minX*zoom;ty=(viewport.clientHeight-(maxY-minY)*zoom)/2-minY*zoom;transform();}
  tools.append(button('−',()=>zoomTo(zoom/1.25)),scale,button('+',()=>zoomTo(zoom*1.25)),button('Fit',fit),el('span',`${doc.nodes.length} nodes · ${doc.edges.length} connections`,'muted'));
  const point=(n,side)=> side==='top'?[n.x+n.width/2,n.y]:side==='bottom'?[n.x+n.width/2,n.y+n.height]:side==='left'?[n.x,n.y+n.height/2]:[n.x+n.width,n.y+n.height/2];
  const direction={top:[0,-1],bottom:[0,1],left:[-1,0],right:[1,0]};
  doc.edges.forEach((e,i)=>{
    const a=byID.get(e.fromNode),b=byID.get(e.toNode),fs=e.fromSide??(a.x<b.x?'right':'left'),ts=e.toSide??(a.x<b.x?'left':'right');
    const p=point(a,fs),q=point(b,ts),d=Math.max(45,Math.hypot(q[0]-p[0],q[1]-p[1])*.35),u=direction[fs]??direction.right,v=direction[ts]??direction.left;
    const path=document.createElementNS(ns,'path');path.setAttribute('d',`M${p} C${p[0]+u[0]*d},${p[1]+u[1]*d} ${q[0]+v[0]*d},${q[1]+v[1]*d} ${q}`);path.setAttribute('stroke',color(e.color));path.setAttribute('fill','none');path.setAttribute('stroke-width','2');svg.append(path);
    for(const [at,dir,end] of [[p,u,e.fromEnd??'none'],[q,v,e.toEnd??'arrow']]) if(end==='arrow') {
      const arrow=document.createElementNS(ns,'path'),[x,y]=at,[dx,dy]=dir;
      arrow.setAttribute('d',`M${x+dx*12-dy*5},${y+dy*12+dx*5} L${x},${y} L${x+dx*12+dy*5},${y+dy*12-dx*5}`);arrow.setAttribute('stroke',color(e.color));arrow.setAttribute('fill','none');arrow.setAttribute('stroke-width','2');svg.append(arrow);
    }
    if(e.label) {const label=el('div',e.label,'edge-label');label.style.left=(p[0]+q[0])/2+'px';label.style.top=(p[1]+q[1])/2+'px';world.append(label);}
  });
  for(const n of doc.nodes) {
    const node=el('article',null,'node '+n.type);Object.assign(node.style,{left:n.x+'px',top:n.y+'px',width:n.width+'px',height:n.height+'px',borderColor:color(n.color)});
    if(n.type==='group') {node.style.backgroundColor=color(n.color)+'12';node.append(el('div',n.label??'','group-title'));if(n.background)asset(n.background,node,true,n.backgroundStyle);}
    if(n.type==='text') {const content=el('div',null,'markdown');content.innerHTML=data.html?.[n.id]??'';node.append(content);}
    if(n.type==='link') {node.append(el('span','↗','link-icon'),fileButton(n.url,n.url));}
    if(n.type==='file') {const content=el('div','Loading…','file-content');node.append(fileButton(n.file+(n.subpath??''),n.file.split('/').pop()),content);asset(n.file,content);}
    world.append(node);
  }
  if(!doc.nodes.length)viewport.append(el('p','This Canvas is empty.','empty'));
  let drag;
  viewport.onpointerdown=e=>{if(e.target.closest('button,a'))return;drag=[e.clientX,e.clientY,tx,ty];viewport.setPointerCapture(e.pointerId);};
  viewport.onpointermove=e=>{if(!drag)return;tx=drag[2]+e.clientX-drag[0];ty=drag[3]+e.clientY-drag[1];transform();};
  viewport.onpointerup=viewport.onpointercancel=()=>{drag=null;};
  viewport.onwheel=e=>{e.preventDefault();if(e.ctrlKey||e.metaKey)zoomTo(zoom*Math.exp(-e.deltaY*.01));else{tx-=e.deltaX;ty-=e.deltaY;transform();}};
  requestAnimationFrame(fit);
}
function cell(value,path) {
  const box=el('span');
  if(value && typeof value==='object' && Object.hasOwn(value,'link')) box.append(fileButton(value.link,value.label));
  else if(Array.isArray(value)) {for(const v of value)box.append(cell(v,path),document.createTextNode(' '));}
  else if(typeof value==='boolean')box.textContent=value?'✓':'—';
  else if(value instanceof Date)box.textContent=value.toLocaleDateString();
  else if(typeof value==='string'&&/^\[\[.*\]\]$/.test(value)){const [p,label]=value.slice(2,-2).split('|');box.append(fileButton(p,label??p));}
  else box.textContent=value==null?'':typeof value==='object'?JSON.stringify(value):String(value);
  return box;
}
function baseView() {
  const doc=yaml(data.source),tools=el('header');main.append(tools);
  if(!Array.isArray(doc.views))throw Error('This Base has no views.');
  const select=el('select');doc.views.forEach((v,i)=>{const o=el('option',v.name??`View ${i+1}`);o.value=i;select.append(o);});select.value=viewIndex;select.onchange=()=>{viewIndex=Number(select.value);render();};tools.append(select);
  const result=base(data.source,data.files??[],data.path,viewIndex);tools.append(el('span',`${result.rows.length} of ${result.total} files`,'muted'));
  if(data.warning)main.append(el('p',data.warning,'warning'));
  if(result.view.summaries || result.doc.summaries)main.append(el('p','Summary calculations are not supported in this preview.','warning'));
  const title=c=>result.doc.properties?.[c]?.displayName??c.replace(/^note\./,'');
  const body=el('div',null,'base-body');main.append(body);
  if(!result.rows.length){body.append(el('p','No files match this view.','empty'));return;}
  let group=Symbol(),holder,tableBody;
  for(const row of result.rows) {
    const key=JSON.stringify(row.group);
    if(group!==key){group=key;if(result.view.groupBy)body.append(el('h3',row.group??'No value'));
      holder=el('div',null,result.view.type);body.append(holder);
      if(result.view.type==='table'){const table=el('table'),head=el('tr');result.columns.forEach(c=>head.append(el('th',title(c))));const thead=el('thead');thead.append(head);tableBody=el('tbody');table.append(thead,tableBody);holder.append(table);}
    }
    if(result.view.type==='table'){const tr=el('tr');row.cells.forEach((v,i)=>{const td=el('td');td.append(result.columns[i]==='file.name'?fileButton(row.path,v):cell(v,row.path));tr.append(td);});tableBody.append(tr);}
    else {const item=el('article',null,'base-item');item.append(fileButton(row.path,row.path.split('/').pop().replace(/\.md$/i,'')));row.cells.forEach((v,i)=>{if(result.columns[i]==='file.name')return;const line=el('div',null,'property');line.append(el('span',title(result.columns[i]),'muted'),cell(v,row.path));item.append(line);});holder.append(item);}
  }
}
function render(){generation++;assets.clear();main.replaceChildren();try{data.kind==='canvas'?canvasView():baseView();}catch(e){main.append(el('p',e.message,'error'));}}
window.crowObsidian={receive(value){data=value;viewIndex=0;render();},asset(id,value){const item=assets.get(id);if(!item)return;const {target,background,style}=item;
  if(value.image){if(background){target.style.backgroundImage=`url("${value.image}")`;target.style.backgroundSize=style==='repeat'?'auto':style==='ratio'?'contain':'cover';target.style.backgroundRepeat=style==='repeat'?'repeat':'no-repeat';}else{target.replaceChildren();const img=el('img');img.src=value.image;target.append(img);}}
  else if(!background){target.replaceChildren();if(value.html){const div=el('div',null,'markdown');div.innerHTML=value.html;target.append(div);}else target.textContent=value.error??'Open this file to view it.';}
}};
document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();open(a.getAttribute('href'));}});
