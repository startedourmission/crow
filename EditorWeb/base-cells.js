// Value rendering and in-place editors shared by every Bases layout.
import {el, button, icon, autosize, autogrow} from './obsidian-ui.js';
import {display, isEmptyValue, Link, CellError, BaseImage, BaseIcon, BaseHTML, isFile, formatDate, parseDate} from './bases-engine.js';
import {noteProperty} from './obsidian-model.js';

const urlPattern = /^(https?:\/\/|mailto:)[^\s]+$/i;
const imageExt = /\.(png|jpe?g|gif|webp|bmp|svg|heic|tiff?|avif)$/i;
export const isImagePath = path => imageExt.test(String(path ?? '').split('#')[0]);

// Allow only inert formatting tags from html() formulas.
const allowedTags = new Set(['B','STRONG','I','EM','U','S','SPAN','DIV','P','BR','SMALL','SUB','SUP','CODE','MARK','UL','OL','LI','A','IMG','TABLE','TR','TD','TH','TBODY','THEAD','BLOCKQUOTE','H1','H2','H3','H4','H5','H6','HR','DEL','INS','KBD','PRE']);
export function sanitize(html) {
  const doc = new DOMParser().parseFromString('<body>' + html + '</body>', 'text/html');
  const walk = node => {
    for (const child of [...node.children]) {
      if (!allowedTags.has(child.tagName)) { child.replaceWith(...(['SCRIPT','STYLE','IFRAME','OBJECT','EMBED','TEMPLATE'].includes(child.tagName) ? [] : child.childNodes)); continue; }
      for (const attr of [...child.attributes]) {
        const name = attr.name.toLowerCase();
        if (name.startsWith('on') || !['href','src','title','alt','class','colspan','rowspan','width','height'].includes(name) ||
            (name === 'href' || name === 'src') && /^\s*(javascript|data(?!:image\/))/i.test(attr.value)) child.removeAttribute(attr.name);
      }
      walk(child);
    }
  };
  walk(doc.body); return doc.body.innerHTML;
}

export function linkTarget(value, from, B) {
  if (value instanceof Link) {
    if (value.external) return {url:value.path};
    const path = value.path ? B.resolve(value.path, from) : from;
    return {path, target:value.path + value.subpath, subpath:value.subpath};
  }
  if (isFile(value)) return {path:value.path};
  return null;
}
function linkNode(label, value, from, B, cls = 'internal-link') {
  const target = linkTarget(value, from, B), node = el('a', label, cls);
  node.href = '#'; if (target?.url) { node.classList.add('external-link'); node.title = target.url; }
  else if (target && !target.path) node.classList.add('unresolved');
  node.onclick = e => {
    e.preventDefault(); e.stopPropagation();
    if (target?.url) B.open(target.url);
    else if (target?.path) B.open(target.path + (target.subpath ?? ''));
    else if (target?.target) B.openWiki(target.target);
  };
  return node;
}
// Plain strings keep inline [[wikilinks]] and URLs clickable, as in Obsidian.
function richText(text, from, B) {
  const span = el('span', null, 'cell-text');
  const pattern = /(!?\[\[[^\]\n]+\]\])|(https?:\/\/[^\s<>"')\]]+)/g;
  let last = 0;
  for (const m of text.matchAll(pattern)) {
    if (m.index > last) span.append(text.slice(last, m.index));
    if (m[1]) { const link = new Link(m[1]); span.append(linkNode(link.toString(), link, from, B)); }
    else span.append(linkNode(m[2], new Link(m[2]), from, B, 'external-link'));
    last = m.index + m[0].length;
  }
  if (last < text.length) span.append(text.slice(last));
  return span;
}
export function imageSource(value, from, B) {
  if (value instanceof BaseImage) value = value.src;
  if (Array.isArray(value)) value = value[0];
  if (value == null) return null;
  if (value instanceof Link) {
    if (value.external) return {url:value.path};
    const path = B.resolve(value.path, from); return path ? {path} : null;
  }
  if (isFile(value)) return {path:value.path};
  const s = String(value).trim();
  if (/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(s)) return {color:s};
  if (/^https?:\/\//i.test(s)) return {url:s};
  if (/^!?\[\[/.test(s)) return imageSource(new Link(s), from, B);
  if (!s) return null;
  const path = B.resolve(s, from); return path ? {path} : null;
}
export function imageNode(source, B, cls = 'cell-image') {
  const holder = el('span', null, cls);
  if (source?.color) { holder.classList.add('swatch'); holder.style.background = source.color; return holder; }
  if (source?.path || source?.url) B.asset(source.path ?? source.url, holder);
  return holder;
}

export function renderValue(value, B, options = {}) {
  const {from = '', column = '', type = ''} = options;
  if (value instanceof CellError) {
    const node = el('span', null, 'cell-error'); node.append(icon('type'), el('span', 'Error')); node.title = value.error; return node;
  }
  if (value == null || value === '' || Array.isArray(value) && !value.length) return el('span', '', 'cell-empty');
  if (typeof value === 'boolean') {
    const box = el('input'); box.type = 'checkbox'; box.checked = value; box.className = 'cell-checkbox'; box.tabIndex = -1;
    box.disabled = !options.toggle; if (options.toggle) box.onclick = e => { e.stopPropagation(); options.toggle(box.checked); };
    return box;
  }
  if (value instanceof Date) return el('span', display(value), 'cell-date');
  if (typeof value === 'number') return el('span', display(value), 'cell-number');
  if (value instanceof Link) {
    if (value.embed && isImagePath(value.path)) return imageNode(imageSource(value, from, B), B);
    return linkNode(value.toString(), value, from, B);
  }
  if (isFile(value)) return linkNode(value.basename, value, from, B);
  if (value instanceof BaseImage) return imageNode(imageSource(value, from, B), B);
  if (value instanceof BaseIcon) { const node = el('span', null, 'cell-icon'); node.append(icon(iconAlias(value.name))); node.title = value.name; return node; }
  if (value instanceof BaseHTML) { const node = el('span', null, 'cell-html'); node.innerHTML = sanitize(value.html); return node; }
  if (Array.isArray(value)) {
    const list = el('span', null, 'cell-chips');
    const tags = type === 'tags' || column === 'file.tags' || column === 'tags' || column === 'note.tags';
    for (const item of value) {
      const chip = el('span', null, 'chip' + (tags ? ' tag-chip' : ''));
      if (tags && typeof item === 'string') chip.textContent = item.replace(/^#/, '');
      else chip.append(renderValue(item, B, {from}));
      list.append(chip);
    }
    return list;
  }
  if (typeof value === 'string') {
    if (urlPattern.test(value.trim())) return linkNode(value.trim(), new Link(value.trim()), from, B, 'external-link');
    if (/^\[\[[^\]\n]+\]\]$/.test(value.trim()) || value.includes('[[') || /https?:\/\//.test(value)) return richText(value, from, B);
    return el('span', value, 'cell-text');
  }
  if (typeof value === 'object') return el('span', display(value), 'cell-object');
  return el('span', display(value), 'cell-text');
}
const iconAliases = {'arrow-right':'arrowRight','arrow-left':'arrowLeft','arrow-up':'arrowUp','arrow-down':'arrowDown','check':'check','x':'close',
  'plus':'plus','minus':'minus','calendar':'calendar','file':'file','link':'link','image':'image','hash':'hash','list':'list','star':'magic','search':'search'};
const iconAlias = name => iconAliases[name] ?? (name in iconAliases ? name : 'target');

// Serialize a typed property value for YAML while keeping links as [[wikilinks]].
function rawScalar(value) {
  if (value instanceof Link) return value.external ? value.path : '[[' + value.path + value.subpath + (value.display != null ? '|' + value.display : '') + ']]';
  if (value instanceof Date) return formatDate(value, value.getHours() || value.getMinutes() ? 'YYYY-MM-DDTHH:mm' : 'YYYY-MM-DD');
  return value;
}
export function editableText(value) {
  if (value == null) return '';
  if (Array.isArray(value)) return value.map(v => display(rawScalar(v))).join(', ');
  return display(rawScalar(value));
}
function parseValue(textValue, type) {
  const t = textValue.trim();
  if (!t) return null;
  if (type === 'number') { const n = Number(t.replace(/,/g, '')); if (!Number.isFinite(n)) throw Error('Enter a valid number.'); return n; }
  if (type === 'checkbox') return /^(true|yes|1|x|✓)$/i.test(t);
  if (type === 'date') { const d = parseDate(t); if (!d) throw Error('Enter a date like 2025-01-31.'); return formatDate(d, 'YYYY-MM-DD'); }
  if (type === 'datetime') { const d = parseDate(t); if (!d) throw Error('Enter a date and time like 2025-01-31 14:00.'); return formatDate(d, 'YYYY-MM-DDTHH:mm'); }
  if (['multitext', 'tags', 'aliases'].includes(type)) return splitList(textValue, type);
  return textValue;
}
function splitList(textValue, type) {
  const items = []; let depth = 0, current = '';
  for (const ch of textValue) {
    if (ch === '[') depth++; if (ch === ']') depth = Math.max(0, depth - 1);
    if ((ch === ',' || ch === '\n' || ch === '\t') && !depth) { items.push(current); current = ''; } else current += ch;
  }
  items.push(current);
  return items.map(v => v.trim()).filter(Boolean).map(v => type === 'tags' ? v.replace(/^#/, '') : v);
}
export const valueFromText = parseValue;

// Replace the cell's content with an editor. `commit(value)` returns a promise;
// `finish()` is called once editing ends, whether saved or cancelled.
export function openEditor(holder, {type, raw, initial = null, commit, finish, label}) {
  const done = {closed:false};
  const close = () => { if (done.closed) return; done.closed = true; finish(); };
  const save = async value => {
    if (done.closed) return;
    try { await commit(value); close(); }
    catch (e) { done.closed = false; holder.classList.add('edit-error'); holder.title = e.message; throw e; }
  };
  holder.classList.add('editing'); holder.replaceChildren();
  if (['multitext', 'tags', 'aliases'].includes(type)) return chipEditor(holder, {type, raw, initial, save, close, label});
  let field;
  if (type === 'date' || type === 'datetime') {
    field = el('input'); field.type = type === 'date' ? 'date' : 'datetime-local';
    const d = parseDate(Array.isArray(raw) ? raw[0] : raw);
    field.value = d ? formatDate(d, type === 'date' ? 'YYYY-MM-DD' : 'YYYY-MM-DDTHH:mm') : '';
  } else if (type === 'number') {
    field = el('input'); field.type = 'text'; field.inputMode = 'decimal'; field.value = initial ?? editableText(raw);
  } else {
    field = el('textarea'); field.rows = 1; field.value = initial ?? editableText(raw); autogrow(field);
  }
  field.className = 'cell-editor'; field.spellcheck = false; field.setAttribute('aria-label', label);
  const original = field.value;
  let committing = false;
  const submit = async () => {
    if (committing) return; committing = true;
    try {
      if (field.value === original && initial == null) { close(); return; }
      await save(parseValue(field.value, type));
    } catch (e) { field.setCustomValidity(e.message); field.reportValidity(); committing = false; }
  };
  field.onkeydown = e => {
    if (e.isComposing || e.keyCode === 229) return;
    e.stopPropagation();
    if (e.key === 'Escape') { e.preventDefault(); committing = true; close(); }
    else if (e.key === 'Enter' && !e.shiftKey && !e.altKey) { e.preventDefault(); submit(); }
    else if (e.key === 'Tab') { e.preventDefault(); submit().then(() => holder.dispatchEvent(new CustomEvent('cell-tab', {bubbles:true, detail:{back:e.shiftKey}}))); }
  };
  field.oninput = () => field.setCustomValidity('');
  field.onblur = () => { if (!committing) submit(); };
  holder.append(field);
  requestAnimationFrame(() => { field.focus(); if (initial == null && field.select && field.type !== 'date' && field.type !== 'datetime-local') field.setSelectionRange?.(field.value.length, field.value.length); });
  return {field};
}
function chipEditor(holder, {type, raw, initial, save, close, label}) {
  const values = (Array.isArray(raw) ? raw : raw == null || raw === '' ? [] : [raw]).map(v => display(rawScalar(v)));
  const wrap = el('div', null, 'chip-editor'), entry = el('input');
  entry.className = 'chip-input'; entry.placeholder = values.length ? '' : 'Add…'; entry.setAttribute('aria-label', label + ' · Add item'); entry.spellcheck = false;
  if (initial != null) entry.value = initial;
  let committing = false;
  const draw = () => {
    wrap.querySelectorAll('.chip').forEach(c => c.remove());
    values.forEach((value, index) => {
      const chip = el('span', null, 'chip' + (type === 'tags' ? ' tag-chip' : ''));
      chip.append(el('span', type === 'tags' ? value.replace(/^#/, '') : value));
      const remove = button(null, e => { e.preventDefault(); values.splice(index, 1); draw(); entry.focus(); }, 'chip-remove');
      remove.setAttribute('aria-label', 'Remove ' + value); remove.tabIndex = -1; remove.append(icon('close'));
      remove.onpointerdown = e => e.preventDefault();
      chip.append(remove); wrap.insertBefore(chip, entry);
    });
    entry.placeholder = values.length ? '' : 'Add…'; fit();
  };
  const addEntry = () => { for (const v of splitList(entry.value, type)) values.push(v); entry.value = ''; draw(); };
  const submit = async () => {
    if (committing) return; committing = true; addEntry();
    const before = (Array.isArray(raw) ? raw : raw == null || raw === '' ? [] : [raw]).map(v => display(rawScalar(v)));
    if (JSON.stringify(before) === JSON.stringify(values)) { close(); return; }
    try { await save(values.length ? values.map(v => type === 'tags' ? v.replace(/^#/, '') : v) : null); }
    catch { committing = false; }
  };
  entry.onkeydown = e => {
    if (e.isComposing || e.keyCode === 229) return;
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); if (entry.value.trim()) addEntry(); else submit(); }
    else if (e.key === ',' ) { e.preventDefault(); addEntry(); }
    else if (e.key === 'Backspace' && !entry.value && values.length) { e.preventDefault(); values.pop(); draw(); }
    else if (e.key === 'Escape') { e.preventDefault(); committing = true; close(); }
    else if (e.key === 'Tab') { e.preventDefault(); submit().then(() => holder.dispatchEvent(new CustomEvent('cell-tab', {bubbles:true, detail:{back:e.shiftKey}}))); }
  };
  entry.onblur = () => setTimeout(() => { if (!wrap.contains(document.activeElement) && !committing) submit(); }, 0);
  wrap.onpointerdown = e => { if (e.target === wrap) { e.preventDefault(); entry.focus(); } };
  wrap.append(entry); holder.append(wrap);
  const fit = autosize(entry, 30, 10);
  draw(); requestAnimationFrame(() => entry.focus());
  return {field:entry};
}
export function rawValue(row, column) {
  const key = noteProperty(column);
  return key && row.record?.raw ? row.record.raw[key] ?? null : null;
}
export {isEmptyValue};
