// JSON Canvas editor with Obsidian's interaction model.
import {canvas, serializeCanvas, drawableNodes, knownNodeType} from './obsidian-model.js';
import {el, button, icon, iconButton, field, input, dialog, actions, color, presetColors, presetNames, menu, closeMenus, popover, closePopover} from './obsidian-ui.js';
import {renderMarkdown, hydrate, stripFrontmatter, subpathText, toggleTask} from './markdown-render.js';
import {mountEmbed} from './obsidian-embed.js';

const GRID = 20, MIN_W = 50, MIN_H = 30;
const states = new Map();
const uid = () => Array.from(crypto.getRandomValues(new Uint8Array(8)), b => b.toString(16).padStart(2, '0')).join('');
const imageExt = /\.(png|jpe?g|gif|webp|bmp|svg|heic|tiff?|avif)$/i, audioExt = /\.(mp3|wav|m4a|ogg|flac|aac|webm)$/i, videoExt = /\.(mp4|mov|m4v|mkv|avi|ogv)$/i;
const sides = ['top', 'right', 'bottom', 'left'];
const direction = {top:[0, -1], right:[1, 0], bottom:[0, 1], left:[-1, 0]};
const fileIcon = path => imageExt.test(path) ? 'image' : /\.pdf$/i.test(path) ? 'pdf' : audioExt.test(path) ? 'audio' : videoExt.test(path) ? 'video' : /\.canvas$/i.test(path) ? 'frame' : /\.base$/i.test(path) ? 'table' : 'file';

export function canvasEditor(ctx) {
  const path = ctx.data.path;
  const state = states.get(path) ?? {camera:null, selection:[], snapGrid:true, snapObjects:true};
  states.set(path, state);
  const doc = canvas(ctx.data.source);
  let nodes = drawableNodes(doc), byId = new Map(nodes.map(n => [n.id, n]));
  const edgeValid = e => e && byId.has(e.fromNode) && byId.has(e.toNode);
  let camera = state.camera ?? {x:0, y:0, zoom:1};
  let selected = new Set(state.selection.filter(id => byId.has(id) || doc.edges.some(e => e?.id === id)));
  let editing = null, drag = null, spaceDown = false, destroyed = false, pointer = {x:0, y:0};

  // ---------------------------------------------------------------- DOM
  const viewport = el('div', null, 'canvas-viewport'); viewport.tabIndex = 0; viewport.setAttribute('aria-label', 'Canvas');
  const world = el('div', null, 'canvas-world');
  const groupLayer = el('div', null, 'canvas-layer groups');
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.classList.add('canvas-edges');
  const nodeLayer = el('div', null, 'canvas-layer cards'), labelLayer = el('div', null, 'canvas-layer labels');
  world.append(groupLayer, svg, nodeLayer, labelLayer);
  const overlay = el('div', null, 'canvas-overlay'), marquee = el('div', null, 'canvas-marquee'); marquee.hidden = true;
  const guides = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); guides.classList.add('canvas-guides');
  const toolbar = el('div', null, 'canvas-selection-menu'); toolbar.hidden = true;
  overlay.append(guides, marquee, toolbar);
  viewport.append(world, overlay);
  ctx.main.append(viewport);
  if (doc.issues.length) { const note = el('div', doc.issues.slice(0, 2).join(' ') + (doc.issues.length > 2 ? ' …' : '') + ' They are kept when saving.', 'canvas-issues'); note.title = doc.issues.join('\n'); note.onpointerdown = e => { e.stopPropagation(); note.remove(); }; viewport.append(note); }

  // Creation bar (bottom) and controls (right), as in Obsidian.
  const create = el('div', null, 'canvas-create');
  const createButton = (glyph, label, action) => { const b = iconButton(glyph, label, action); b.onpointerdown = e => e.stopPropagation(); return b; };
  create.append(
    createButton('note', 'Add card', () => addNode('text', {text:''}, null, true)),
    createButton('file', 'Add note from vault', () => pickFile('note')),
    createButton('image', 'Add media from vault', () => pickFile('media')),
    createButton('globe', 'Add web page', () => askLink()),
    createButton('group', 'Add group', () => selectionNodes().length ? groupSelection() : addNode('group', {label:''}))
  );
  create.firstChild.dataset.action = 'add-note';
  const controls = el('div', null, 'canvas-controls'), zoomLabel = button('100%', () => zoomTo(1), 'zoom-label');
  zoomLabel.title = 'Reset zoom';
  const history = el('div', null, 'canvas-history'); ctx.tools(history); history.querySelector('.toolbar-spacer, .toolbar-gap')?.remove();
  controls.append(iconButton('plus', 'Zoom in (⌘=)', () => zoomTo(camera.zoom * 1.25)), zoomLabel, iconButton('minus', 'Zoom out (⌘-)', () => zoomTo(camera.zoom / 1.25)),
    iconButton('fit', 'Zoom to fit (⇧1)', () => fit()), el('div', null, 'control-separator'), ...history.children,
    el('div', null, 'control-separator'), iconButton('settings', 'Canvas settings', e => menu(e.currentTarget, [
      {label:'Snap to grid', checked:state.snapGrid, action:() => { state.snapGrid = !state.snapGrid; }},
      {label:'Snap to objects', checked:state.snapObjects, action:() => { state.snapObjects = !state.snapObjects; }},
      'separator', {label:'Zoom to selection (⇧2)', disabled:!selected.size, action:() => zoomToSelection()}])));
  for (const b of controls.querySelectorAll('button')) b.addEventListener('pointerdown', e => e.stopPropagation());
  viewport.append(create, controls);

  // ---------------------------------------------------------------- camera
  function applyCamera() {
    world.style.transform = 'translate(' + camera.x + 'px,' + camera.y + 'px) scale(' + camera.zoom + ')';
    const size = GRID * camera.zoom;
    viewport.style.backgroundSize = size + 'px ' + size + 'px';
    viewport.style.backgroundPosition = camera.x + 'px ' + camera.y + 'px';
    viewport.classList.toggle('zoomed-out', camera.zoom < 0.35);
    viewport.style.setProperty('--zoom', camera.zoom);
    zoomLabel.textContent = Math.round(camera.zoom * 100) + '%';
    state.camera = camera; placeToolbar();
  }
  const toWorld = (clientX, clientY) => { const r = viewport.getBoundingClientRect(); return {x:(clientX - r.left - camera.x) / camera.zoom, y:(clientY - r.top - camera.y) / camera.zoom}; };
  function zoomTo(next, cx = viewport.clientWidth / 2, cy = viewport.clientHeight / 2) {
    next = Math.min(4, Math.max(0.05, next));
    camera = {x:cx - (cx - camera.x) * next / camera.zoom, y:cy - (cy - camera.y) * next / camera.zoom, zoom:next}; applyCamera();
  }
  function frame(list, maxZoom = 1) {
    const w = viewport.clientWidth, h = viewport.clientHeight; if (!w || !h) return false;
    // An empty canvas is centered but not remembered, so content that loads later is fitted.
    if (!list.length) { camera = {x:w / 2, y:h / 2, zoom:1}; applyCamera(); state.camera = null; return false; }
    const b = bounds(list), zoom = Math.max(0.05, Math.min(maxZoom, (w - 120) / Math.max(b.w, 1), (h - 160) / Math.max(b.h, 1)));
    camera = {zoom, x:(w - b.w * zoom) / 2 - b.x * zoom, y:(h - b.h * zoom) / 2 - b.y * zoom - 10}; applyCamera(); return true;
  }
  const fit = () => { if (frame(nodes)) state.fitted = true; };
  const zoomToSelection = () => frame(selectionNodes().length ? selectionNodes() : nodes, 1.5);
  function bounds(list) {
    const x = Math.min(...list.map(n => n.x)), y = Math.min(...list.map(n => n.y));
    return {x, y, w:Math.max(...list.map(n => n.x + n.width)) - x, h:Math.max(...list.map(n => n.y + n.height)) - y};
  }

  // ---------------------------------------------------------------- persistence
  function commit(history = true) { if (destroyed) return; ctx.change(serializeCanvas(doc), {render:false, history}); state.selection = [...selected]; }
  const beforeEdit = () => ctx.data.source;

  // ---------------------------------------------------------------- nodes
  const elements = new Map(), embeds = new Map();
  let observer = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.isIntersecting) { const id = entry.target.dataset.nodeId; observer.unobserve(entry.target); fill(byId.get(id)); }
  }, {root:viewport, rootMargin:'400px'});
  function nodeColor(node) { return node.color ? color(node.color) : null; }
  function paintNode(node) {
    const element = elements.get(node.id); if (!element) return;
    Object.assign(element.style, {left:node.x + 'px', top:node.y + 'px', width:node.width + 'px', height:node.height + 'px'});
    const c = nodeColor(node);
    element.classList.toggle('colored', !!c);
    if (c) element.style.setProperty('--node-color', c); else element.style.removeProperty('--node-color');
    element.classList.toggle('selected', selected.has(node.id));
  }
  function nodeLabel(node) {
    if (node.type === 'group') return node.label ?? '';
    if (node.type === 'file') return (node.file ?? '').split('/').pop() + (node.subpath ?? '');
    return '';
  }
  function build(node) {
    const element = el('div', null, 'cnode type-' + (knownNodeType(node.type) ? node.type : 'unknown')); element.dataset.nodeId = node.id;
    if (node.type === 'group' || node.type === 'file') {
      const label = el('div', nodeLabel(node) || (node.type === 'group' ? '' : 'File'), 'cnode-label');
      if (node.type === 'group' && !node.label) label.classList.add('empty');
      element.append(label);
    }
    const body = el('div', null, 'cnode-body'); element.append(body);
    for (const side of sides) { const port = el('div', null, 'cnode-port ' + side); port.dataset.side = side; element.append(port); }
    for (const h of ['n', 'e', 's', 'w', 'ne', 'nw', 'se', 'sw']) { const handle = el('div', null, 'cnode-resize ' + h); handle.dataset.handle = h; element.append(handle); }
    elements.set(node.id, element);
    (node.type === 'group' ? groupLayer : nodeLayer).append(element);
    paintNode(node); element.style.zIndex = String(doc.nodes.indexOf(node) + 1);
    observer.observe(element);
    return element;
  }
  function fill(node) {
    const element = elements.get(node?.id); if (!element || editing?.id === node.id) return;
    const body = element.querySelector('.cnode-body'); body.replaceChildren(); body.className = 'cnode-body';
    if (node.type === 'text') {
      if (!node.text) { body.append(el('span', '', 'cnode-placeholder')); return; }
      body.classList.add('markdown'); body.innerHTML = renderMarkdown(node.text);
      hydrate(body, {...linkHandlers(), onTask:(index, checked) => { node.text = toggleTask(node.text, index, checked); commit(); }});
    } else if (node.type === 'file') {
      const file = node.file ?? '';
      if (!file) { body.append(el('div', 'No file', 'cnode-missing')); return; }
      body.classList.add('file-' + fileIcon(file));
      // Bases render live inside their card, as in Obsidian.
      if (/\.base$/i.test(file) && !ctx.embedded) {
        const holder = el('div', null, 'cnode-embed'); body.append(holder);
        embeds.get(node.id)?.destroy();
        embeds.set(node.id, mountEmbed(holder, {kind:'base', file, view:node.subpath ? node.subpath.replace(/^#/, '') : null, key:path + '#' + node.id}));
        return;
      }
      ctx.load({action:'asset', path:file}).then(value => {
        if (!element.isConnected || editing?.id === node.id) return;
        body.replaceChildren();
        if (value.image) {
          const img = el('img'); img.src = value.image; img.alt = file; img.draggable = false; body.append(img);
          if (value.kind === 'pdf') body.append(fileBadge(file));
        } else if (typeof value.text === 'string') {
          body.classList.add('markdown');
          const text = subpathText(stripFrontmatter(value.text), node.subpath);
          body.innerHTML = renderMarkdown(text); hydrate(body, linkHandlers());
        } else if (value.kind || value.error) {
          const box = el('div', null, 'cnode-file-icon'); box.append(icon(fileIcon(file)), el('span', file.split('/').pop()));
          if (value.error && !value.kind) box.append(el('small', value.error, 'cnode-error'));
          body.append(box);
        }
      });
    } else if (node.type === 'link') {
      const url = node.url ?? '';
      const card = el('div', null, 'link-preview');
      const host = (() => { try { return new URL(url).hostname.replace(/^www\./, ''); } catch { return url; } })();
      const titleNode = el('div', host, 'link-title'), desc = el('div', '', 'link-description'), site = el('div', null, 'link-site');
      site.append(icon('globe'), el('span', host));
      const cover = el('div', null, 'link-image'); cover.hidden = true;
      card.append(cover, titleNode, desc, site); body.append(card);
      card.ondblclick = e => { e.stopPropagation(); ctx.open(url); };
      if (/^https?:\/\//i.test(url)) ctx.load({action:'linkPreview', url}).then(value => {
        if (value.title) titleNode.textContent = value.title;
        if (value.description) desc.textContent = value.description;
        if (value.site) site.lastChild.textContent = value.site;
        if (value.image) { cover.hidden = false; ctx.asset(value.image, cover); }
      });
    } else if (node.type === 'group') {
      if (node.background) { body.classList.add('background'); ctx.asset(node.background, body, true, node.backgroundStyle ?? 'cover'); }
    } else {
      const box = el('div', null, 'cnode-file-icon'); box.append(icon('layers'), el('span', String(node.type ?? 'Unknown') + ' card'), el('small', 'Added by a plugin. Kept as is.', 'muted')); body.append(box);
    }
  }
  function fileBadge(file) { const badge = el('div', null, 'file-badge'); badge.append(icon(fileIcon(file)), el('span', file.split('/').pop())); return badge; }
  function linkHandlers() {
    return {open:url => ctx.open(url), openWiki:target => ctx.openWiki(target), asset:(src, holder) => ctx.asset(src, holder)};
  }
  function rebuildNode(node) { embeds.get(node.id)?.destroy(); embeds.delete(node.id); elements.get(node.id)?.remove(); elements.delete(node.id); build(node); fill(node); }

  // ---------------------------------------------------------------- edges
  const edgeElements = new Map();
  function autoSides(a, b) {
    const ax = a.x + a.width / 2, ay = a.y + a.height / 2, bx = b.x + b.width / 2, by = b.y + b.height / 2, dx = bx - ax, dy = by - ay;
    return Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? ['right', 'left'] : ['left', 'right']) : (dy > 0 ? ['bottom', 'top'] : ['top', 'bottom']);
  }
  const anchor = (node, side) => side === 'top' ? [node.x + node.width / 2, node.y] : side === 'bottom' ? [node.x + node.width / 2, node.y + node.height] :
    side === 'left' ? [node.x, node.y + node.height / 2] : [node.x + node.width, node.y + node.height / 2];
  function curve(p, fromSide, q, toSide) {
    const dist = Math.hypot(q[0] - p[0], q[1] - p[1]), k = Math.min(Math.max(dist * 0.5, 40), 300);
    const u = direction[fromSide] ?? [0, 0], v = direction[toSide] ?? [0, 0];
    const c1 = [p[0] + u[0] * k, p[1] + u[1] * k], c2 = [q[0] + v[0] * k, q[1] + v[1] * k];
    return {d:'M' + p + ' C' + c1 + ' ' + c2 + ' ' + q, mid:[(p[0] + 3 * c1[0] + 3 * c2[0] + q[0]) / 8, (p[1] + 3 * c1[1] + 3 * c2[1] + q[1]) / 8], c1, c2};
  }
  const arrow = (at, from) => {
    const dx = at[0] - from[0], dy = at[1] - from[1], len = Math.hypot(dx, dy) || 1, ux = dx / len, uy = dy / len, s = 12, w = 6;
    return 'M' + at + ' L' + [at[0] - ux * s - uy * w, at[1] - uy * s + ux * w] + ' L' + [at[0] - ux * s + uy * w, at[1] - uy * s - ux * w] + 'Z';
  };
  function edgeGeometry(edge) {
    const a = byId.get(edge.fromNode), b = byId.get(edge.toNode), auto = autoSides(a, b);
    const fromSide = edge.fromSide ?? auto[0], toSide = edge.toSide ?? auto[1];
    const p = anchor(a, fromSide), q = anchor(b, toSide);
    return {p, q, fromSide, toSide, ...curve(p, fromSide, q, toSide)};
  }
  const svgEl = (name, attrs) => { const node = document.createElementNS(svg.namespaceURI, name); for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v); return node; };
  function drawEdge(edge) {
    let entry = edgeElements.get(edge);
    if (!entry) {
      const g = svgEl('g', {class:'cedge'}), path = svgEl('path', {class:'cedge-path', fill:'none'}), hit = svgEl('path', {class:'cedge-hit', fill:'none'});
      const start = svgEl('path', {class:'cedge-arrow'}), end = svgEl('path', {class:'cedge-arrow'});
      g.append(path, start, end, hit); svg.append(g);
      hit.addEventListener('pointerdown', e => edgePointer(e, edge));
      hit.addEventListener('dblclick', e => { e.stopPropagation(); editEdgeLabel(edge); });
      hit.addEventListener('contextmenu', e => { e.preventDefault(); e.stopPropagation(); choose([edge.id]); edgeMenu(edge, {x:e.clientX, y:e.clientY}); });
      entry = {g, path, hit, start, end, label:null}; edgeElements.set(edge, entry);
    }
    const geo = edgeGeometry(edge), stroke = edge.color ? color(edge.color) : 'var(--edge)';
    entry.g.style.setProperty('--edge-color', stroke);
    entry.g.classList.toggle('selected', selected.has(edge.id));
    for (const p of [entry.path, entry.hit]) p.setAttribute('d', geo.d);
    const fromEnd = edge.fromEnd ?? 'none', toEnd = edge.toEnd ?? 'arrow';
    entry.start.setAttribute('d', fromEnd === 'arrow' ? arrow(geo.p, geo.c1) : ''); entry.end.setAttribute('d', toEnd === 'arrow' ? arrow(geo.q, geo.c2) : '');
    if (edge.label) {
      if (!entry.label) {
        entry.label = el('div', null, 'cedge-label'); labelLayer.append(entry.label);
        entry.label.addEventListener('pointerdown', e => edgePointer(e, edge));
        entry.label.addEventListener('dblclick', e => { e.stopPropagation(); editEdgeLabel(edge); });
      }
      entry.label.textContent = edge.label; entry.label.style.left = geo.mid[0] + 'px'; entry.label.style.top = geo.mid[1] + 'px';
      entry.label.classList.toggle('selected', selected.has(edge.id));
    } else if (entry.label) { entry.label.remove(); entry.label = null; }
    entry.geo = geo;
  }
  function removeEdgeElement(edge) { const entry = edgeElements.get(edge); if (!entry) return; entry.g.remove(); entry.label?.remove(); edgeElements.delete(edge); }
  function drawEdges(filter = null) {
    for (const edge of doc.edges) {
      if (!edgeValid(edge)) { removeEdgeElement(edge); continue; }
      if (!filter || filter.has(edge.fromNode) || filter.has(edge.toNode)) drawEdge(edge);
    }
    for (const edge of [...edgeElements.keys()]) if (!doc.edges.includes(edge)) removeEdgeElement(edge);
  }

  // ---------------------------------------------------------------- selection
  const selectionNodes = () => nodes.filter(n => selected.has(n.id));
  const selectionEdges = () => doc.edges.filter(e => e && selected.has(e.id));
  function choose(ids, additive = false) {
    const before = new Set(selected);
    if (!additive) selected = new Set(ids); else for (const id of ids) { if (selected.has(id)) selected.delete(id); else selected.add(id); }
    for (const id of new Set([...before, ...selected])) {
      if (byId.has(id)) paintNode(byId.get(id));
      else { const edge = doc.edges.find(e => e?.id === id); if (edge && edgeValid(edge)) drawEdge(edge); }
    }
    viewport.classList.toggle('single-selection', selected.size === 1 && selectionNodes().length === 1);
    state.selection = [...selected]; placeToolbar();
  }
  function placeToolbar() {
    const list = selectionNodes(), edges = selectionEdges();
    if (editing || drag?.moved || (!list.length && !edges.length)) { toolbar.hidden = true; return; }
    buildToolbar(list, edges);
    let x, y;
    if (list.length) { const b = bounds(list); x = (b.x + b.w / 2) * camera.zoom + camera.x; y = b.y * camera.zoom + camera.y - (list.some(n => n.type === 'group' || n.type === 'file') ? 34 : 8); }
    else { const geo = edgeElements.get(edges[0])?.geo; if (!geo) { toolbar.hidden = true; return; } x = geo.mid[0] * camera.zoom + camera.x; y = geo.mid[1] * camera.zoom + camera.y - 14; }
    toolbar.hidden = false;
    const w = toolbar.offsetWidth, h = toolbar.offsetHeight;
    toolbar.style.left = Math.max(8, Math.min(x - w / 2, viewport.clientWidth - w - 8)) + 'px';
    toolbar.style.top = Math.max(8, Math.min(y - h - 6, viewport.clientHeight - h - 60)) + 'px';
  }
  let toolbarKey = '';
  function buildToolbar(list, edges) {
    const key = [...selected].join(',') + '|' + list.map(n => n.color).join() + edges.map(e => e.color + e.toEnd + e.fromEnd).join();
    if (key === toolbarKey && toolbar.childNodes.length) return; toolbarKey = key;
    toolbar.replaceChildren();
    const add = (glyph, label, action) => { const b = iconButton(glyph, label, action); b.onpointerdown = e => e.stopPropagation(); toolbar.append(b); return b; };
    add('trash', 'Remove', () => removeSelection());
    add('palette', 'Set color', e => colorMenu(e.currentTarget));
    if (list.length) add('target', 'Zoom to selection', () => zoomToSelection());
    if (list.length === 1 && !edges.length) {
      const node = list[0];
      if (node.type === 'text') add('edit', 'Edit', () => startEditing(node));
      if (node.type === 'group') add('edit', 'Edit label', () => editGroupLabel(node));
      if (node.type === 'file') add('arrow', 'Open file', () => ctx.open(node.file + (node.subpath ?? '')));
      if (node.type === 'link') add('globe', 'Open link', () => ctx.open(node.url));
    }
    if (list.length > 1 || list.length === 1 && list[0].type !== 'group') add('group', 'Create group', () => groupSelection());
    if (edges.length === 1 && !list.length) {
      const edge = edges[0];
      add('arrowRight', 'Line direction', e => directionMenu(edge, e.currentTarget));
      add('edit', 'Edit label', () => editEdgeLabel(edge));
    }
  }
  function colorMenu(anchorNode) {
    const items = [...selectionNodes(), ...selectionEdges()];
    const current = items.length === 1 ? items[0].color : null;
    const set = value => { for (const item of items) { if (value) item.color = value; else delete item.color; } refreshItems(items); commit(); };
    popover(anchorNode, 'Color', (form, close) => {
      const row = el('div', null, 'color-row');
      const swatch = (value, label, css) => { const b = button(null, () => { set(value); close(); }, 'color-swatch' + (String(current ?? '') === String(value ?? '') ? ' active' : '')); b.style.background = css; b.title = label; b.setAttribute('aria-label', label); row.append(b); };
      swatch(null, 'Default', 'var(--card-border)');
      for (const [key, value] of Object.entries(presetColors)) swatch(key, presetNames[key], value);
      const custom = input(current && current.startsWith?.('#') ? current : '#888888', 'color'); custom.title = 'Custom color'; custom.className = 'color-custom';
      custom.onchange = () => { set(custom.value); close(); }; row.append(custom);
      form.append(row);
    });
  }
  function directionMenu(edge, anchorNode) {
    const now = (edge.fromEnd ?? 'none') + '>' + (edge.toEnd ?? 'arrow');
    const set = (fromEnd, toEnd) => { if (fromEnd === 'none') delete edge.fromEnd; else edge.fromEnd = fromEnd; if (toEnd === 'arrow') delete edge.toEnd; else edge.toEnd = toEnd; drawEdge(edge); toolbarKey = ''; placeToolbar(); commit(); };
    menu(anchorNode, [
      {label:'No arrows', checked:now === 'none>none', action:() => set('none', 'none')},
      {label:'One-way', checked:now === 'none>arrow', action:() => set('none', 'arrow')},
      {label:'Bidirectional', checked:now === 'arrow>arrow', action:() => set('arrow', 'arrow')},
      {label:'Reverse', action:() => { [edge.fromNode, edge.toNode] = [edge.toNode, edge.fromNode]; [edge.fromSide, edge.toSide] = [edge.toSide, edge.fromSide]; if (edge.fromSide == null) delete edge.fromSide; if (edge.toSide == null) delete edge.toSide; drawEdge(edge); commit(); }}]);
  }
  function refreshItems(items) { for (const item of items) { if (byId.has(item.id)) paintNode(item); else drawEdge(item); } toolbarKey = ''; placeToolbar(); }

  // ---------------------------------------------------------------- editing
  function startEditing(node, caretAtEnd = true) {
    if (node.type === 'group') { editGroupLabel(node); return; }
    if (node.type === 'file') { ctx.open(node.file + (node.subpath ?? '')); return; }
    if (node.type === 'link') { askLink(node); return; }
    if (node.type !== 'text') return;
    finishEditing();
    const element = elements.get(node.id), body = element.querySelector('.cnode-body'), before = beforeEdit();
    choose([node.id]);
    const area = el('textarea', null, 'cnode-editor'); area.value = node.text ?? ''; area.spellcheck = false; area.setAttribute('aria-label', 'Card text');
    body.replaceChildren(area); body.className = 'cnode-body editing'; element.classList.add('editing');
    editing = {id:node.id, before, area}; toolbar.hidden = true;
    const suggest = wikiSuggest(area);
    area.oninput = () => {
      node.text = area.value; ctx.change(serializeCanvas(doc), {render:false, history:false});
      // Cards grow while typing, like Obsidian.
      if (area.scrollHeight > area.clientHeight + 2) { node.height = Math.ceil((node.height + area.scrollHeight - area.clientHeight) / GRID) * GRID; paintNode(node); drawEdges(new Set([node.id])); }
      suggest.update();
    };
    area.onkeydown = e => {
      if (suggest.key(e)) return;
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finishEditing(); viewport.focus({preventScroll:true}); }
    };
    area.onblur = () => setTimeout(() => { if (editing?.area === area && document.activeElement !== area) finishEditing(); }, 0);
    area.onpointerdown = e => e.stopPropagation();
    area.focus({preventScroll:true}); if (caretAtEnd) area.setSelectionRange(area.value.length, area.value.length);
  }
  function finishEditing() {
    if (!editing) return;
    const {id, before} = editing, node = byId.get(id); editing = null;
    elements.get(id)?.classList.remove('editing');
    closeSuggest();
    if (node) { ctx.record(before, ctx.data.source); fill(node); }
    placeToolbar();
  }
  let suggestBox = null;
  function closeSuggest() { suggestBox?.remove(); suggestBox = null; }
  // [[ autocomplete from the vault's files.
  function wikiSuggest(area) {
    let options = [], active = 0;
    const query = () => { const before = area.value.slice(0, area.selectionStart), m = /\[\[([^\]\n|#]*)$/.exec(before); return m ? m[1] : null; };
    const update = () => {
      const q = query(); if (q == null) { closeSuggest(); return; }
      const files = ctx.files(); if (!files.length) ctx.requestFiles();
      const term = q.toLowerCase();
      options = files.filter(f => f.path.toLowerCase().includes(term)).sort((a, b) => (a.path.split('/').pop().toLowerCase().startsWith(term) ? 0 : 1) - (b.path.split('/').pop().toLowerCase().startsWith(term) ? 0 : 1) || a.path.length - b.path.length).slice(0, 8);
      active = 0; draw();
    };
    const draw = () => {
      closeSuggest(); if (!options.length) return;
      suggestBox = el('div', null, 'menu suggest');
      options.forEach((f, i) => {
        const name = f.path.split('/').pop().replace(/\.md$/i, ''), row = button(null, () => pick(i), 'menu-item' + (i === active ? ' active' : ''));
        row.onpointerdown = e => e.preventDefault(); row.append(el('span', name, 'menu-label'), el('span', f.path, 'menu-hint')); suggestBox.append(row);
      });
      document.body.append(suggestBox);
      const r = area.getBoundingClientRect(); suggestBox.style.left = r.left + 'px'; suggestBox.style.top = Math.min(r.bottom + 4, innerHeight - suggestBox.offsetHeight - 6) + 'px';
    };
    const pick = i => {
      const f = options[i]; if (!f) return;
      const name = f.path.replace(/\.md$/i, ''), q = query(), start = area.selectionStart - q.length;
      const after = area.value.slice(area.selectionStart).startsWith(']]') ? '' : ']]';
      area.setRangeText(name + after, start, area.selectionStart, 'end'); if (!after) area.selectionStart = area.selectionEnd = area.selectionEnd + 2;
      closeSuggest(); area.dispatchEvent(new Event('input'));
    };
    return {update, key:e => {
      if (!suggestBox) return false;
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); active = (active + (e.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length; draw(); return true; }
      if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); pick(active); return true; }
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeSuggest(); return true; }
      return false;
    }};
  }
  function inlineInput(worldX, worldY, width, value, placeholder, onDone, cls) {
    const box = el('input', null, 'canvas-inline-input ' + (cls ?? '')); box.value = value ?? ''; box.placeholder = placeholder;
    box.style.left = worldX + 'px'; box.style.top = worldY + 'px'; box.style.width = Math.max(120, width) + 'px';
    labelLayer.append(box); box.focus(); box.select();
    let done = false;
    const finish = save => { if (done) return; done = true; box.remove(); if (save) onDone(box.value); viewport.focus({preventScroll:true}); };
    box.onkeydown = e => { e.stopPropagation(); if (e.key === 'Enter' && !e.isComposing) { e.preventDefault(); finish(true); } if (e.key === 'Escape') finish(false); };
    box.onblur = () => finish(true); box.onpointerdown = e => e.stopPropagation();
  }
  function editGroupLabel(node) {
    inlineInput(node.x, node.y - 30, Math.min(node.width, 360), node.label, 'Group name', value => {
      if ((node.label ?? '') === value) return; if (value) node.label = value; else delete node.label;
      const label = elements.get(node.id)?.querySelector('.cnode-label'); if (label) { label.textContent = value; label.classList.toggle('empty', !value); }
      commit();
    }, 'group-label-input');
  }
  function editEdgeLabel(edge) {
    const geo = edgeElements.get(edge)?.geo ?? edgeGeometry(edge);
    inlineInput(geo.mid[0] - 80, geo.mid[1] - 14, 160, edge.label, 'Label', value => {
      if ((edge.label ?? '') === value) return; if (value) edge.label = value; else delete edge.label; drawEdge(edge); commit();
    }, 'edge-label-input');
  }

  // ---------------------------------------------------------------- creation
  function freeSpot(width, height, at) {
    let x = at?.x ?? (viewport.clientWidth / 2 - camera.x) / camera.zoom - width / 2, y = at?.y ?? (viewport.clientHeight / 2 - camera.y) / camera.zoom - height / 2;
    if (state.snapGrid) { x = Math.round(x / GRID) * GRID; y = Math.round(y / GRID) * GRID; }
    // Offset from existing cards at the same spot.
    for (let i = 0; i < 20 && nodes.some(n => n.type !== 'group' && Math.abs(n.x - x) < 10 && Math.abs(n.y - y) < 10); i++) { x += GRID; y += GRID; }
    return {x, y};
  }
  function addNode(type, extra = {}, at = null, edit = false, size = null) {
    const defaults = {text:[260, 60], file:[400, 400], link:[400, 300], group:[400, 400]}[type] ?? [260, 60];
    const [width, height] = size ?? defaults, spot = freeSpot(width, height, at);
    const node = {id:uid(), type, x:Math.round(spot.x), y:Math.round(spot.y), width, height, ...extra};
    if (type === 'group') doc.nodes.unshift(node); else doc.nodes.push(node);
    nodes.push(node); byId.set(node.id, node); build(node); fill(node);
    doc.nodes.forEach((n, i) => { const e = elements.get(n?.id); if (e) e.style.zIndex = String(i + 1); });
    viewport.querySelector('.canvas-empty')?.remove();
    choose([node.id]); commit();
    if (edit && type === 'text') startEditing(node);
    if (edit && type === 'group') editGroupLabel(node);
    return node;
  }
  function pickFile(kind) {
    ctx.requestFiles();
    const matches = f => kind === 'media' ? imageExt.test(f.path) || audioExt.test(f.path) || videoExt.test(f.path) || /\.pdf$/i.test(f.path) : !/\.(canvas)$/i.test(f.path) || true;
    dialog(kind === 'media' ? 'Add media from vault' : 'Add note from vault', (form, close) => {
      const search = input('', 'search'); search.placeholder = 'Search files…';
      const list = el('div', null, 'file-picker');
      let active = 0, shown = [];
      const draw = () => {
        const term = search.value.trim().toLowerCase(), files = ctx.files().filter(matches);
        shown = files.filter(f => !term || f.path.toLowerCase().includes(term)).sort((a, b) => (kind === 'note' ? (/\.md$/i.test(b.path) - /\.md$/i.test(a.path)) : 0) || a.path.localeCompare(b.path)).slice(0, 60);
        active = Math.min(active, Math.max(0, shown.length - 1));
        list.replaceChildren(...shown.map((f, i) => {
          const row = button(null, () => choosePath(f.path), 'file-option' + (i === active ? ' active' : ''));
          row.append(icon(fileIcon(f.path)), el('span', f.path.split('/').pop(), 'file-option-name'), el('span', f.path.includes('/') ? f.path.slice(0, f.path.lastIndexOf('/')) : '', 'file-option-folder'));
          return row;
        }));
        if (!files.length) list.append(el('div', 'Loading files…', 'muted'));
        else if (!shown.length) list.append(el('div', 'No matching files', 'muted'));
      };
      const choosePath = file => {
        close();
        const at = null, image = imageExt.test(file);
        addNode('file', {file}, at, false, image ? [400, 300] : /\.md$/i.test(file) ? [400, 400] : [400, 400]);
      };
      search.oninput = () => { active = 0; draw(); };
      search.onkeydown = e => {
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); active = Math.max(0, Math.min(shown.length - 1, active + (e.key === 'ArrowDown' ? 1 : -1))); draw(); list.children[active]?.scrollIntoView({block:'nearest'}); }
        if (e.key === 'Enter') { e.preventDefault(); if (shown[active]) choosePath(shown[active].path); }
      };
      form.append(search, list); draw();
      filesListeners.add(draw); form.closest('dialog').addEventListener('close', () => filesListeners.delete(draw));
      requestAnimationFrame(() => search.focus());
    }).classList.add('wide');
  }
  const filesListeners = new Set();
  function askLink(node = null) {
    dialog(node ? 'Edit web page' : 'Add web page', (form, close) => {
      const url = input(node?.url ?? ''); url.placeholder = 'https://';
      form.append(field('URL', url));
      actions(form, close, () => {
        let value = url.value.trim(); if (!value) throw Error('Enter a URL.');
        if (!/^[a-z][a-z0-9+.-]*:/i.test(value)) value = 'https://' + value;
        if (node) { node.url = value; rebuildNode(node); commit(); } else addNode('link', {url:value});
      }, node ? 'Save' : 'Add');
      requestAnimationFrame(() => url.focus());
    });
  }
  function groupSelection() {
    const list = selectionNodes(); if (!list.length) return;
    const b = bounds(list), pad = 20;
    const group = {id:uid(), type:'group', x:b.x - pad, y:b.y - pad, width:b.w + pad * 2, height:b.h + pad * 2};
    const first = Math.min(...list.map(n => doc.nodes.indexOf(n)));
    doc.nodes.splice(Math.max(0, first), 0, group); nodes.push(group); byId.set(group.id, group); build(group); fill(group);
    doc.nodes.forEach((n, i) => { const e = elements.get(n?.id); if (e) e.style.zIndex = String(i + 1); });
    choose([group.id]); commit(); editGroupLabel(group);
  }
  function removeSelection() {
    const ids = new Set(selected); if (!ids.size) return;
    finishEditing();
    doc.nodes = doc.nodes.filter(n => !ids.has(n?.id));
    doc.edges = doc.edges.filter(e => !ids.has(e?.id) && !ids.has(e?.fromNode) && !ids.has(e?.toNode));
    for (const id of ids) { elements.get(id)?.remove(); elements.delete(id); byId.delete(id); }
    nodes = nodes.filter(n => !ids.has(n.id));
    selected = new Set(); drawEdges(); choose([]); commit();
  }
  function reorder(front) {
    const list = selectionNodes(); if (!list.length) return;
    doc.nodes = front ? [...doc.nodes.filter(n => !list.includes(n)), ...list] : [...list, ...doc.nodes.filter(n => !list.includes(n))];
    doc.nodes.forEach((n, i) => { const e = elements.get(n?.id); if (e) e.style.zIndex = String(i + 1); }); commit();
  }

  // ---------------------------------------------------------------- clipboard
  function copySelection() {
    const list = selectionNodes(); if (!list.length) return null;
    const ids = new Set(list.map(n => n.id));
    return JSON.stringify({nodes:list, edges:doc.edges.filter(e => e && ids.has(e.fromNode) && ids.has(e.toNode))}, null, '\t');
  }
  function pasteData(textValue, at = null) {
    let data = null;
    try { data = JSON.parse(textValue); } catch {}
    const target = at ?? (pointerInside ? toWorld(pointer.x, pointer.y) : null);
    if (data && Array.isArray(data.nodes) && data.nodes.length) {
      const incoming = data.nodes.filter(n => n && Number.isFinite(n.x) && Number.isFinite(n.y) && Number.isFinite(n.width) && Number.isFinite(n.height));
      if (!incoming.length) return;
      const b = bounds(incoming), origin = target ? {x:target.x - b.w / 2, y:target.y - b.h / 2} : {x:b.x + 40, y:b.y + 40};
      let dx = origin.x - b.x, dy = origin.y - b.y; if (state.snapGrid) { dx = Math.round(dx / GRID) * GRID; dy = Math.round(dy / GRID) * GRID; }
      const map = new Map(), added = [];
      for (const n of incoming) { const copy = {...structuredClone(n), id:uid(), x:Math.round(n.x + dx), y:Math.round(n.y + dy)}; map.set(n.id, copy.id); added.push(copy); }
      for (const n of added) { if (n.type === 'group') doc.nodes.unshift(n); else doc.nodes.push(n); nodes.push(n); byId.set(n.id, n); build(n); fill(n); }
      for (const e of data.edges ?? []) if (e && map.has(e.fromNode) && map.has(e.toNode)) doc.edges.push({...structuredClone(e), id:uid(), fromNode:map.get(e.fromNode), toNode:map.get(e.toNode)});
      doc.nodes.forEach((n, i) => { const e = elements.get(n?.id); if (e) e.style.zIndex = String(i + 1); });
      drawEdges(); choose(added.map(n => n.id)); commit(); return;
    }
    const value = textValue.trim(); if (!value) return;
    const spot = target ? {x:target.x - 130, y:target.y - 30} : null;
    if (/^https?:\/\/\S+$/i.test(value)) addNode('link', {url:value}, spot);
    else if (/^!?\[\[[^\]]+\]\]$/.test(value)) addNode('file', {file:resolveFile(value.replace(/^!?\[\[|\]\]$/g, '').split('|')[0])}, spot);
    else {
      const lines = value.split('\n').length, width = Math.min(600, Math.max(260, Math.min(80, Math.max(...value.split('\n').map(l => l.length))) * 8));
      addNode('text', {text:value}, spot, false, [Math.round(width / GRID) * GRID, Math.min(600, Math.ceil((lines * 24 + 30) / GRID) * GRID)]);
    }
  }
  function resolveFile(target) {
    const files = ctx.files(), clean = target.split('#')[0];
    return files.find(f => f.path === clean || f.path === clean + '.md')?.path ?? files.find(f => f.path.split('/').pop().replace(/\.md$/i, '') === clean)?.path ?? (/\.\w+$/.test(clean) ? clean : clean + '.md');
  }
  const onCopy = e => {
    if (editing || e.target.closest?.('input,textarea,dialog')) return;
    const data = copySelection(); if (!data) return;
    e.clipboardData.setData('text/plain', data); e.preventDefault();
    if (cutting) { cutting = false; removeSelection(); }
  };
  let cutting = false;
  const onCut = e => { cutting = true; onCopy(e); cutting = false; };
  const onPaste = e => {
    if (editing || e.target.closest?.('input,textarea,dialog')) return;
    const text = e.clipboardData.getData('text/plain'); if (!text) return;
    e.preventDefault(); pasteData(text);
  };
  document.addEventListener('copy', onCopy); document.addEventListener('cut', onCut); document.addEventListener('paste', onPaste);

  // ---------------------------------------------------------------- menus
  function canvasMenu(at, worldPoint) {
    menu(at, [
      {label:'Add card', icon:'note', action:() => addNode('text', {text:''}, {x:worldPoint.x, y:worldPoint.y}, true)},
      {label:'Add note from vault', icon:'file', action:() => pickFile('note')},
      {label:'Add media from vault', icon:'image', action:() => pickFile('media')},
      {label:'Add web page', icon:'globe', action:() => askLink()},
      {label:'Add group', icon:'group', action:() => addNode('group', {}, {x:worldPoint.x, y:worldPoint.y}, true)},
      'separator',
      {label:'Paste', icon:'copy', hint:'⌘V', action:() => { const at = worldPoint; (navigator.clipboard?.readText?.() ?? Promise.reject()).then(text => pasteData(text, at)).catch(() => ctx.notice('Press ⌘V to paste here.')); }},
      {label:'Select all', hint:'⌘A', action:() => choose([...nodes.map(n => n.id), ...doc.edges.filter(edgeValid).map(e => e.id)])},
      {label:'Zoom to fit', icon:'fit', hint:'⇧1', action:() => fit()}]);
  }
  function nodeMenu(node, at) {
    const multi = selectionNodes().length > 1;
    menu(at, [
      !multi && node.type === 'text' ? {label:'Edit', icon:'edit', action:() => startEditing(node)} : null,
      !multi && node.type === 'file' ? {label:'Open file', icon:'arrow', action:() => ctx.open(node.file + (node.subpath ?? ''))} : null,
      !multi && node.type === 'link' ? {label:'Open link', icon:'globe', action:() => ctx.open(node.url)} : null,
      !multi && node.type === 'link' ? {label:'Edit URL', icon:'edit', action:() => askLink(node)} : null,
      !multi && node.type === 'group' ? {label:'Edit label', icon:'edit', action:() => editGroupLabel(node)} : null,
      !multi && node.type === 'group' ? {label:'Remove background', disabled:!node.background, action:() => { delete node.background; delete node.backgroundStyle; rebuildNode(node); commit(); }} : null,
      {label:'Color', icon:'palette', submenu:[{label:'Default', checked:!node.color, action:() => setColor(null)},
        ...Object.entries(presetColors).map(([k, v]) => ({label:presetNames[k], swatch:v, checked:String(node.color) === k, action:() => setColor(k)}))]},
      {label:multi ? 'Create group from selection' : 'Create group', icon:'group', disabled:!multi && node.type === 'group', action:() => groupSelection()},
      'separator',
      {label:'Bring to front', icon:'arrowUp', action:() => reorder(true)},
      {label:'Send to back', icon:'arrowDown', action:() => reorder(false)},
      {label:'Duplicate', icon:'duplicate', hint:'⌘D', action:() => duplicate()},
      {label:'Zoom to selection', icon:'target', hint:'⇧2', action:() => zoomToSelection()},
      'separator',
      {label:'Remove', icon:'trash', danger:true, hint:'⌫', action:() => removeSelection()}]);
    function setColor(value) { const list = selectionNodes(); for (const n of list) { if (value) n.color = value; else delete n.color; } refreshItems(list); commit(); }
  }
  function edgeMenu(edge, at) {
    menu(at, [
      {label:'Edit label', icon:'edit', action:() => editEdgeLabel(edge)},
      {label:'Direction', icon:'arrowRight', submenu:[
        {label:'No arrows', action:() => { edge.fromEnd = 'none'; edge.toEnd = 'none'; drawEdge(edge); commit(); }},
        {label:'One-way', action:() => { delete edge.fromEnd; delete edge.toEnd; drawEdge(edge); commit(); }},
        {label:'Bidirectional', action:() => { edge.fromEnd = 'arrow'; edge.toEnd = 'arrow'; drawEdge(edge); commit(); }}]},
      {label:'Color', icon:'palette', submenu:[{label:'Default', checked:!edge.color, action:() => { delete edge.color; drawEdge(edge); commit(); }},
        ...Object.entries(presetColors).map(([k, v]) => ({label:presetNames[k], swatch:v, checked:String(edge.color) === k, action:() => { edge.color = k; drawEdge(edge); commit(); }}))]},
      {label:'Go to source', action:() => { choose([edge.fromNode]); zoomToSelection(); }},
      {label:'Go to target', action:() => { choose([edge.toNode]); zoomToSelection(); }},
      'separator', {label:'Remove', icon:'trash', danger:true, action:() => { choose([edge.id]); removeSelection(); }}]);
  }
  function duplicate() { const data = copySelection(); if (!data) return; const b = bounds(selectionNodes()); pasteData(data, {x:b.x + b.w / 2 + 40, y:b.y + b.h / 2 + 40}); }

  // ---------------------------------------------------------------- snapping
  function snapMove(moving, dx, dy) {
    const b0 = drag.bounds, others = drag.others;
    let x = b0.x + dx, y = b0.y + dy, guideX = null, guideY = null;
    if (state.snapObjects && !drag.noSnap) {
      const threshold = 8 / camera.zoom;
      const xs = [x, x + b0.w / 2, x + b0.w], ys = [y, y + b0.h / 2, y + b0.h];
      let best = threshold, bestY = threshold;
      for (const n of others) {
        for (const line of [n.x, n.x + n.width / 2, n.x + n.width]) xs.forEach((v, i) => { const d = Math.abs(line - v); if (d < best) { best = d; guideX = line; x = line - [0, b0.w / 2, b0.w][i]; } });
        for (const line of [n.y, n.y + n.height / 2, n.y + n.height]) ys.forEach((v, i) => { const d = Math.abs(line - v); if (d < bestY) { bestY = d; guideY = line; y = line - [0, b0.h / 2, b0.h][i]; } });
      }
    }
    if (state.snapGrid && !drag.noSnap) { if (guideX == null) x = Math.round(x / GRID) * GRID; if (guideY == null) y = Math.round(y / GRID) * GRID; }
    showGuides(guideX, guideY);
    return {dx:x - b0.x, dy:y - b0.y};
  }
  function showGuides(gx, gy) {
    guides.replaceChildren();
    const line = (x1, y1, x2, y2) => { const l = document.createElementNS(guides.namespaceURI, 'line'); Object.entries({x1, y1, x2, y2}).forEach(([k, v]) => l.setAttribute(k, v)); guides.append(l); };
    if (gx != null) { const sx = gx * camera.zoom + camera.x; line(sx, 0, sx, viewport.clientHeight); }
    if (gy != null) { const sy = gy * camera.zoom + camera.y; line(0, sy, viewport.clientWidth, sy); }
  }

  // ---------------------------------------------------------------- pointer input
  const touches = new Map();
  let pointerInside = false, longPress = null;
  viewport.addEventListener('pointerenter', () => { pointerInside = true; });
  viewport.addEventListener('pointerleave', () => { pointerInside = false; });
  viewport.addEventListener('pointerdown', e => {
    if (e.target.closest('.canvas-create,.canvas-controls,.canvas-selection-menu,.canvas-inline-input,.cnode-editor,.canvas-issues')) return;
    closeMenus(); closePopover();
    pointer = {x:e.clientX, y:e.clientY};
    if (e.pointerType === 'touch') {
      touches.set(e.pointerId, {x:e.clientX, y:e.clientY});
      if (touches.size === 2) { const [a, b] = [...touches.values()]; drag = {type:'pinch', distance:Math.hypot(a.x - b.x, a.y - b.y), zoom:camera.zoom, cx:(a.x + b.x) / 2, cy:(a.y + b.y) / 2, camera:{...camera}}; clearTimeout(longPress); return; }
    }
    if (e.button === 1 || e.button === 0 && spaceDown) { startPan(e); return; }
    if (e.button !== 0) return;
    const nodeElement = e.target.closest('.cnode'), node = nodeElement ? byId.get(nodeElement.dataset.nodeId) : null;
    if (editing && (!node || node.id !== editing.id)) finishEditing();
    if (node) {
      if (e.target.closest('a,input,.link-preview button')) return;
      // A selected Base card is interactive; unselected ones still drag.
      if (selected.has(node.id) && e.target.closest('.cnode-embed .embed-main')) return;
      const handle = e.target.closest('.cnode-resize'), port = e.target.closest('.cnode-port');
      if (port) { startConnect(e, node, port.dataset.side); return; }
      if (handle && selected.has(node.id)) { startResize(e, node, handle.dataset.handle); return; }
      if (editing?.id === node.id) return;
      if (e.shiftKey || e.metaKey) choose([node.id], true); else if (!selected.has(node.id)) choose([node.id]);
      startMove(e, e.altKey);
      if (e.pointerType === 'touch') longPress = setTimeout(() => { if (drag && !drag.moved) { drag = null; nodeMenu(node, {x:e.clientX, y:e.clientY}); } }, 550);
      return;
    }
    // Empty space: pan with touch, marquee selection with a mouse or pen.
    if (e.pointerType === 'touch') {
      startPan(e);
      const at = toWorld(e.clientX, e.clientY);
      longPress = setTimeout(() => { if (drag?.type === 'pan' && !drag.moved) { drag = null; canvasMenu({x:e.clientX, y:e.clientY}, at); } }, 550);
      return;
    }
    const start = toWorld(e.clientX, e.clientY);
    drag = {type:'marquee', start, additive:e.shiftKey || e.metaKey, base:new Set(e.shiftKey || e.metaKey ? selected : []), x:e.clientX, y:e.clientY, moved:false};
    viewport.setPointerCapture?.(e.pointerId);
    viewport.focus({preventScroll:true});
  });
  function startPan(e) { drag = {type:'pan', x:e.clientX, y:e.clientY, camera:{...camera}, moved:false}; viewport.classList.add('panning'); viewport.setPointerCapture?.(e.pointerId); }
  function movingSet(list) {
    const moving = new Set(list);
    for (const n of list) if (n.type === 'group') for (const m of nodes) if (m !== n && m.x >= n.x && m.y >= n.y && m.x + m.width <= n.x + n.width && m.y + m.height <= n.y + n.height) moving.add(m);
    return [...moving];
  }
  function startMove(e, duplicateFirst) {
    let list = selectionNodes();
    drag = {type:'move', x:e.clientX, y:e.clientY, moved:false, duplicateFirst, noSnap:false};
    drag.prepare = () => {
      // Alt-drag moves a copy and leaves the originals in place.
      if (drag.duplicateFirst) { const b = bounds(list); pasteData(copySelection(), {x:b.x + b.w / 2, y:b.y + b.h / 2}); list = selectionNodes(); }
      const moving = movingSet(list);
      drag.items = moving.map(n => [n, n.x, n.y]); drag.bounds = bounds(list);
      const ids = new Set(moving.map(n => n.id)); drag.ids = ids;
      const cx = drag.bounds.x + drag.bounds.w / 2, cy = drag.bounds.y + drag.bounds.h / 2, reach = 1500;
      drag.others = nodes.filter(n => !ids.has(n.id) && Math.abs(n.x + n.width / 2 - cx) < reach && Math.abs(n.y + n.height / 2 - cy) < reach).slice(0, 400);
    };
    viewport.setPointerCapture?.(e.pointerId);
  }
  function startResize(e, node, handle) {
    e.stopPropagation();
    drag = {type:'resize', node, handle, x:e.clientX, y:e.clientY, start:{x:node.x, y:node.y, w:node.width, h:node.height}, moved:false,
      others:nodes.filter(n => n !== node).slice(0, 400)};
    viewport.setPointerCapture?.(e.pointerId);
  }
  function startConnect(e, node, side) {
    e.stopPropagation();
    drag = {type:'connect', node, side, moved:false, x:e.clientX, y:e.clientY};
    const pending = svgEl('path', {class:'cedge-pending', fill:'none'}); svg.append(pending); drag.pending = pending;
    viewport.classList.add('connecting'); viewport.setPointerCapture?.(e.pointerId);
  }
  function edgePointer(e, edge) {
    if (e.button !== 0) return;
    e.stopPropagation(); closeMenus();
    if (e.shiftKey || e.metaKey) { choose([edge.id], true); return; }
    choose([edge.id]);
    // Dragging near an end reconnects that end.
    const at = toWorld(e.clientX, e.clientY), geo = edgeElements.get(edge)?.geo; if (!geo) return;
    const dFrom = Math.hypot(at.x - geo.p[0], at.y - geo.p[1]), dTo = Math.hypot(at.x - geo.q[0], at.y - geo.q[1]), near = 30 / camera.zoom;
    if (Math.min(dFrom, dTo) > near) return;
    const end = dFrom < dTo ? 'from' : 'to', fixed = end === 'from' ? byId.get(edge.toNode) : byId.get(edge.fromNode);
    drag = {type:'reconnect', edge, end, fixed, fixedSide:end === 'from' ? geo.toSide : geo.fromSide, x:e.clientX, y:e.clientY, moved:false};
    const pending = svgEl('path', {class:'cedge-pending', fill:'none'}); svg.append(pending); drag.pending = pending;
    edgeElements.get(edge)?.g.classList.add('reconnecting'); viewport.classList.add('connecting'); viewport.setPointerCapture?.(e.pointerId);
  }
  function targetAt(clientX, clientY, exclude) {
    const hit = document.elementsFromPoint(clientX, clientY).find(n => n.closest?.('.cnode') && n.closest('.cnode').dataset.nodeId !== exclude?.id)?.closest('.cnode');
    const node = hit ? byId.get(hit.dataset.nodeId) : null; if (!node) return null;
    const portSide = document.elementsFromPoint(clientX, clientY).find(n => n.classList?.contains('cnode-port'))?.dataset.side;
    if (portSide) return {node, side:portSide};
    const p = toWorld(clientX, clientY);
    return {node, side:sides.map(s => [s, Math.hypot(anchor(node, s)[0] - p.x, anchor(node, s)[1] - p.y)]).sort((a, b) => a[1] - b[1])[0][0]};
  }
  function markTarget(target) {
    viewport.querySelectorAll('.connection-target').forEach(n => n.classList.remove('connection-target'));
    viewport.querySelectorAll('.cnode-port.active').forEach(n => n.classList.remove('active'));
    if (!target) return;
    const element = elements.get(target.node.id); element?.classList.add('connection-target'); element?.querySelector('.cnode-port.' + target.side)?.classList.add('active');
  }
  viewport.addEventListener('pointermove', e => {
    pointer = {x:e.clientX, y:e.clientY};
    if (e.pointerType === 'touch' && touches.has(e.pointerId)) touches.set(e.pointerId, {x:e.clientX, y:e.clientY});
    if (!drag) return;
    if (drag.type === 'pinch') {
      const [a, b] = [...touches.values()]; if (!a || !b) return;
      const distance = Math.hypot(a.x - b.x, a.y - b.y), cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2, r = viewport.getBoundingClientRect();
      const zoom = Math.min(4, Math.max(0.05, drag.zoom * distance / drag.distance)), px = drag.cx - r.left, py = drag.cy - r.top;
      camera = {zoom, x:px - (px - drag.camera.x) * zoom / drag.camera.zoom + (cx - drag.cx), y:py - (py - drag.camera.y) * zoom / drag.camera.zoom + (cy - drag.cy)}; applyCamera(); return;
    }
    const dxs = e.clientX - drag.x, dys = e.clientY - drag.y;
    if (!drag.moved && Math.hypot(dxs, dys) < 4) return;
    if (!drag.moved) { drag.moved = true; clearTimeout(longPress); toolbar.hidden = true; drag.prepare?.(); }
    const dx = dxs / camera.zoom, dy = dys / camera.zoom;
    if (drag.type === 'pan') { camera = {...camera, x:drag.camera.x + dxs, y:drag.camera.y + dys}; applyCamera(); }
    else if (drag.type === 'marquee') {
      const a = drag.start, b = toWorld(e.clientX, e.clientY), x = Math.min(a.x, b.x), y = Math.min(a.y, b.y), w = Math.abs(a.x - b.x), h = Math.abs(a.y - b.y);
      marquee.hidden = false; Object.assign(marquee.style, {left:x * camera.zoom + camera.x + 'px', top:y * camera.zoom + camera.y + 'px', width:w * camera.zoom + 'px', height:h * camera.zoom + 'px'});
      const inside = nodes.filter(n => n.x < x + w && n.x + n.width > x && n.y < y + h && n.y + n.height > y && !(n.type === 'group' && !(n.x >= x && n.y >= y && n.x + n.width <= x + w && n.y + n.height <= y + h)));
      const ids = new Set([...drag.base, ...inside.map(n => n.id)]);
      const before = selected; selected = ids; for (const id of new Set([...before, ...ids])) if (byId.has(id)) paintNode(byId.get(id));
    } else if (drag.type === 'move') {
      drag.noSnap = e.metaKey; const snapped = snapMove(null, dx, dy);
      for (const [n, x, y] of drag.items) { n.x = Math.round(x + snapped.dx); n.y = Math.round(y + snapped.dy); paintNode(n); }
      drawEdges(drag.ids);
    } else if (drag.type === 'resize') {
      const {node, handle, start} = drag; let {x, y, w, h} = start;
      if (handle.includes('e')) w = start.w + dx; if (handle.includes('s')) h = start.h + dy;
      if (handle.includes('w')) { w = start.w - dx; x = start.x + dx; } if (handle.includes('n')) { h = start.h - dy; y = start.y + dy; }
      if (e.shiftKey && start.w && start.h) { const ratio = start.w / start.h; if (Math.abs(w / h) > ratio) h = w / ratio; else w = h * ratio; }
      if (state.snapGrid && !e.metaKey) {
        if (handle.includes('e')) w = Math.round((x + w) / GRID) * GRID - x; if (handle.includes('s')) h = Math.round((y + h) / GRID) * GRID - y;
        if (handle.includes('w')) { const right = x + w; x = Math.round(x / GRID) * GRID; w = right - x; } if (handle.includes('n')) { const bottom = y + h; y = Math.round(y / GRID) * GRID; h = bottom - y; }
      }
      if (w < MIN_W) { if (handle.includes('w')) x -= MIN_W - w; w = MIN_W; } if (h < MIN_H) { if (handle.includes('n')) y -= MIN_H - h; h = MIN_H; }
      Object.assign(node, {x:Math.round(x), y:Math.round(y), width:Math.round(w), height:Math.round(h)}); paintNode(node); drawEdges(new Set([node.id])); placeToolbar();
    } else if (drag.type === 'connect' || drag.type === 'reconnect') {
      const source = drag.type === 'connect' ? drag.node : drag.fixed, side = drag.type === 'connect' ? drag.side : drag.fixedSide;
      const target = targetAt(e.clientX, e.clientY, source); markTarget(target); drag.target = target;
      const at = toWorld(e.clientX, e.clientY), q = target ? anchor(target.node, target.side) : [at.x, at.y];
      const geo = curve(anchor(source, side), side, q, target?.side ?? null);
      drag.pending.setAttribute('d', geo.d);
    }
  });
  function endPointer(e) {
    if (e.pointerType === 'touch') touches.delete(e.pointerId);
    clearTimeout(longPress);
    const current = drag; if (!current) return;
    if (current.type === 'pinch') { if (touches.size < 2) drag = null; return; }
    drag = null; viewport.classList.remove('panning', 'connecting'); showGuides(null, null); markTarget(null);
    if (viewport.hasPointerCapture?.(e.pointerId)) viewport.releasePointerCapture(e.pointerId);
    if (current.type === 'marquee') {
      marquee.hidden = true;
      if (!current.moved) choose(current.additive ? [...selected] : []);
      else choose([...selected]);
    } else if (current.type === 'move' || current.type === 'resize') { if (current.moved) commit(); placeToolbar(); }
    else if (current.type === 'connect') {
      current.pending.remove();
      if (!current.moved) return;
      const target = current.target;
      if (target) {
        const edge = {id:uid(), fromNode:current.node.id, fromSide:current.side, toNode:target.node.id, toSide:target.side};
        doc.edges.push(edge); drawEdge(edge); choose([edge.id]); commit();
      } else {
        // Dropping on empty space creates a connected card, as in Obsidian.
        const at = toWorld(e.clientX, e.clientY), opposite = {top:'bottom', bottom:'top', left:'right', right:'left'}[current.side];
        const [w, h] = [260, 60], spot = {x:at.x - (opposite === 'left' ? 0 : opposite === 'right' ? w : w / 2), y:at.y - (opposite === 'top' ? 0 : opposite === 'bottom' ? h : h / 2)};
        const node = addNode('text', {text:''}, spot, false);
        const edge = {id:uid(), fromNode:current.node.id, fromSide:current.side, toNode:node.id, toSide:opposite};
        doc.edges.push(edge); drawEdge(edge); commit(); startEditing(node);
      }
    } else if (current.type === 'reconnect') {
      current.pending.remove(); edgeElements.get(current.edge)?.g.classList.remove('reconnecting');
      if (current.moved && current.target) {
        if (current.end === 'from') { current.edge.fromNode = current.target.node.id; current.edge.fromSide = current.target.side; }
        else { current.edge.toNode = current.target.node.id; current.edge.toSide = current.target.side; }
        drawEdge(current.edge); commit();
      }
      placeToolbar();
    } else if (current.type === 'pan') placeToolbar();
  }
  viewport.addEventListener('pointerup', endPointer);
  viewport.addEventListener('pointercancel', e => { if (drag && drag.type !== 'pinch') { drag.pending?.remove(); marquee.hidden = true; } endPointer(e); });
  viewport.addEventListener('dblclick', e => {
    if (e.target.closest('.canvas-create,.canvas-controls,.canvas-selection-menu,.canvas-inline-input,.cnode-editor,a,input')) return;
    const nodeElement = e.target.closest('.cnode');
    if (nodeElement) {
      const node = byId.get(nodeElement.dataset.nodeId); if (!node) return;
      if (e.target.closest('.cnode-label') && node.type === 'group') { editGroupLabel(node); return; }
      if (node.type === 'group') { const at = toWorld(e.clientX, e.clientY); addNode('text', {text:''}, {x:at.x - 130, y:at.y - 30}, true); return; }
      startEditing(node); return;
    }
    if (e.target.closest('.cedge-hit,.cedge-label')) return;
    const at = toWorld(e.clientX, e.clientY); addNode('text', {text:''}, {x:at.x - 130, y:at.y - 30}, true);
  });
  viewport.addEventListener('contextmenu', e => {
    if (e.target.closest('.canvas-create,.canvas-controls,.canvas-selection-menu,input,textarea')) return;
    e.preventDefault();
    const nodeElement = e.target.closest('.cnode');
    if (nodeElement) { const node = byId.get(nodeElement.dataset.nodeId); if (!node) return; if (!selected.has(node.id)) choose([node.id]); nodeMenu(node, {x:e.clientX, y:e.clientY}); }
    else canvasMenu({x:e.clientX, y:e.clientY}, toWorld(e.clientX, e.clientY));
  });
  viewport.addEventListener('wheel', e => {
    if (e.target.closest('.cnode.selected .cnode-embed .base-body') && !(e.ctrlKey || e.metaKey)) return;
    if (e.target.closest('.cnode-body.markdown,.cnode-editor') && !(e.ctrlKey || e.metaKey) && e.target.closest('.cnode')?.classList.contains('selected')) {
      const body = e.target.closest('.cnode-body,.cnode-editor'); if (body.scrollHeight > body.clientHeight) return;
    }
    e.preventDefault();
    const r = viewport.getBoundingClientRect();
    if (e.ctrlKey || e.metaKey) zoomTo(camera.zoom * Math.exp(-e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.01)), e.clientX - r.left, e.clientY - r.top);
    else { camera = {...camera, x:camera.x - e.deltaX, y:camera.y - e.deltaY}; applyCamera(); }
  }, {passive:false});
  // Safari trackpad pinch.
  let gestureZoom = 1;
  viewport.addEventListener('gesturestart', e => { e.preventDefault(); gestureZoom = camera.zoom; });
  viewport.addEventListener('gesturechange', e => { e.preventDefault(); const r = viewport.getBoundingClientRect(); zoomTo(gestureZoom * e.scale, e.clientX - r.left, e.clientY - r.top); });
  const keyup = e => { if (e.key === ' ') { spaceDown = false; viewport.classList.remove('pan-ready'); } };
  addEventListener('keyup', keyup);

  // ---------------------------------------------------------------- initial render
  for (const node of doc.nodes) if (byId.get(node?.id) === node) build(node);
  drawEdges();
  if (!nodes.length) {
    const empty = el('div', null, 'canvas-empty'); empty.append(el('div', 'Double-click to add a card', 'canvas-empty-title'), el('div', 'Drag from a card’s edge to connect it. Drag on empty space to select.', 'muted'));
    viewport.append(empty);
  }
  choose([...selected]);
  const resize = new ResizeObserver(() => { if (!state.fitted && !state.camera) fit(); else placeToolbar(); });
  resize.observe(viewport);
  if (state.camera && nodes.length) applyCamera(); else if (frame(nodes)) state.fitted = true;
  requestAnimationFrame(() => { if (!destroyed && !state.fitted && !state.camera) fit(); });
  ctx.onFiles?.(() => filesListeners.forEach(f => f()));

  return {
    key(e) {
      const meta = e.metaKey || e.ctrlKey;
      if (e.key === ' ' && !e.repeat) { spaceDown = true; viewport.classList.add('pan-ready'); e.preventDefault(); return; }
      if ((e.key === 'Delete' || e.key === 'Backspace') && selected.size) { e.preventDefault(); removeSelection(); return; }
      if (e.key === 'Escape') { if (drag) { drag.pending?.remove(); drag = null; marquee.hidden = true; markTarget(null); viewport.classList.remove('connecting', 'panning'); } else choose([]); closeMenus(); return; }
      if (e.key === 'Enter' && selected.size === 1) { const node = selectionNodes()[0]; if (node) { e.preventDefault(); startEditing(node); } return; }
      if (meta && e.key.toLowerCase() === 'a') { e.preventDefault(); choose([...nodes.map(n => n.id), ...doc.edges.filter(edgeValid).map(x => x.id)]); return; }
      if (meta && e.key.toLowerCase() === 'd') { e.preventDefault(); duplicate(); return; }
      if (meta && (e.key === '=' || e.key === '+')) { e.preventDefault(); zoomTo(camera.zoom * 1.25); return; }
      if (meta && e.key === '-') { e.preventDefault(); zoomTo(camera.zoom / 1.25); return; }
      if (meta && e.key === '0') { e.preventDefault(); zoomTo(1); return; }
      if (e.shiftKey && (e.key === '!' || e.code === 'Digit1')) { e.preventDefault(); fit(); return; }
      if (e.shiftKey && (e.key === '@' || e.code === 'Digit2')) { e.preventDefault(); zoomToSelection(); return; }
      const arrows = {ArrowUp:[0, -1], ArrowDown:[0, 1], ArrowLeft:[-1, 0], ArrowRight:[1, 0]};
      if (arrows[e.key] && selectionNodes().length) {
        e.preventDefault(); const step = e.shiftKey ? 1 : state.snapGrid ? GRID : 10, [ax, ay] = arrows[e.key];
        const moving = movingSet(selectionNodes()); for (const n of moving) { n.x += ax * step; n.y += ay * step; paintNode(n); }
        drawEdges(new Set(moving.map(n => n.id))); placeToolbar(); clearTimeout(nudge); nudge = setTimeout(() => commit(), 400);
      }
    },
    destroy() {
      destroyed = true; finishEditing(); resize.disconnect(); observer.disconnect(); embeds.forEach(embed => embed.destroy()); closeMenus(); closePopover(); closeSuggest();
      document.removeEventListener('copy', onCopy); document.removeEventListener('cut', onCut); document.removeEventListener('paste', onPaste);
      removeEventListener('keyup', keyup); state.selection = [...selected];
    }
  };
}
let nudge;
