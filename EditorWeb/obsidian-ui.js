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
  plus: 'M12 5v14M5 12h14', minus: 'M5 12h14', fit: 'M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5',
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
  arrow: 'M4 12h16m-6-6 6 6-6 6', close: 'm5 5 14 14M19 5 5 19'
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
export const color = value => /^#[0-9a-f]{6}$/i.test(value ?? '') ? value :
  ({1:'#dc6269',2:'#d68d4c',3:'#b9a440',4:'#53a680',5:'#579fc0',6:'#9b79bf'}[value] ?? '#b5bcc8');
