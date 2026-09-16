import {base, updateNoteProperty} from './obsidian-model.js';
import {canvasEditor} from './canvas-editor.js';
import {baseEditor} from './base-editor.js';
import {el, iconButton} from './obsidian-ui.js';

const send = body => window.webkit.messageHandlers.obsidian.postMessage(body);
const main = document.querySelector('main');
let data, controller, generation = 0, sequence = 0;
let undo = [], redo = [], assets = new Map(), cache = new Map(), pending = new Map();
function notice(message, error = false) {
  let node = document.querySelector('.notice');
  if (!node) { node = el('div', null, 'notice'); document.body.append(node); }
  node.textContent = message; node.classList.toggle('error', error);
  clearTimeout(node.dismissTimer);
  if (!error) node.dismissTimer = setTimeout(() => node.remove(), 2600);
}
function open(path) { send({action:'open', path}); }
function renderAsset(path, target, background = false, style = 'cover', markdown = false) {
  const key = (markdown ? 'markdown:' : 'file:') + path;
  const item = {target, background, style, key};
  if (cache.has(key)) { applyAsset(item, cache.get(key)); return; }
  const id = generation + ':' + sequence++; assets.set(id, item);
  send(markdown ? {action:'markdown', text:path, id} : {action:'asset', path, id});
}
function applyAsset({target, background, style}, value) {
  if (target.dataset.editing === 'true') return;
  if (value.image) {
    if (background) {
      target.style.backgroundImage = 'url("' + value.image + '")';
      target.style.backgroundSize = style === 'repeat' ? 'auto' : style === 'ratio' ? 'contain' : 'cover';
      target.style.backgroundRepeat = style === 'repeat' ? 'repeat' : 'no-repeat';
    } else { const image = el('img'); image.src = value.image; target.replaceChildren(image); }
  } else if (!background) {
    if (value.html != null) { target.innerHTML = value.html; }
    else target.textContent = value.error ?? 'Open this attachment to view it.';
  }
}
function record(before, after, path = null) {
  if (before === after) return;
  undo.push({before, after, path}); if (undo.length > 100) undo.shift(); redo = [];
  main.querySelectorAll('[data-history]').forEach(b => b.disabled = b.dataset.history === 'undo' ? !undo.length : !redo.length);
}
function change(source, options = {}) {
  if (source === data.source) return;
  const before = data.source; data.source = source;
  if (options.history !== false) record(before, source);
  send({action:'change', source, expected:before});
  if (options.render !== false) render();
}
function writeProperty(path, source, options = {}) {
  if (pending.size) return Promise.reject(Error('Wait for the current property edit to finish.'));
  const file = data.files.find(file => file.path === path);
  if (!file || typeof file.text !== 'string') return Promise.reject(Error('This note has not been loaded.'));
  const id = String(++sequence), before = file.text;
  return new Promise((resolve, reject) => {
    pending.set(id, {path, before, source, options, resolve, reject});
    send({action:'property', id, path, expected:before, source});
  });
}
async function travel(backwards) {
  if (pending.size) return;
  const from = backwards ? undo : redo, to = backwards ? redo : undo, entry = from.at(-1);
  if (!entry) return;
  try {
    const next = backwards ? entry.before : entry.after;
    if (entry.path) await writeProperty(entry.path, next, {history:false, render:false});
    else change(next, {history:false, render:false});
    from.pop(); to.push(entry); render();
  } catch (e) { notice(e.message, true); }
}
function tools(header) {
  const spacer = el('span', null, 'toolbar-spacer');
  const back = iconButton('undo', 'Undo', () => travel(true)), forward = iconButton('redo', 'Redo', () => travel(false));
  back.dataset.history = 'undo'; forward.dataset.history = 'redo';
  back.disabled = !undo.length || pending.size > 0; forward.disabled = !redo.length || pending.size > 0;
  header.append(spacer, back, forward, iconButton('save', 'Save (⌘S)', () => send({action:'save'})));
}
function render() {
  controller?.destroy?.(); generation++; assets.clear(); main.replaceChildren();
  if (!data) return;
  const context = {
    data, main, open, change, record, notice, tools, asset:renderAsset, render,
    property: async (path, column, value) => {
      const file = data.files.find(file => file.path === path);
      return writeProperty(path, updateNoteProperty(file?.text, column, value));
    },
    get busy() { return pending.size > 0; }
  };
  try { controller = data.kind === 'canvas' ? canvasEditor(context) : baseEditor(context); }
  catch (e) { main.append(el('div', e.message, 'empty error')); }
}
window.crowObsidian = {
  validateBase(value) {
    try { base(value.source, [], value.path, 0); return true; }
    catch (e) { main.replaceChildren(el('p', e.message, 'error')); return false; }
  },
  receive(value) {
    if (data?.path !== value.path || data?.source !== value.source) { undo = []; redo = []; }
    cache.clear();
    if (value.kind === 'canvas' && value.html) {
      try {
        for (const node of JSON.parse(value.source).nodes ?? []) {
          if (node.type === 'text' && value.html[node.id] != null) cache.set('markdown:' + node.text, {html:value.html[node.id]});
        }
      } catch {}
    }
    data = value; render();
  },
  rejectSource(source) {
    data.source = source; undo = []; redo = []; render();
    notice('The document changed outside this view. Its latest content has been reloaded.', true);
  },
  saved(ok) { notice(ok ? 'Saved' : 'Could not save. Check the file conflict or connection.', !ok); },
  propertyResult(id, result) {
    const item = pending.get(id); if (!item) return; pending.delete(id);
    if (!result.ok) { item.reject(Error(result.error || 'Could not save property.')); return; }
    const file = data.files.find(file => file.path === item.path);
    if (file) { file.text = item.source; file.modified = Date.now() / 1000; }
    if (item.options.history !== false) record(item.before, item.source, item.path);
    item.resolve();
    if (item.options.render !== false) render();
  },
  asset(id, value) {
    const item = assets.get(id); if (!item) return; assets.delete(id);
    if (!value.error) { cache.set(item.key, value); if (cache.size > 64) cache.delete(cache.keys().next().value); }
    applyAsset(item, value);
  }
};
document.addEventListener('click', e => {
  const link = e.target.closest('a'); if (link) { e.preventDefault(); open(link.getAttribute('href')); }
});
document.addEventListener('keydown', e => {
  const typing = e.target.closest('input,textarea,[contenteditable=true]');
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
    e.preventDefault(); if (typing) typing.blur(); send({action:'save'}); return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z' && !typing) {
    e.preventDefault(); travel(!e.shiftKey); return;
  }
  if (!typing && !document.querySelector('dialog[open]')) controller?.key?.(e);
});
