import {base, updateNoteProperty, record as noteRecord, noteProperty} from './obsidian-model.js';
import {Document as YAMLDocument} from 'yaml';
import {canvasEditor} from './canvas-editor.js';
import {baseEditor} from './base-editor.js';
import {el, iconButton} from './obsidian-ui.js';

const post = body => window.webkit.messageHandlers.obsidian.postMessage(body);
// Canvas and Bases paths are relative to the Obsidian vault; the host works in
// workspace paths. Translate at this single boundary.
let vault = '';
const toWorkspace = path => !vault || path == null || /^[a-z][a-z0-9+.-]*:/i.test(path) ? path : vault + '/' + String(path).replace(/^\/+/, '');
const send = body => {
  const out = {...body};
  if (typeof out.path === 'string' && out.action !== 'openWiki') out.path = toWorkspace(out.path);
  if (typeof out.folder === 'string') out.folder = out.folder ? toWorkspace(out.folder) : vault;
  post(out);
};
const mapped = new WeakMap();
function vaultFiles(files) {
  if (!vault) return files;
  const prefix = vault + '/', out = [];
  for (const file of files) {
    if (!file.path.startsWith(prefix)) continue;
    let view = mapped.get(file);
    if (!view) { view = {...file, path:file.path.slice(prefix.length)}; mapped.set(file, view); }
    out.push(view);
  }
  return out;
}
const fromWorkspace = path => vault && path.startsWith(vault + '/') ? path.slice(vault.length + 1) : path;
const main = document.querySelector('main');
let data, controller, generation = 0, sequence = 0;
let propertyQueue = Promise.resolve();
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
  const request=markdown ? {action:'markdown',text:path} : {action:'asset',path};
  const item = {target, background, style, key, request, retries:0};
  if (cache.has(key)) { applyAsset(item, cache.get(key)); return; }
  const id = generation + ':' + sequence++; assets.set(id, item);
  send({...request,id});
}
// Promise-based host requests (file contents, link previews) share the asset channel.
const loads = new Map();
function load(request) {
  const key = JSON.stringify(request);
  if (cache.has(key)) return Promise.resolve(cache.get(key));
  if (loads.has(key)) return loads.get(key).promise;
  let resolve; const promise = new Promise(r => { resolve = r; });
  const id = generation + ':' + sequence++;
  loads.set(key, {promise}); assets.set(id, {load:true, key, request, retries:0, resolve});
  send({...request, id}); return promise;
}
let filesCallbacks = new Set(), filesRequested = false;
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
  syncHistory();
}
function syncHistory() { main.querySelectorAll('[data-history]').forEach(b => b.disabled = pending.size > 0 || (b.dataset.history === 'undo' ? !undo.length : !redo.length)); }
// Canvas and Base documents save automatically shortly after each edit, like Obsidian.
let saveTimer = null;
function scheduleSave(delay = 900) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { saveTimer = null; send({action:'save', silent:'true'}); }, delay);
}
function flushSave() { if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; send({action:'save', silent:'true'}); } }
addEventListener('blur', flushSave); document.addEventListener('visibilitychange', () => { if (document.hidden) flushSave(); });
function change(source, options = {}) {
  if (source === data.source) return;
  const before = data.source; data.source = source;
  if (options.history !== false) record(before, source);
  send({action:'change', source, expected:before});
  scheduleSave(options.history === false ? 1500 : 900);
  if (options.render !== false) render();
}
function writeProperty(path, source, options = {}) {
  if (pending.size) return Promise.reject(Error('Wait for the current property edit to finish.'));
  const file = data.files.find(file => file.path === path);
  if (!file || typeof file.text !== 'string') return Promise.reject(Error('This note has not been loaded.'));
  const id = String(++sequence), before = file.text;
  return new Promise((resolve, reject) => {
    pending.set(id, {path, before, source, options, resolve, reject});
    syncHistory();
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
  const spacer = header.querySelector('.toolbar-spacer') ? el('span', null, 'toolbar-gap') : el('span', null, 'toolbar-spacer');
  const back = iconButton('undo', 'Undo', () => travel(true)), forward = iconButton('redo', 'Redo', () => travel(false));
  back.dataset.history = 'undo'; forward.dataset.history = 'redo';
  back.disabled = !undo.length || pending.size > 0; forward.disabled = !redo.length || pending.size > 0;
  header.append(spacer, back, forward);
}
function render() {
  syncHistory();
  if (controller?.update?.()) return;
  controller?.destroy?.(); generation++; assets.clear(); loads.clear(); filesCallbacks = new Set(); main.replaceChildren();
  controller = null;
  if (!data) return;
  const context = {
    get data() { return data; }, main, open, openWiki: path=>send({action:"openWiki",path}), change, record, notice, tools, asset:renderAsset, render,
    selectView: index => send({action:'selectView', index:String(index)}),
    createNote: (folder, properties = {}) => {
      const doc = new YAMLDocument(properties);
      const content = Object.keys(properties).length ? '---\n' + doc.toString() + '---\n' : '';
      send({action:'createNote', folder:folder ?? '', content});
    },
    renameFile: (path, name) => send({action:'rename', path, name}),
    copy: text => send({action:'copy', text}),
    exportFile: (name, text) => send({action:'export', name, text}),
    files: () => data.files ?? [],
    load,
    requestFiles: () => { if (data.kind === 'canvas' && !filesRequested) { filesRequested = true; send({action:'files'}); } },
    onFiles: callback => { filesCallbacks.add(callback); },
    property: (path, column, value) => {
      const documentPath=data.path;
      const request=propertyQueue.catch(()=>{}).then(()=>{
        if(data.path!==documentPath)throw Error('The Base was closed before this edit could be saved.');
        const file=data.files.find(file=>file.path===path);
        const next=typeof value==='function'?value(noteRecord(file).note[noteProperty(column)]):value;
        return writeProperty(path,updateNoteProperty(file?.text,column,next));
      });
      propertyQueue=request;return request;
    },
    get busy() { return pending.size > 0; }
  };
  try { controller = data.kind === 'canvas' ? canvasEditor(context) : baseEditor(context); }
  catch (e) { main.append(el('div', e.message, 'empty error')); }
}
window.crowObsidian = {
  validateBase(value) {
    try { base(value.source, [], value.path, 0); return true; }
    catch (e) { controller?.destroy?.(); controller=null; main.replaceChildren(el('p', e.message, 'error')); return false; }
  },
  receive(value) {
    vault = value.vault ?? vault ?? '';
    value.path = fromWorkspace(value.path);
    if (data?.path !== value.path || data?.source !== value.source) { undo = []; redo = []; }
    if (data) data = {...data, files:data.rawFiles};
    if (data?.path === value.path && value.incremental) {
      const files = new Map((data.files ?? []).map(file => [file.path, file]));
      for (const path of value.removed ?? []) files.delete(path);
      for (const file of value.files ?? []) files.set(file.path, file);
      value.files = [...files.values()];
    }
    if (data?.path === value.path && value.files) {
      const previous = new Map((data.files ?? []).map(file => [file.path, file]));
      value.files = value.files.map(file => {
        const old = previous.get(file.path);
        return old && old.text === file.text && old.size === file.size && old.modified === file.modified && old.created === file.created ? old : file;
      });
    }
    cache.clear(); if (data?.path !== value.path) filesRequested = false;
    if (value.kind === 'canvas' && !value.files && data?.path === value.path && data.rawFiles) { value.files = data.rawFiles; }
    value.rawFiles = value.files; if (value.files) value.files = vaultFiles(value.files);
    data = value; render();
  },
  stopLoading(source, warning) {
    if (data?.kind === 'base' && data.source === source) { data = {...data, loading:false, warning}; render(); }
  },
  failed(message) {
    if (data?.kind === 'base') { data = {...data, loading:false, warning:message}; render(); }
    else { controller?.destroy?.(); controller=null; main.replaceChildren(el('div',message,'empty error')); }
  },
  rejectSource(source) {
    data.source = source; undo = []; redo = []; render();
    notice('The document changed outside this view. Its latest content has been reloaded.', true);
  },
  saved(ok, silent) { if (!ok) notice('Could not save. Check the file conflict or connection.', true); else if (!silent) notice('Saved'); },
  // Files created, renamed or deleted from this view update the loaded inventory in place.
  updateFiles(files, removed) {
    if (!data || data.kind !== 'base') return;
    const map = new Map((data.rawFiles ?? []).map(file => [file.path, file]));
    for (const path of removed ?? []) map.delete(path);
    for (const file of files ?? []) map.set(file.path, file);
    const raw = [...map.values()];
    data = {...data, rawFiles:raw, files:vaultFiles(raw)}; render();
  },
  renamed(from, to) {
    if (!data?.rawFiles) return;
    const file = data.rawFiles.find(f => f.path === from);
    if (file) this.updateFiles([{...file, path:to}], [from]);
  },
  propertyResult(id, result) {
    const item = pending.get(id); if (!item) return; pending.delete(id);
    if (!result.ok) { syncHistory(); item.reject(Error(result.error || 'Could not save property.')); return; }
    const workspacePath = toWorkspace(item.path), now = Date.now() / 1000;
    data.rawFiles = (data.rawFiles ?? []).map(file => file.path === workspacePath ? {...file, text:item.source, modified:now} : file);
    data.files = vaultFiles(data.rawFiles);
    if (item.options.history !== false) record(item.before, item.source, item.path);
    item.resolve();
    if (item.options.render !== false) render();
  },
  setFiles(files) {
    if (!data) return;
    data.rawFiles = files; data.files = vaultFiles(files);
    filesCallbacks.forEach(callback => callback());
  },
  asset(id, value) {
    const item = assets.get(id); if (!item) return;
    if (item.load) {
      if (value.pending === 'true' && item.retries++ < 45) { setTimeout(() => { if (assets.get(id) === item) send({...item.request, id}); }, Math.min(4000, 700 + item.retries * 200)); return; }
      assets.delete(id); loads.delete(item.key);
      if (!value.error) { cache.set(item.key, value); if (cache.size > 200) cache.delete(cache.keys().next().value); }
      item.resolve(value); return;
    }
    if(value.pending==='true' && item.retries++ < 45){
      applyAsset(item,value);
      setTimeout(()=>{if(assets.get(id)===item)send({...item.request,id});},Math.min(4000,700+item.retries*200));
      return;
    }
    assets.delete(id);
    if(value.pending==='true')value={error:'iCloud download is still pending. Refresh to try again.'};
    if (!value.error) { cache.set(item.key, value); if (cache.size > 64) cache.delete(cache.keys().next().value); }
    applyAsset(item, value);
  }
};
document.addEventListener('click', e => {
  const link = e.target.closest('a'); if (link) { e.preventDefault(); open(link.getAttribute('href')); }
});
document.addEventListener('keydown', e => {
  const typing = e.target.closest?.('input,textarea,[contenteditable=true]');
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
    e.preventDefault(); if (typing) typing.blur(); clearTimeout(saveTimer); saveTimer = null; send({action:'save'}); return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z' && !typing) {
    e.preventDefault(); travel(!e.shiftKey); return;
  }
  if (!document.querySelector('dialog[open]') && (!typing || (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f')) controller?.key?.(e);
});
