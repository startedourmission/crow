// Bases and Canvas embedded in Markdown notes: ```base blocks and ![[File.base#View]] /
// ![[File.canvas]]. They reuse the full editors with a host bridge to the app.
import {baseEditor} from './base-editor.js';
import {canvasEditor} from './canvas-editor.js';
import {updateNoteProperty, record, noteProperty, yaml} from './obsidian-model.js';
import {el, button, icon} from './obsidian-ui.js';

/* global __EMBED_CSS__ */
let styled = false;
function style() {
  if (styled) return; styled = true;
  const scoped = typeof __EMBED_CSS__ === 'undefined' ? '' : __EMBED_CSS__;
  const node = document.createElement('style'); node.textContent = scoped + EMBED_FRAME; document.head.append(node);
}
const EMBED_FRAME = `.note-embed{position:relative;margin:.6em 0;border:1px solid #e3e3e6;border-radius:8px;overflow:hidden;background:#fff;font-size:13px;line-height:normal;user-select:none;-webkit-user-select:none}
.note-embed-body{display:flex;flex-direction:column}
.obsidian-embed{display:flex;flex-direction:column;min-height:120px;max-height:520px;color:#222;font:13px -apple-system,BlinkMacSystemFont,'Apple SD Gothic Neo',sans-serif;text-align:left}
.obsidian-embed.embed-canvas{height:420px;max-height:none}
.obsidian-embed .embed-main{flex:1;min-height:0;display:flex;flex-direction:column;position:relative}
.obsidian-embed .embed-header{display:flex;align-items:center;gap:6px;padding:6px 10px;border-bottom:1px solid #e3e3e6;font-size:12px;color:#6b6b72}
.obsidian-embed .embed-title{color:inherit;text-decoration:none;font-weight:500}.obsidian-embed .embed-title:hover{text-decoration:underline}
.obsidian-embed .embed-notice{position:absolute;left:50%;bottom:10px;transform:translateX(-50%);background:#2b2b30;color:#fff;border-radius:6px;padding:6px 10px;font-size:12px;z-index:20}
.obsidian-embed .embed-notice.error{background:#9c2f2f}
.obsidian-embed .canvas-controls{top:8px;right:8px}.obsidian-embed .canvas-create{bottom:10px}
.embed-edit-source{position:absolute;top:6px;right:6px;z-index:30;display:inline-flex;border:0;background:#ffffffd0;border-radius:5px;padding:4px;opacity:0;transition:opacity .15s;cursor:pointer;color:#55555c}
.note-embed:hover .embed-edit-source{opacity:1}.embed-edit-source svg{width:15px;height:15px}
.embed-source-hidden{display:none!important}`;
let host = null, filesPromise = null, shared = {files:[], types:null, thisPath:null};
const embeds = new Set();
export function setEmbedHost(value) { host = value; }
export function refreshEmbedFiles() { filesPromise = null; for (const embed of embeds) embed.reload(); }
function loadFiles() {
  filesPromise ??= host.request('files', {}).then(value => {
    if (value.error) throw Error(value.error);
    shared = {files:value.files ?? [], types:value.types ?? null, thisPath:value.thisPath ?? null};
    return shared;
  }).catch(e => { filesPromise = null; throw e; });
  return filesPromise;
}
const imageCache = new Map();

export function mountEmbed(container, {kind, source = null, file = null, view = null, key, onChange = null}) {
  style();
  container.classList.add('obsidian-embed', 'embed-' + kind);
  const main = el('main', null, 'embed-main'), notice = el('div', '', 'embed-notice'); notice.hidden = true;
  const header = el('div', null, 'embed-header');
  if (file) {
    const title = el('a', file.split('/').pop(), 'embed-title'); title.href = '#';
    title.onclick = e => { e.preventDefault(); host.post('open', {path:file}); };
    header.append(icon(kind === 'canvas' ? 'frame' : 'table'), title);
    container.append(header);
  }
  container.append(main, notice);
  const data = {kind, path:key, source:source ?? '', files:[], types:null, loading:true, thisPath:null, selectedView:0};
  let controller = null, destroyed = false, fileText = null, writing = Promise.resolve();
  const say = (message, error = false) => { notice.textContent = message; notice.hidden = false; notice.classList.toggle('error', error); clearTimeout(say.timer); say.timer = setTimeout(() => { notice.hidden = true; }, error ? 5000 : 2200); };
  function applyImage(target, value, background, style) {
    if (value.image) {
      if (background) { target.style.backgroundImage = 'url("' + value.image + '")'; target.style.backgroundSize = style === 'repeat' ? 'auto' : style === 'ratio' ? 'contain' : 'cover'; target.style.backgroundRepeat = style === 'repeat' ? 'repeat' : 'no-repeat'; }
      else { const img = el('img'); img.src = value.image; img.draggable = false; target.replaceChildren(img); }
    } else if (!background && value.error) target.title = value.error;
  }
  const request = (action, payload) => host.request(action, payload);
  const ctx = {
    embedded: true, get data() { return data; }, main,
    open: path => host.post(/^[a-z][a-z0-9+.-]*:/i.test(path) ? 'open' : 'open', {path}),
    openWiki: target => host.post('openWiki', {path:target}),
    change(next, options = {}) {
      if (next === data.source) return;
      data.source = next;
      if (onChange) onChange(next);
      else if (file) {
        const expected = fileText;
        writing = writing.then(async () => {
          const result = await request('writeFile', {path:file, expected, source:next});
          if (result.ok) fileText = next; else { say(result.error || 'Could not save the embedded file.', true); await reload(); }
        });
      }
      if (options.render !== false) render();
    },
    record() {}, notice: say, tools() {}, render: () => render(),
    asset(path, target, background = false, style = 'cover') {
      const key = path;
      if (imageCache.has(key)) { applyImage(target, imageCache.get(key), background, style); return; }
      request('asset', {path}).then(value => { if (!value.error) { imageCache.set(key, value); if (imageCache.size > 100) imageCache.delete(imageCache.keys().next().value); } applyImage(target, value, background, style); });
    },
    load: req => request(req.action, req),
    selectView() {}, files: () => data.files, requestFiles() {}, onFiles() {},
    createNote() { if (file) host.post('open', {path:file}); say('Open the Base to create notes.'); },
    renameFile() { say('Rename the note from its own tab.'); },
    copy() {}, exportFile() { say('Open the Base to export it.'); },
    property(path, column, value) {
      const index = data.files.findIndex(f => f.path === path), current = data.files[index];
      if (!current || typeof current.text !== 'string') return Promise.reject(Error('This note has not been loaded.'));
      const next = updateNoteProperty(current.text, column, typeof value === 'function' ? value(record(current).note[noteProperty(column)]) : value);
      return request('property', {path, expected:current.text, source:next}).then(result => {
        if (!result.ok) throw Error(result.error || 'Could not save property.');
        const updated = {...current, text:next, modified:Date.now() / 1000};
        data.files = data.files.map(f => f === current ? updated : f);
        shared.files = shared.files.map(f => f.path === path ? updated : f);
        for (const embed of embeds) embed.filesChanged?.();
      });
    },
    get busy() { return false; }
  };
  function render() {
    if (destroyed) return;
    if (controller?.update?.()) return;
    controller?.destroy?.(); controller = null; main.replaceChildren();
    try { controller = kind === 'canvas' ? canvasEditor(ctx) : baseEditor(ctx); }
    catch (e) { main.replaceChildren(el('div', e.message, 'empty error')); }
  }
  async function reload() {
    try {
      if (file) {
        const value = await request('readFile', {path:file});
        if (value.error) throw Error(value.error);
        fileText = value.text; data.source = value.text;
      }
      if (kind === 'base') {
        const loaded = await loadFiles();
        data.files = loaded.files; data.types = loaded.types; data.thisPath = loaded.thisPath;
        if (view) { const views = yaml(data.source).views ?? [], index = views.findIndex(v => v?.name === view); if (index >= 0) data.selectedView = index; }
      } else {
        const loaded = await loadFiles().catch(() => shared);
        data.files = loaded.files;
      }
      data.loading = false; if (!destroyed) render();
    } catch (e) { data.loading = false; main.replaceChildren(el('div', e.message, 'empty error')); }
  }
  // Keys go to the embedded editor, not the surrounding note.
  container.addEventListener('keydown', e => {
    if (e.target.closest('input,textarea,select')) return;
    e.stopPropagation(); controller?.key?.(e);
  });
  const entry = {reload, filesChanged:() => { if (kind === 'base') { data.files = shared.files; render(); } }};
  embeds.add(entry);
  render(); reload();
  return {
    update(next) { if (next === data.source) return; data.source = next; render(); },
    destroy() { destroyed = true; embeds.delete(entry); controller?.destroy?.(); controller = null; }
  };
}
