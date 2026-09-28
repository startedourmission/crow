// Render ```base blocks and ![[File.base]] / ![[File.canvas]] embeds inside notes,
// as Obsidian does. The Markdown source stays in the document and reappears while
// the cursor is inside it.
import {Extension} from '@tiptap/core';
import {Plugin, PluginKey} from '@tiptap/pm/state';
import {Decoration, DecorationSet} from '@tiptap/pm/view';
import {mountEmbed} from './obsidian-embed.js';
import {icon} from './obsidian-ui.js';

const embedPattern = /^!\[\[([^\]|#]+\.(base|canvas))(#[^\]|]*)?(?:\|[^\]]*)?\]\]$/i;
const isBaseBlock = node => node.type.name === 'codeBlock' && String(node.attrs.language ?? '').toLowerCase() === 'base';
function fileEmbed(node) {
  if (node.type.name !== 'paragraph' || node.childCount !== 1) return null;
  const child = node.firstChild;
  const source = child.type.name === 'wikiLink' ? child.attrs.source : child.isText ? child.text.trim() : '';
  const m = embedPattern.exec(source ?? '');
  return m ? {file:m[1].trim(), kind:m[2].toLowerCase(), view:m[3] ? m[3].slice(1) : null} : null;
}
function scan(doc) {
  const items = []; let blocks = 0; const seen = new Map();
  doc.descendants((node, pos) => {
    if (isBaseBlock(node)) { const index = blocks++; items.push({kind:'base', block:index, key:'base-block-' + index, pos, end:pos + node.nodeSize, source:node.textContent}); return false; }
    const embed = fileEmbed(node);
    if (embed) {
      const id = embed.kind + ':' + embed.file + '#' + (embed.view ?? ''), n = seen.get(id) ?? 0; seen.set(id, n + 1);
      items.push({...embed, key:'file-' + id + '-' + n, pos, end:pos + node.nodeSize}); return false;
    }
    return node.isBlock && !node.isTextblock;
  });
  return items;
}

export const NoteEmbeds = Extension.create({
  name: 'noteEmbeds',
  addProseMirrorPlugins() {
    const editor = this.editor, key = new PluginKey('noteEmbeds'), mounted = new Map();
    const notePath = () => window.crowMarkdown?.notePath ?? 'Note.md';
    function blockAt(index) {
      let n = 0, found = null;
      editor.state.doc.descendants((node, pos) => { if (found) return false; if (isBaseBlock(node)) { if (n++ === index) found = {node, pos}; return false; } });
      return found;
    }
    function mount(item) {
      let entry = mounted.get(item.key);
      if (entry) return entry.dom;
      const dom = document.createElement('div'); dom.contentEditable = 'false'; dom.className = 'note-embed';
      dom.addEventListener('mousedown', e => e.stopPropagation());
      if (item.block != null) {
        const edit = document.createElement('button'); edit.type = 'button'; edit.className = 'embed-edit-source'; edit.title = 'Edit source'; edit.setAttribute('aria-label', 'Edit source');
        edit.append(icon('code'));
        edit.onclick = () => { const found = blockAt(item.block); if (found) editor.chain().setTextSelection(found.pos + 1).focus().scrollIntoView().run(); };
        dom.append(edit);
      }
      const holder = document.createElement('div'); holder.className = 'note-embed-body'; dom.append(holder);
      const embed = mountEmbed(holder, item.block != null ? {kind:'base', source:item.source, key:notePath() + '#' + item.key,
        onChange:next => {
          const found = blockAt(item.block); if (!found) return;
          const text = next.replace(/\n+$/, ''), {state} = editor;
          if (found.node.textContent === text) return;
          editor.view.dispatch(state.tr.replaceWith(found.pos + 1, found.pos + found.node.nodeSize - 1, text ? state.schema.text(text) : []));
        }} : {kind:item.kind, file:item.file, view:item.view, key:item.file});
      entry = {dom, embed, source:item.source}; mounted.set(item.key, entry);
      return dom;
    }
    function build(state) {
      const items = scan(state.doc), decorations = [], {from, to} = state.selection;
      for (const item of items) {
        const inside = from >= item.pos && to <= item.end && editor.isFocused;
        if (!inside) decorations.push(Decoration.node(item.pos, item.end, {class:'embed-source-hidden'}));
        decorations.push(Decoration.widget(item.end, () => mount(item), {key:item.key, side:-1, ignoreSelection:true, stopEvent:() => true}));
      }
      return {set:DecorationSet.create(state.doc, decorations), items};
    }
    return [new Plugin({
      key,
      state: {
        init: (_, state) => build(state),
        apply: (tr, old, _before, state) => tr.docChanged || tr.selectionSet || tr.getMeta('focus') != null ? build(state) : old
      },
      props: {
        decorations: state => key.getState(state).set,
        handleDOMEvents: {focus: view => { view.dispatch(view.state.tr.setMeta('focus', true)); return false; }, blur: view => { view.dispatch(view.state.tr.setMeta('focus', false)); return false; }}
      },
      view: () => ({
        update(view) {
          const {items} = key.getState(view.state), live = new Set(items.map(i => i.key));
          for (const item of items) {
            const entry = mounted.get(item.key);
            if (entry && item.block != null && entry.source !== item.source) { entry.source = item.source; entry.embed.update(item.source); }
          }
          for (const [k, entry] of mounted) if (!live.has(k)) { entry.embed.destroy(); mounted.delete(k); }
        },
        destroy() { for (const entry of mounted.values()) entry.embed.destroy(); mounted.clear(); }
      })
    })];
  }
});
