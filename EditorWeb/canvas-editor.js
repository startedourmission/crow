import {canvas, serializeCanvas} from './obsidian-model.js';
import {el, button, iconButton, field, input, select, dialog, actions, color} from './obsidian-ui.js';

let currentPath, camera, selected;
const uid = () => Array.from(crypto.getRandomValues(new Uint8Array(8)), byte => byte.toString(16).padStart(2, '0')).join('');
export function canvasEditor(ctx) {
  const doc = canvas(ctx.data.source);
  if (currentPath !== ctx.data.path) { currentPath = ctx.data.path; camera = null; selected = null; }
  if (!camera) camera = {x:0, y:0, zoom:1};
  const header = el('header', null, 'document-toolbar canvas-toolbar');
  const creationBar = el('div', null, 'canvas-create');
  const viewport = el('div', null, 'canvas-viewport'), world = el('div', null, 'canvas-world');
  const selectionBar = el('div', null, 'selection-toolbar');
  const byID = new Map(doc.nodes.map(n => [n.id, n])), elements = new Map();
  let drag, frame, destroyed = false;
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.classList.add('edges'); world.append(svg); viewport.append(world, selectionBar);
  ctx.main.append(header, viewport);
  const commit = () => ctx.change(serializeCanvas(doc));
  const center = () => ({x:Math.round((viewport.clientWidth / 2 - camera.x) / camera.zoom), y:Math.round((viewport.clientHeight / 2 - camera.y) / camera.zoom)});
  const add = (type, extra = {}) => {
    const point = center(), id = uid(), width = type === 'group' ? 560 : 320, height = type === 'group' ? 360 : 200;
    const node = {id, type, x:point.x - width / 2, y:point.y - height / 2, width, height, ...extra};
    if (type === 'group') doc.nodes.unshift(node); else doc.nodes.push(node);
    selected = {kind:'node', id}; commit();
    if (type === 'text') requestAnimationFrame(() => document.querySelector('[data-node-id="' + id + '"]')?.dispatchEvent(new MouseEvent('dblclick', {bubbles:true})));
  };
  creationBar.append(
    iconButton('note', 'Add text card', () => add('text', {text:''}), 'Note'),
    iconButton('file', 'Add file card', () => addDialog('file')),
    iconButton('link', 'Add link card', () => addDialog('link')),
    iconButton('group', 'Add group', () => add('group', {label:'Group', color:'5'}))
  );
  creationBar.querySelector('button').dataset.action = 'add-note';
  viewport.append(creationBar);
  ctx.tools(header);

  const zoomTools = el('div', null, 'canvas-zoom'), zoomLabel = el('span', '100%', 'zoom-label');
  zoomTools.append(iconButton('minus', 'Zoom out', () => zoomTo(camera.zoom / 1.2)), zoomLabel,
    iconButton('plus', 'Zoom in', () => zoomTo(camera.zoom * 1.2)), iconButton('fit', 'Fit canvas', fit));
  viewport.append(zoomTools);
  function transform() {
    world.style.transform = 'translate(' + camera.x + 'px,' + camera.y + 'px) scale(' + camera.zoom + ')';
    viewport.style.backgroundPosition = camera.x + 'px ' + camera.y + 'px';
    viewport.style.backgroundSize = (24 * camera.zoom) + 'px ' + (24 * camera.zoom) + 'px';
    zoomLabel.textContent = Math.round(camera.zoom * 100) + '%';
    positionSelection();
  }
  function zoomTo(next, x = viewport.clientWidth / 2, y = viewport.clientHeight / 2) {
    next = Math.min(4, Math.max(.05, next));
    camera.x = x - (x - camera.x) * next / camera.zoom;
    camera.y = y - (y - camera.y) * next / camera.zoom;
    camera.zoom = next; transform();
  }
  function fit() {
    if (!viewport.clientWidth || !viewport.clientHeight) return;
    if (!doc.nodes.length) { camera = {x:viewport.clientWidth / 2, y:viewport.clientHeight / 2, zoom:1}; transform(); return; }
    const left = Math.min(...doc.nodes.map(n => n.x)), top = Math.min(...doc.nodes.map(n => n.y));
    const width = Math.max(...doc.nodes.map(n => n.x + n.width)) - left;
    const height = Math.max(...doc.nodes.map(n => n.y + n.height)) - top;
    const zoom = Math.max(.05, Math.min(1, (viewport.clientWidth - 100) / width, (viewport.clientHeight - 110) / height));
    camera = {zoom, x:(viewport.clientWidth - width * zoom) / 2 - left * zoom, y:(viewport.clientHeight - height * zoom) / 2 - top * zoom};
    transform();
    camera.fitted = true;
  }
  function addDialog(type) {
    dialog(type === 'file' ? 'Add file' : 'Add link', (form, close) => {
      const value = input(); value.placeholder = type === 'file' ? 'Notes/Example.md' : 'https://';
      form.append(field(type === 'file' ? 'Workspace file' : 'URL', value));
      actions(form, close, () => {
        if (!value.value.trim()) throw Error('Enter a file path or URL.');
        add(type, {[type === 'file' ? 'file' : 'url']:value.value.trim()});
      }, 'Add');
    });
  }
  const point = (node, side) => side === 'top' ? [node.x + node.width / 2, node.y] : side === 'bottom' ? [node.x + node.width / 2, node.y + node.height] :
    side === 'left' ? [node.x, node.y + node.height / 2] : [node.x + node.width, node.y + node.height / 2];
  const directions = {top:[0,-1], bottom:[0,1], left:[-1,0], right:[1,0]};
  function svgPath(d, stroke, width = 2, cls = '') {
    const path = document.createElementNS(svg.namespaceURI, 'path');
    path.setAttribute('d', d); path.setAttribute('stroke', stroke); path.setAttribute('fill', 'none'); path.setAttribute('stroke-width', width);
    if (cls) path.setAttribute('class', cls); svg.append(path); return path;
  }
  function drawEdges() {
    svg.replaceChildren(); world.querySelectorAll('.edge-label').forEach(n => n.remove());
    doc.edges.forEach(edge => {
      const a = byID.get(edge.fromNode), b = byID.get(edge.toNode);
      const fs = edge.fromSide ?? (a.x < b.x ? 'right' : 'left'), ts = edge.toSide ?? (a.x < b.x ? 'left' : 'right');
      const p = point(a, fs), q = point(b, ts), u = directions[fs] ?? directions.right, v = directions[ts] ?? directions.left;
      const distance = Math.max(50, Math.hypot(q[0] - p[0], q[1] - p[1]) * .4);
      const d = 'M' + p + ' C' + [p[0] + u[0] * distance, p[1] + u[1] * distance] + ' ' +
        [q[0] + v[0] * distance, q[1] + v[1] * distance] + ' ' + q;
      const active = selected?.kind === 'edge' && selected.id === edge.id;
      svgPath(d, active ? 'var(--accent)' : color(edge.color), active ? 3 : 2);
      const hit = svgPath(d, 'transparent', 16, 'edge-hit');
      hit.onclick = e => { e.stopPropagation(); choose({kind:'edge', id:edge.id}); drawEdges(); };
      hit.ondblclick = e => { e.stopPropagation(); editEdge(edge); };
      for (const [at, direction, end] of [[p,u,edge.fromEnd ?? 'none'], [q,v,edge.toEnd ?? 'arrow']]) {
        if (end !== 'arrow') continue;
        const [x,y] = at, [dx,dy] = direction;
        svgPath('M' + [x + dx * 11 - dy * 5, y + dy * 11 + dx * 5] + ' L' + at + ' L' + [x + dx * 11 + dy * 5,y + dy * 11 - dx * 5], color(edge.color));
      }
      if (edge.label) {
        const label = el('button', edge.label, 'edge-label');
        label.style.left = (p[0] + q[0]) / 2 + 'px'; label.style.top = (p[1] + q[1]) / 2 + 'px';
        label.onclick = () => { choose({kind:'edge', id:edge.id}); editEdge(edge); }; world.append(label);
      }
    });
    if (drag?.type === 'connect' && drag.to) {
      const from = point(byID.get(drag.id), drag.side);
      const to = drag.to, direction = directions[drag.side], end = directions[drag.target?.side] ?? [0,0];
      const bend = Math.max(50,Math.hypot(to[0]-from[0],to[1]-from[1])*.4);
      svgPath('M' + from + ' C' + [from[0]+direction[0]*bend,from[1]+direction[1]*bend] + ' ' +
        [to[0]+end[0]*bend,to[1]+end[1]*bend] + ' ' + to, 'var(--accent)', 2, 'pending-edge');
    }
  }
  function position(node) {
    Object.assign(elements.get(node.id).style, {left:node.x + 'px', top:node.y + 'px', width:node.width + 'px', height:node.height + 'px'});
  }
  function choose(value) {
    selected = value;
    for (const [id, element] of elements) element.classList.toggle('selected', value?.kind === 'node' && value.id === id);
    selectionBar.replaceChildren(); selectionBar.hidden = !value;
    if (!value) return;
    const item = value.kind === 'node' ? byID.get(value.id) : doc.edges.find(e => e.id === value.id);
    if (!item) { selected = null; selectionBar.hidden = true; return; }
    const picker = input(color(item.color), 'color'); picker.title = 'Color'; picker.setAttribute('aria-label','Color');
    picker.onchange = () => { item.color = picker.value; commit(); };
    selectionBar.append(iconButton('trash', 'Delete selected ' + value.kind, remove), picker,
      iconButton('edit', 'Edit selected ' + value.kind, () => value.kind === 'node' ? editNode(item) : editEdge(item)));
    if (value.kind === 'node') selectionBar.append(iconButton('fit','Focus card',()=>{
      const zoom=Math.min(1.5,(viewport.clientWidth-100)/item.width,(viewport.clientHeight-150)/item.height);
      camera={zoom:Math.max(.05,zoom),x:viewport.clientWidth/2-(item.x+item.width/2)*zoom,y:viewport.clientHeight/2-(item.y+item.height/2)*zoom,fitted:true}; transform();
    }));
    positionSelection();
  }
  function positionSelection() {
    const node = selected?.kind === 'node' ? byID.get(selected.id) : null;
    const x = node ? (node.x + node.width / 2) * camera.zoom + camera.x : viewport.clientWidth / 2;
    const y = node ? node.y * camera.zoom + camera.y - 52 : 12;
    selectionBar.style.left = Math.max(8, Math.min(x - selectionBar.offsetWidth / 2, viewport.clientWidth - selectionBar.offsetWidth - 8)) + 'px';
    selectionBar.style.top = Math.max(8, Math.min(y, viewport.clientHeight - 100)) + 'px';
  }
  function connectionTarget(e) {
    const hit = document.elementFromPoint(e.clientX,e.clientY), element = hit?.closest('[data-node-id]');
    const id = element?.dataset.nodeId;
    if (!id || id === drag?.id) return null;
    const node = byID.get(id); if (!node) return null;
    let side = hit.closest('.node-port')?.dataset.side;
    if (!side) {
      const bounds=viewport.getBoundingClientRect(), x=(e.clientX-bounds.left-camera.x)/camera.zoom, y=(e.clientY-bounds.top-camera.y)/camera.zoom;
      side=Object.keys(directions).sort((a,b)=>{
        const p=point(node,a),q=point(node,b); return Math.hypot(p[0]-x,p[1]-y)-Math.hypot(q[0]-x,q[1]-y);
      })[0];
    }
    return {id,side};
  }
  function markTarget(target) {
    for (const [id,element] of elements) {
      element.classList.toggle('connection-target',id===target?.id);
      element.querySelectorAll('.node-port').forEach(port=>port.classList.toggle('connection-port',id===target?.id && port.dataset.side===target.side));
    }
  }
  function clearConnection() { viewport.classList.remove('connecting'); markTarget(null); }
  function remove() {
    if (!selected) return;
    if (selected.kind === 'node') {
      doc.nodes = doc.nodes.filter(n => n.id !== selected.id);
      doc.edges = doc.edges.filter(e => e.fromNode !== selected.id && e.toNode !== selected.id);
    } else doc.edges = doc.edges.filter(e => e.id !== selected.id);
    selected = null; commit();
  }
  function editEdge(edge) {
    dialog('Connection', (form, close) => {
      const label = input(edge.label ?? ''), start = select([['none','None'],['arrow','Arrow']], edge.fromEnd ?? 'none'),
        end = select([['none','None'],['arrow','Arrow']], edge.toEnd ?? 'arrow');
      form.append(field('Label', label), field('Start', start), field('End', end));
      actions(form, close, () => { edge.label = label.value; edge.fromEnd = start.value; edge.toEnd = end.value; commit(); });
    });
  }
  function editNode(node) {
    if (node.type !== 'text') {
      dialog(node.type === 'group' ? 'Group' : node.type === 'file' ? 'File card' : 'Link card', (form, close) => {
        const key = node.type === 'group' ? 'label' : node.type === 'file' ? 'file' : 'url', value = input(node[key] ?? '');
        form.append(field(key === 'label' ? 'Name' : key === 'file' ? 'Workspace file' : 'URL', value));
        actions(form, close, () => { node[key] = value.value; commit(); });
      }); return;
    }
    const content = elements.get(node.id).querySelector('.node-content');
    if (content.dataset.editing === 'true') return;
    const before = ctx.data.source, editor = el('textarea', null, 'node-editor');
    editor.value = node.text ?? ''; editor.placeholder = 'Write a note…'; editor.setAttribute('aria-label', 'Card text');
    content.dataset.editing = 'true'; content.replaceChildren(editor);
    editor.oninput = () => { node.text = editor.value; ctx.change(serializeCanvas(doc), {render:false, history:false}); };
    editor.onblur = () => {
      ctx.record(before, ctx.data.source); content.dataset.editing = 'false'; content.replaceChildren();
      ctx.asset(node.text ?? '', content, false, 'cover', true);
    };
    editor.onkeydown = e => { if (e.key === 'Escape') { e.preventDefault(); editor.blur(); } };
    editor.focus(); editor.setSelectionRange(editor.value.length, editor.value.length);
  }
  function begin(e, type, node, side) {
    if (e.button !== 0) return;
    document.activeElement?.blur();
    e.preventDefault(); e.stopPropagation(); choose({kind:'node', id:node.id});
    const moving = type === 'move' ? doc.nodes.filter(n => n.id === node.id || node.type === 'group' && n.x >= node.x && n.y >= node.y &&
      n.x + n.width <= node.x + node.width && n.y + n.height <= node.y + node.height) : [node];
    drag = {type, id:node.id, side, x:e.clientX, y:e.clientY, width:node.width, height:node.height,
      positions:moving.map(n => [n, n.x, n.y]), moved:false, pointerId:e.pointerId};
    if (type === 'connect') viewport.classList.add('connecting');
    viewport.setPointerCapture(e.pointerId);
  }
  doc.nodes.forEach((node, index) => {
    const element = el('article', null, 'node ' + node.type); element.dataset.nodeId = node.id;
    element.style.zIndex = index + 1; element.style.setProperty('--node-color', color(node.color));
    const bar = el('div', null, 'node-bar'), title = node.type === 'text' ? 'Note' : node.type === 'group' ? node.label || 'Group' :
      node.type === 'file' ? node.file?.split('/').pop() : 'Link';
    bar.append(el('span', title)); bar.onpointerdown = e => begin(e, 'move', node);
    const content = el('div', null, 'node-content');
    element.append(bar, content); elements.set(node.id, element); position(node); world.append(element);
    element.onclick = e => { if (!e.target.closest('button,a,input,textarea')) choose({kind:'node', id:node.id}); };
    element.ondblclick = e => { if (!e.target.closest('button,a,input,textarea')) { e.stopPropagation(); choose({kind:'node',id:node.id}); editNode(node); } };
    if (node.type === 'text') {
      content.classList.add('markdown');
      if (node.text) ctx.asset(node.text, content, false, 'cover', true);
      else content.append(el('span', 'Double-click to write…', 'placeholder'));
    } else if (node.type === 'file') {
      bar.append(iconButton('arrow', 'Open file', () => ctx.open(node.file + (node.subpath ?? ''))));
      ctx.asset(node.file, content);
    } else if (node.type === 'link') {
      content.append(iconButton('link', 'Open link', () => ctx.open(node.url), node.url || 'Link'));
    } else {
      content.remove();
      if (node.background) ctx.asset(node.background, element, true, node.backgroundStyle);
    }
    const handle = el('button', null, 'node-resize'); handle.setAttribute('aria-label', 'Resize card');
    handle.onpointerdown = e => begin(e, 'resize', node); element.append(handle);
    for (const side of ['top','right','bottom','left']) {
      const port = el('button', null, 'node-port ' + side); port.dataset.side = side;
      port.setAttribute('aria-label','Connect from ' + side); port.onpointerdown = e => begin(e, 'connect', node, side);
      element.append(port);
    }
  });
  choose(selected); drawEdges();
  if (!doc.nodes.length) viewport.append(el('div', 'Add a note to start your canvas', 'canvas-empty'));
  viewport.onpointerdown = e => {
    if (e.target.closest('.node,button,input,textarea,.selection-toolbar,.canvas-zoom,.edge-hit')) return;
    choose(null); drag = {type:'pan', x:e.clientX, y:e.clientY, cx:camera.x, cy:camera.y};
    viewport.setPointerCapture(e.pointerId);
  };
  viewport.onpointermove = e => {
    if (!drag) return;
    const dx = (e.clientX - drag.x) / camera.zoom, dy = (e.clientY - drag.y) / camera.zoom;
    if (Math.abs(dx) + Math.abs(dy) > 2) drag.moved = true;
    if (drag.type === 'pan') { camera.x = drag.cx + e.clientX - drag.x; camera.y = drag.cy + e.clientY - drag.y; transform(); }
    if (drag.type === 'move') for (const [node,x,y] of drag.positions) {
      node.x = Math.round(x + dx); node.y = Math.round(y + dy); position(node);
    }
    if (drag.type === 'resize') {
      const node = byID.get(drag.id); node.width = Math.max(160, Math.round(drag.width + dx));
      node.height = Math.max(100, Math.round(drag.height + dy)); position(node);
    }
    if (drag.type === 'connect') {
      const bounds = viewport.getBoundingClientRect();
      drag.target = connectionTarget(e); markTarget(drag.target);
      drag.to = drag.target ? point(byID.get(drag.target.id),drag.target.side) : [(e.clientX - bounds.left - camera.x) / camera.zoom, (e.clientY - bounds.top - camera.y) / camera.zoom];
    }
    positionSelection();
    cancelAnimationFrame(frame); frame = requestAnimationFrame(drawEdges);
  };
  viewport.onpointerup = e => {
    const target = drag?.type === 'connect' ? connectionTarget(e) : null;
    const previous = drag; drag = null; clearConnection();
    if (!previous) return;
    if (previous.type === 'connect') {
      if (target) {
        const edge = {id:uid(), fromNode:previous.id, fromSide:previous.side, toNode:target.id, toSide:target.side};
        doc.edges.push(edge); selected = {kind:'edge',id:edge.id}; commit(); return;
      }
      drawEdges();
    } else if (previous.moved && previous.type !== 'pan') commit();
  };
  viewport.onpointercancel = () => { drag = null; clearConnection(); ctx.render(); };
  viewport.addEventListener('wheel', e => {
    if (e.target.closest('textarea,.node-content') && !(e.ctrlKey || e.metaKey)) return;
    e.preventDefault(); const bounds = viewport.getBoundingClientRect();
    if (e.ctrlKey || e.metaKey) zoomTo(camera.zoom * Math.exp(-e.deltaY * .01), e.clientX - bounds.left, e.clientY - bounds.top);
    else { camera.x -= e.deltaX; camera.y -= e.deltaY; transform(); }
  }, {passive:false});
  const resize = new ResizeObserver(() => { if (!camera.fitted) fit(); });
  resize.observe(viewport);
  // Apply on every rebuild, including when WebKit throttles animation frames.
  if (!camera.fitted) fit(); else transform();
  requestAnimationFrame(() => { if (!destroyed) { if (!camera.fitted) fit(); else transform(); } });
  return {
    key(e) { if (['Delete','Backspace'].includes(e.key) && selected) { e.preventDefault(); remove(); } if (e.key === 'Escape') {
      if (drag) { const id=drag.pointerId; drag=null; clearConnection(); if (id != null && viewport.hasPointerCapture(id)) viewport.releasePointerCapture(id); ctx.render(); }
      else { choose(null); drawEdges(); }
    } },
    destroy() { destroyed = true; resize.disconnect(); cancelAnimationFrame(frame); }
  };
}
