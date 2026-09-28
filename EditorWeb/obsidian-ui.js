export const el = (name, text, cls) => {
  const node = document.createElement(name);
  if (text != null) node.textContent = String(text);
  if (cls) node.className = cls;
  return node;
};
export function button(title, action, cls = '') {
  const node = el('button', title, cls); node.type = 'button'; node.onclick = action; return node;
}
const glyphs = {
  text: 'M4 6h16M4 12h16M4 18h10', checkbox: 'M4 4h16v16H4V4Zm4 8 3 3 5-6',
  plus: 'M12 5v14M5 12h14', minus: 'M5 12h14', fit: 'M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5',
  sliders: 'M4 6h6m4 0h6M4 12h12m4 0h0M4 18h2m4 0h10M10 3v6m6 0v6M6 15v6',
  history: 'M3 4v5h5M3 9a9 9 0 1 1 0 6M12 7v5l3 2', refresh: 'M20 4v5h-5M4 20v-5h5M4 9a8 8 0 0 1 13-5l3 5M4 15l3 5a8 8 0 0 0 13-5',
  undo: 'M8 5 3 10l5 5M3 10h11a6 6 0 0 1 0 12', redo: 'm16 5 5 5-5 5m5-5H10a6 6 0 0 0 0 12',
  save: 'M5 3h12l4 4v14H3V3h2Zm2 0v6h10V3M7 21v-8h10v8',
  note: 'M5 3h14v18H5V3Zm3 5h8m-8 4h8m-8 4h5',
  group: 'M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5M8 8h8v8H8z',
  file: 'M14 3H5v18h14V8l-5-5Zm0 0v5h5', link: 'm10 13 4-4m-6 6-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m2 2 1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0',
  trash: 'M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7',
  edit: 'm15 4 5 5M4 16l-1 5 5-1L21 7l-5-5L4 16Z',
  settings: 'M4 7h16M4 17h16M8 4v6m8 4v6', table: 'M3 4h18v16H3V4Zm0 5h18M9 9v11m6-11v11',
  cards: 'M3 4h7v7H3V4Zm11 0h7v7h-7V4ZM3 15h7v6H3v-6Zm11 0h7v6h-7v-6Z',
  search: 'M17 10a7 7 0 1 1-14 0 7 7 0 0 1 14 0Zm-2 5 6 6',
  filter: 'M3 6h18M6 12h12M10 18h4', sort: 'M7 3v18m-4-4 4 4 4-4M17 21V3m-4 4 4-4 4 4',
  properties: 'M8 6h13M8 12h13M8 18h13M3 6h1M3 12h1M3 18h1',
  type: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18Zm0 7v7m0-10v.5',
  number: 'M9 3 7 21M17 3l-2 18M3 9h18M2 15h18',
  calendar: 'M5 5h14v16H5V5Zm3-3v6m8-6v6M5 10h14',
  formula: 'M3 3h18v18H3V3Zm5 5h8M11 8v9m-3-4h7',
  arrow: 'M4 12h16m-6-6 6 6-6 6', close: 'm5 5 14 14M19 5 5 19',
  chevronDown: 'm6 9 6 6 6-6', chevronRight: 'm9 6 6 6-6 6', chevronLeft: 'm15 6-6 6 6 6', check: 'm5 12 5 5 9-10',
  grip: 'M9 5h.01M9 12h.01M9 19h.01M15 5h.01M15 12h.01M15 19h.01', more: 'M5 12h.01M12 12h.01M19 12h.01',
  eyeOff: 'M3 3l18 18M10.6 10.6a2 2 0 0 0 2.8 2.8M9.9 5.1A9 9 0 0 1 21 12a13 13 0 0 1-2.2 3M6.6 6.6A13 13 0 0 0 3 12s3 7 9 7a9 9 0 0 0 4-1',
  calculator: 'M5 3h14v18H5V3Zm3 4h8M8 11h.01M12 11h.01M16 11h.01M8 15h.01M12 15h.01M16 15h.01M8 18h.01M12 18h4',
  copy: 'M9 9h11v11H9V9Zm-4 6H4V4h11v1', download: 'M12 3v12m-5-5 5 5 5-5M4 21h16',
  list: 'M8 6h13M8 12h13M8 18h13M3 6h1M3 12h1M3 18h1', kanban: 'M4 4h16v16H4V4Zm5 0v16m6-16v16',
  map: 'm3 6 6-3 6 3 6-3v15l-6 3-6-3-6 3V6Zm6-3v15m6-12v15', image: 'M4 4h16v16H4V4Zm0 12 5-5 4 4 2-2 5 5M15 9h.01',
  link2: 'M9 17H7a5 5 0 0 1 0-10h2m6 0h2a5 5 0 0 1 0 10h-2M8 12h8', hash: 'M4 9h16M4 15h16M10 3 8 21M16 3l-2 18',
  pencil: 'm15 4 5 5M4 16l-1 5 5-1L21 7l-5-5L4 16Z', duplicate: 'M9 9h11v11H9V9Zm-4 6H4V4h11v1', arrowUp: 'M12 20V4m-6 6 6-6 6 6',
  arrowDown: 'M12 4v16m-6-6 6 6 6-6', arrowLeft: 'M20 12H4m6-6-6 6 6 6', arrowRight: 'M4 12h16m-6-6 6 6-6 6',
  code: 'm8 7-5 5 5 5m8-10 5 5-5 5', layers: 'm12 3 9 5-9 5-9-5 9-5Zm-9 9 9 5 9-5M3 16l9 5 9-5',
  palette: 'M12 3a9 9 0 1 0 0 18c1 0 1.5-.8 1.5-1.6 0-1.4-1.2-1.6-1.2-2.8 0-1 .8-1.6 1.8-1.6H17a4 4 0 0 0 4-4c0-4.4-4-8-9-8Zm-5 9h.01M9 7h.01M15 7h.01',
  lock: 'M6 11h12v10H6V11Zm2 0V7a4 4 0 0 1 8 0v4', unlock: 'M6 11h12v10H6V11Zm2 0V7a4 4 0 0 1 7.5-2',
  target: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18Zm0 5a4 4 0 1 1 0 8 4 4 0 0 1 0-8Z', globe: 'M12 3a9 9 0 1 1 0 18 9 9 0 0 1 0-18ZM3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',
  pdf: 'M14 3H5v18h14V8l-5-5Zm0 0v5h5M8 13h2a1.5 1.5 0 0 1 0 3H8v-4m0 4v2', audio: 'M9 18V5l12-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm12-2a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z',
  video: 'M3 6h13v12H3V6Zm13 4 5-3v10l-5-3', frame: 'M3 7V3h4m10 0h4v4m0 10v4h-4M7 21H3v-4',
  magic: 'm5 19 11-11m-3-3 3 3M7 3v4M5 5h4M19 13v4m-2-2h4', select: 'M4 4l7 17 2-7 7-2-16-8Z', hand: 'M8 13V5a2 2 0 0 1 4 0v6m0-1V4a2 2 0 0 1 4 0v7m0-3a2 2 0 0 1 4 0v6a7 7 0 0 1-14 0v-3a2 2 0 0 1 4 0'
};
export function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('aria-hidden', 'true');
  svg.innerHTML = '<path d="' + (glyphs[name] || glyphs.note) + '" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>';
  return svg;
}
export function iconButton(name, title, action, text = '') {
  const node = button(null, action, 'icon-button');
  node.title = title; node.setAttribute('aria-label', title); node.append(icon(name));
  if (text) node.append(el('span', text));
  return node;
}
export function field(label, input) {
  const wrapper = el('label', null, 'field'); wrapper.append(el('span', label), input); return wrapper;
}
export function input(value = '', type = 'text') {
  const node = el('input'); node.type = type; node.value = value ?? ''; return node;
}
export function select(options, value) {
  const node = el('select');
  options.forEach(([key, label]) => { const item = el('option', label); item.value = key; node.append(item); });
  node.value = value; return node;
}
export function dialog(title, build) {
  const modal = el('dialog'), form = el('form');
  const heading = el('div', null, 'dialog-heading');
  heading.append(el('h2', title), iconButton('close', 'Close', () => modal.close()));
  form.append(heading); modal.append(form); document.body.append(modal);
  modal.addEventListener('close', () => modal.remove());
  modal.addEventListener('click', e => { if (e.target === modal) modal.close(); });
  form.onsubmit = e => e.preventDefault();
  build(form, () => modal.close());
  modal.showModal(); return modal;
}
export function actions(form, close, apply, label = 'Apply') {
  const row = el('div', null, 'dialog-actions'), error = el('p', '', 'field-error');
  const submit = button(label, async () => {
    try { await apply(); close(); } catch (e) { error.textContent = e.message; }
  }, 'primary');
  row.append(button('Cancel', close), submit); form.append(error, row);
  form.onsubmit = e => { e.preventDefault(); submit.click(); };
}
let dismissPopover;
export function closePopover() { dismissPopover?.(); }
export function popover(anchor, title, build, options = {}) {
  const wasOpen = anchor.getAttribute('aria-expanded') === 'true';
  closePopover(); if (wasOpen) return;
  const panel = el('div', null, 'popover' + (options.wide ? ' wide' : '')), form = el('form');
  panel.setAttribute('role', 'dialog'); panel.setAttribute('aria-label', title);
  anchor.setAttribute('aria-expanded', 'true');
  const close = () => {
    panel.remove(); anchor.setAttribute('aria-expanded', 'false');
    document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', key, true);
    window.removeEventListener('resize', position); dismissPopover = null;
  };
  const outside = e => { if (!panel.contains(e.target) && !anchor.contains(e.target) && !e.target.closest?.('.menu,dialog')) close(); };
  const key = e => { if (e.key === 'Escape' && !activeMenus.length && !document.querySelector('dialog[open]')) { e.preventDefault(); e.stopPropagation(); close(); anchor.focus(); } };
  const position = () => {
    const rect = anchor.getBoundingClientRect();
    panel.style.left = Math.max(8, Math.min(rect.right - panel.offsetWidth, innerWidth - panel.offsetWidth - 8)) + 'px';
    panel.style.top = (rect.bottom + 6) + 'px';
    panel.style.maxHeight = Math.max(80, innerHeight - rect.bottom - 14) + 'px';
  };
  form.onsubmit = e => e.preventDefault(); panel.append(form); document.body.append(panel);
  build(form, close); position(); dismissPopover = close;
  document.addEventListener('pointerdown', outside, true); document.addEventListener('keydown', key, true);
  window.addEventListener('resize', position);
  form.querySelector('input,select,button,textarea')?.focus();
  return panel;
}
// Obsidian's six canvas presets; "0"/missing uses the neutral card border.
export const presetColors = {1:'#e93147',2:'#ec7500',3:'#e0ac00',4:'#08b94e',5:'#00bfbc',6:'#7852ee'};
export const presetNames = {1:'Red',2:'Orange',3:'Yellow',4:'Green',5:'Cyan',6:'Purple'};
let measureContext;
export function textWidth(text, font) {
  measureContext ??= document.createElement('canvas').getContext('2d');
  measureContext.font = font; return measureContext.measureText(text).width;
}
// Size an input to its text using real glyph metrics (CJK glyphs are wide).
export function autosize(field, min = 24, extra = 6) {
  const fit = () => { const style = getComputedStyle(field); field.style.width = Math.max(min, Math.ceil(textWidth(field.value || field.placeholder || '', style.font) + extra)) + 'px'; };
  field.addEventListener('input', fit); requestAnimationFrame(fit); fit(); return fit;
}
export function autogrow(area) {
  const fit = () => { area.style.height = 'auto'; area.style.height = area.scrollHeight + 'px'; };
  area.addEventListener('input', fit); requestAnimationFrame(fit); return fit;
}
export function toggle(checked, onchange, label = '') {
  const node = el('input'); node.type = 'checkbox'; node.checked = !!checked; node.className = 'toggle'; node.setAttribute('role', 'switch');
  if (label) node.setAttribute('aria-label', label);
  node.onchange = () => onchange(node.checked); return node;
}
export function slider(value, min, max, step, onchange, label = '') {
  const node = el('input'); node.type = 'range'; node.min = min; node.max = max; node.step = step; node.value = value;
  if (label) node.setAttribute('aria-label', label);
  node.oninput = () => onchange(Number(node.value), false); node.onchange = () => onchange(Number(node.value), true); return node;
}
// Context menus: items are {label, icon, action, checked, danger, disabled, submenu:[items]} or 'separator'.
let activeMenus = [];
export function closeMenus(depth = 0) { activeMenus.splice(depth).forEach(m => m.remove()); if (!activeMenus.length) document.removeEventListener('pointerdown', outsideMenu, true); }
function outsideMenu(e) { if (!activeMenus.some(m => m.contains(e.target))) closeMenus(); }
function menuKeys(e) {
  if (!activeMenus.length) { document.removeEventListener('keydown', menuKeys, true); return; }
  const menu = activeMenus.at(-1), items = [...menu.querySelectorAll('.menu-item:not([disabled])')];
  const index = items.indexOf(document.activeElement);
  if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeMenus(activeMenus.length - 1); activeMenus.at(-1)?.querySelector('.menu-item')?.focus(); }
  else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); e.stopPropagation(); items[(index + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus(); }
  else if (e.key === 'ArrowRight' && document.activeElement?.dataset.submenu) { e.preventDefault(); document.activeElement.click(); }
  else if (e.key === 'ArrowLeft' && activeMenus.length > 1) { e.preventDefault(); closeMenus(activeMenus.length - 1); }
}
export function menu(at, items, depth = 0) {
  closeMenus(depth);
  const node = el('div', null, 'menu'); node.setAttribute('role', 'menu');
  for (const item of items) {
    if (!item) continue;
    if (item === 'separator') { node.append(el('div', null, 'menu-separator')); continue; }
    if (item.heading) { node.append(el('div', item.heading, 'menu-heading')); continue; }
    const row = button(null, null, 'menu-item' + (item.danger ? ' danger' : '')); row.setAttribute('role', item.checked != null ? 'menuitemcheckbox' : 'menuitem');
    if (item.checked != null) row.setAttribute('aria-checked', String(!!item.checked));
    row.disabled = !!item.disabled;
    const mark = el('span', null, 'menu-icon'); if (item.icon) mark.append(icon(item.icon)); else if (item.swatch) { mark.classList.add('menu-swatch'); mark.style.background = item.swatch; }
    row.append(mark, el('span', item.label, 'menu-label'));
    if (item.hint) row.append(el('span', item.hint, 'menu-hint'));
    if (item.checked) row.append(icon('check'));
    if (item.submenu) { row.dataset.submenu = 'true'; row.append(icon('chevronRight')); }
    const open = () => { const r = row.getBoundingClientRect(); menu({x:r.right - 4, y:r.top - 5, flip:r.left + 4}, item.submenu, depth + 1); activeMenus.at(-1)?.querySelector('.menu-item')?.focus(); };
    row.onpointerenter = () => { if (item.submenu) open(); else closeMenus(depth + 1); };
    row.onclick = e => { e.stopPropagation(); if (item.submenu) { open(); return; } closeMenus(); item.action?.(); };
    node.append(row);
  }
  document.body.append(node); activeMenus.push(node);
  const point = at instanceof Element ? (() => { const r = at.getBoundingClientRect(); return {x:r.left, y:r.bottom + 4, above:r.top - 4}; })() : at;
  const width = node.offsetWidth, height = node.offsetHeight;
  let x = point.x, y = point.y;
  if (x + width > innerWidth - 6) x = point.flip != null ? point.flip - width : innerWidth - width - 6;
  if (y + height > innerHeight - 6) y = point.above != null && point.above - height > 6 ? point.above - height : Math.max(6, innerHeight - height - 6);
  node.style.left = Math.max(6, x) + 'px'; node.style.top = Math.max(6, y) + 'px';
  if (depth === 0) { document.addEventListener('pointerdown', outsideMenu, true); document.addEventListener('keydown', menuKeys, true); }
  return node;
}
export const color = value => /^#[0-9a-f]{6}$/i.test(value ?? '') ? value :
  (presetColors[value] ?? '#b5bcc8');
