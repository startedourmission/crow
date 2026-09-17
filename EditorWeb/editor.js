import {NoteCompletions, setCatalog} from './note-completions.js';
import {frontmatterView} from './frontmatter-editor.js';
import { Editor, Extension, Node, createNodeFromContent } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { Markdown } from '@tiptap/markdown';
import { TableKit } from '@tiptap/extension-table';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';

// A single ProseMirror document owns selection, IME, undo, lists and table editing.
// There are no per-block textareas or source/preview swaps on focus.
const main = document.querySelector('main');
const style = document.createElement('style');
style.textContent = `
  .tiptap { outline: none; min-height: calc(100vh - 104px); white-space: pre-wrap; }
  .tiptap > :first-child { margin-top: 0; }
  .tiptap p:empty::before { content: '\\200b'; }
  .tiptap table { display: table; table-layout: fixed; width: 100%; }
  .tiptap td,.tiptap th { border: 1px solid #dce0e5; padding: 7px 12px; vertical-align: top; position: relative; }
  .tiptap th { background: #f4f5f7; font-weight: 600; }
  .tiptap td p,.tiptap th p { margin: 0; }
  .tiptap .selectedCell::after { position: absolute; inset: 0; background: #182c4818; content: ''; pointer-events: none; }
  .tiptap ul[data-type=taskList] { list-style: none; padding-left: 0; }
  .tiptap li[data-type=taskItem] { display: flex; gap: .6em; }
  .tiptap li[data-type=taskItem] > div { flex: 1; }
  .tiptap li[data-type=taskItem] label { user-select: none; }
  .frontmatter { margin-bottom: 24px; font-size: 13px; }
  .frontmatter { white-space: normal; padding: 4px 0 12px; }
  .frontmatter h2 { margin: 0 0 12px; border: 0; font-size: 17px; font-weight: 600; }
  .frontmatter-row { display: grid; grid-template-columns: 26px minmax(90px, 28%) minmax(0,1fr) 24px; align-items: center; gap: 8px; min-height: 38px; border-radius: 5px; }
  .frontmatter-row:hover { background: #80808008; }
  .frontmatter input,.frontmatter textarea,.frontmatter select,.frontmatter button { font: inherit; color: inherit; }
  .frontmatter input:not([type=checkbox]),.frontmatter textarea { min-width: 0; width: 100%; padding: 5px 4px; border: 1px solid transparent; border-radius: 4px; background: transparent; }
  .frontmatter-linked-value { display: flex; align-items: center; min-width: 0; gap: 4px; }
  .frontmatter .property-link { color: #527ba7; text-decoration: none; flex-shrink: 0; padding: 4px; }
  .frontmatter textarea { resize: vertical; line-height: 1.5; }
  .frontmatter input:focus,.frontmatter textarea:focus { outline: none; border-color: #a0a0a050; background: #80808008; }
  .frontmatter .frontmatter-name { color: #85858b; }
  .frontmatter input[type=checkbox] { justify-self: start; margin: 5px; accent-color: #5e6776; }
  .frontmatter-type { display: grid; place-items: center; position: relative; width: 26px; height: 28px; color: #85858b; border-radius: 4px; }
  .frontmatter-type:hover,.frontmatter-type:focus-within { background: #80808018; }
  .frontmatter svg { width: 18px; height: 18px; }
  .frontmatter-type select { position: absolute; inset: 0; width: 100%; opacity: 0; cursor: pointer; }
  .frontmatter button { border: 0; background: transparent; border-radius: 4px; cursor: pointer; }
  .frontmatter button:hover { background: #80808015; }
  .frontmatter-add { color: #85858b!important; padding: 8px 4px; margin-top: 8px; text-align: left; }
  .frontmatter-remove { opacity: 0; padding: 2px; color: #85858b!important; }
  .frontmatter-row:hover .frontmatter-remove,.frontmatter-row:focus-within .frontmatter-remove { opacity: 1; }
  .frontmatter-error { color: #b34343; font-size: 12px; }
  .frontmatter-error:empty { display: none; }
  .frontmatter-list { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 10px; min-width: 0; }
  .frontmatter-list-item { display: inline-flex; align-items: center; gap: 2px; }
  .frontmatter-list-item input { width: auto!important; min-width: 2ch!important; padding: 3px 0!important; }
  .frontmatter-list-item button { color: #95959b; opacity: 0; padding: 0 2px; }
  .frontmatter-list-item:hover button,.frontmatter-list-item:focus-within button { opacity: 1; }
  .frontmatter-list>.frontmatter-list-add { width: 12ch!important; flex: 1; min-width: 8ch!important; padding: 3px 0!important; }
  .note-completions { position: fixed; z-index: 10000; max-height: 250px; overflow: auto; width: 350px; max-width: calc(100vw - 16px); padding: 4px; border: 1px solid #dedee3; border-radius: 7px; background: #fff; color: #292930; box-shadow: 0 5px 20px #0002; font: 13px -apple-system, sans-serif; }
  .note-completion { padding: 7px 9px; border-radius: 4px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
  .note-completion[aria-selected=true] { background: #eeeef3; }
  .frontmatter-new { display: flex; gap: 6px; margin-top: 8px; }
  .frontmatter-new select { max-width: 110px; }
  @media(pointer:coarse) { .frontmatter-remove { opacity: 1; } }

`;
document.head.append(style);
let noteLinksEnabled = false;
let source = '', records = [], loading = false, initialized = false, pending = null;
let modifiers = {control: false, shift: false};
const send = body => window.webkit.messageHandlers.markdown.postMessage(body);
const shortcuts = Extension.create({
  name: 'crowShortcuts',
  addKeyboardShortcuts() { return { 'Mod-s': () => { send({action: 'save'}); return true; } }; },
});
const Frontmatter = Node.create({
  name: 'frontmatter', group: 'block', atom: true, selectable: false,
  addAttributes() { return {source: {default: ''}}; },
  parseHTML() { return [{tag: 'section[data-frontmatter]'}]; },
  renderHTML() { return ['section', {'data-frontmatter':'', class:'frontmatter', contenteditable:'false'}]; },
  addNodeView() { return frontmatterView; },
  renderMarkdown(node) { return node.attrs.source; }
});
const WikiLink = Node.create({
  name: 'wikiLink', group: 'inline', inline: true, atom: true,
  addAttributes() { return {source: {default: ''}, target: {default: ''}, label: {default: ''}}; },
  parseHTML() { return [{tag: 'a[data-wikilink]'}]; },
  renderHTML({node}) { return ['a', {'data-wikilink': '', href: node.attrs.target, contenteditable: 'false'}, node.attrs.label]; },
  renderMarkdown(node) { return node.attrs.source; }
});
function wikiNodes(nodes, insideCode = false) {
  return nodes.flatMap(node => {
    if (node.content) return [{...node, content: wikiNodes(node.content, insideCode || node.type === 'codeBlock' || node.type === 'frontmatter')}];
    if (!noteLinksEnabled || insideCode || node.type !== 'text' || node.marks?.some(mark => ['code','link'].includes(mark.type))) return [node];
    const output = []; let cursor = 0;
    for (const match of node.text.matchAll(/!?\[\[([^\]\n]+)\]\]/g)) {
      if (match.index > cursor) output.push({...node, text: node.text.slice(cursor, match.index)});
      const [target, alias] = match[1].split('|');
      output.push({type: 'wikiLink', attrs: {source: match[0], target, label: alias || target}});
      cursor = match.index + match[0].length;
    }
    if (!output.length) return [node];
    if (cursor < node.text.length) output.push({...node, text: node.text.slice(cursor)});
    return output;
  });
}
const extensions = [Frontmatter, WikiLink, NoteCompletions, StarterKit.configure({ link: { openOnClick: false }, trailingNode: false }),
  Markdown, TableKit.configure({ table: { resizable: false } }), TaskList, TaskItem.configure({ nested: true }), shortcuts];
const signature = nodes => JSON.stringify(nodes);
const shape = nodes => JSON.stringify(nodes, (key, value) => key === 'text' ? '' : value);
const plain = nodes => nodes.map(node => node.text ?? plain(node.content ?? [])).join('');
const leaves = nodes => nodes.flatMap(node => node.text !== undefined ? [node.text] : leaves(node.content ?? []));

function patchText(record, nodes) {
  if (shape(record.nodes) !== shape(nodes)) return null;
  const before = plain(record.nodes);
  if (before !== record.mappedText || record.positions.length !== before.length) return null;
  const oldLeaves = leaves(record.nodes), newLeaves = leaves(nodes), edits = [];
  let offset = 0;
  for (let index = 0; index < oldLeaves.length; index++) {
    const oldText = oldLeaves[index], newText = newLeaves[index];
    let start = 0, end = oldText.length, newEnd = newText.length;
    while (start < end && start < newEnd && oldText[start] === newText[start]) start++;
    while (end > start && newEnd > start && oldText[end - 1] === newText[newEnd - 1]) { end--; newEnd--; }
    if (start !== end || start !== newEnd) {
      const from = start === oldText.length ? record.positions[offset + start - 1] + 1 : record.positions[offset + start];
      const to = end > start ? record.positions[offset + end - 1] + 1 : from;
      if (from == null || to == null || from < 0 || to > record.source.length) return null;
      edits.push({from, to, text: newText.slice(start, newEnd)});
    }
    offset += oldText.length;
  }
  let result = record.source;
  for (const edit of edits.reverse()) result = result.slice(0, edit.from) + edit.text + result.slice(edit.to);
  return result;
}

function serialize() {
  const nodes = editor.getJSON().content ?? [];
  const used = new Set();
  const pieces = [];
  for (let index = 0; index < nodes.length;) {
    let match = records.find(record => !used.has(record) &&
      signature(nodes.slice(index, index + record.nodes.length)) === record.signature);
    let text = match?.source;
    // Preserve exact Markdown delimiters, reference links and surrounding trivia for
    // plain text edits. Structural edits use the Markdown serializer for that block only.
    if (!match) {
      for (const record of records) {
        if (used.has(record)) continue;
        const candidate = patchText(record, nodes.slice(index, index + record.nodes.length));
        if (candidate !== null) { match = record; text = candidate; break; }
      }
    }
    if (match) { used.add(match); pieces.push({text, original: true}); index += match.nodes.length; }
    else {
      const node = nodes[index++];
      pieces.push({ text: editor.markdown.serialize({type: 'doc', content: [node]}), original: node.type === 'frontmatter' });
    }
  }
  let result = '';
  for (let index = 0; index < pieces.length; index++) {
    if (index && (!pieces[index - 1].original || !pieces[index].original)) {
      const breaks = result.match(/\n*$/)[0].length;
      result += '\n'.repeat(Math.max(0, 2 - breaks));
    }
    result += pieces[index].text;
  }
  if (source.endsWith('\n') && result && !result.endsWith('\n')) result += '\n';
  return result;
}

const editor = new Editor({
  element: main, extensions, content: '', injectCSS: false, editable: false,
  editorProps: {
    attributes: { 'aria-label': 'Markdown editor', spellcheck: 'false' },
    handlePaste(_view, event) {
      // Paste only text/Markdown; foreign HTML cannot add embedded resources or styles.
      const text = event.clipboardData?.getData('text/plain');
      if (text === undefined) return false;
      editor.commands.insertContent(text, {contentType: 'markdown'}); return true;
    },
    handleDOMEvents: {
      click(_view, event) {
        const link = event.target.closest('a'); if (!link) return false;
        const href = link.getAttribute('href') || '';
        if (!/^(https?:|mailto:)/i.test(href) && !(noteLinksEnabled && !/^[a-z][a-z0-9+.-]*:/i.test(href))) return false;
        event.preventDefault();
        if (href.startsWith('#')) {
          const anchor = decodeURIComponent(href.slice(1)).toLocaleLowerCase();
          const heading = [...main.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(h => h.textContent.toLocaleLowerCase() === anchor || h.textContent.toLocaleLowerCase().replace(/\s+/g, '-') === anchor);
          if (heading) heading.scrollIntoView({block: 'start'});
        } else send({action: 'openLink', url: href});
        return true;
      },
      beforeinput(_view, event) {
        if (event.isComposing || event.inputType !== 'insertText' || !event.data || (!modifiers.control && !modifiers.shift)) return false;
        event.preventDefault();
        const stroke = {key: event.data, ...modifiers};
        modifiers = {control: false, shift: false};
        send({action: 'keyboardModifiersConsumed'});
        keyboardKey(stroke); return true;
      },
      compositionend() {
        setTimeout(() => { if (pending) { const args = pending; pending = null; receive(...args); } }, 0);
        return false;
      },
    },
  },
  onUpdate() {
    if (loading) return;
    const value = serialize();
    if (value === source) return;
    const base = source; source = value;
    send({action: 'change', base, source});
  },
});

function receive(value, blocks, fontSize, linksEnabled = false) {
  const linksChanged = noteLinksEnabled !== linksEnabled;
  document.body.style.fontSize = Math.min(32, Math.max(11, fontSize)) + 'px';
  if (initialized && value === source && !linksChanged) return; // Never reset selection or IME on a binding echo.
  if (editor.view.composing) { pending = [value, blocks, fontSize, linksEnabled]; return; }
  noteLinksEnabled = linksEnabled;
  document.documentElement.dataset.noteLinks = String(linksEnabled);
  loading = true;
  try {
    const nodes = []; records = [];
    let offset = 0;
    for (const block of blocks) {
      // generateJSON rebuilds every extension/schema for every block. Reuse the
      // live editor's schema and its cached DOM parser for the whole document.
      let parsed = block.html.includes('data-crow-frontmatter=') ? [{type: 'frontmatter', attrs: {source: block.source}}] : createNodeFromContent(block.html, editor.schema, {slice: false}).toJSON().content ?? [];
      parsed = wikiNodes(parsed);
      // Keep unrendered content editable and recoverable rather than silently dropping it.
      if (!parsed.length) parsed.push({type: 'paragraph', ...(block.source.trim() ? {content: [{type: 'text', text: block.source}]} : {})});
      const holder = document.createElement('div'); holder.innerHTML = block.html;
      let mappedText = ''; const positions = [];
      for (const span of holder.querySelectorAll('[data-source-end]')) {
        const text = span.textContent, start = Number(span.dataset.sourceStart) - offset;
        mappedText += text;
        for (let index = 0; index < text.length; index++) positions.push(start + index);
      }
      records.push({nodes: parsed, signature: signature(parsed), source: block.source, mappedText, positions});
      nodes.push(...parsed); offset += block.source.length;
    }
    // Loading a document is not an edit. Otherwise the first Undo can erase the
    // entire note when ProseMirror groups initialization with the first keystroke.
    editor.chain().setContent({type: 'doc', content: nodes}, {emitUpdate: false})
      .setMeta('addToHistory', false).run();
    // Use schema-normalized JSON for equality checks (default attributes are added on parse).
    let index = 0; const normalized = editor.getJSON().content ?? [];
    for (const record of records) { record.nodes = normalized.slice(index, index + record.nodes.length); record.signature = signature(record.nodes); index += record.nodes.length; }
    source = value; initialized = true;
    editor.setEditable(true, false);
  } finally { loading = false; }
}
function jumpHeading(index) {
  let current = 0, target = null;
  editor.state.doc.descendants((node, position) => {
    if (node.type.name === 'heading' && current++ === index) target = position + 1;
  });
  if (target === null) return false;
  editor.chain().setTextSelection(target).focus().scrollIntoView().run();
  return true;
}
function setFontSize(fontSize) {
  document.body.style.fontSize = Math.min(32, Math.max(11, fontSize)) + 'px';
}
function insertText(text) {
  editor.view.dispatch(editor.state.tr.insertText(text));
}
function keyboardKey(key) {
  const name = key.key;
  if ((key.control || key.command) && ['c', 'x', 'v'].includes(name.toLowerCase())) {
    send({action: 'keyboardClipboard', key: name.toLowerCase(), text: window.getSelection()?.toString() ?? ''});
    if (name.toLowerCase() === 'x') editor.commands.deleteSelection();
    return;
  }
  if (name.startsWith('Arrow')) {
    const selection = window.getSelection();
    const direction = name === 'ArrowLeft' || name === 'ArrowUp' ? 'backward' : 'forward';
    const granularity = name === 'ArrowUp' || name === 'ArrowDown' ? 'line' : key.option || key.control ? 'word' : 'character';
    selection.modify(key.shift ? 'extend' : 'move', direction, granularity);
    if (selection.anchorNode && selection.focusNode && editor.view.dom.contains(selection.anchorNode) && editor.view.dom.contains(selection.focusNode)) {
      editor.commands.setTextSelection({from: editor.view.posAtDOM(selection.anchorNode, selection.anchorOffset), to: editor.view.posAtDOM(selection.focusNode, selection.focusOffset)});
    }
    return;
  }
  const shortcut = (key.control || key.command ? 'Mod-' : '') + (key.option ? 'Alt-' : '') + (key.shift ? 'Shift-' : '') + name;
  if (name === 'Tab') {
    if (key.shift) { if (!editor.commands.liftListItem('listItem')) editor.commands.liftListItem('taskItem'); }
    else if (!editor.commands.sinkListItem('listItem') && !editor.commands.sinkListItem('taskItem')) insertText('    ');
  } else if (!editor.commands.keyboardShortcut(shortcut) && !key.control && !key.command && name.length === 1) {
    insertText(key.shift ? name.toUpperCase() : name);
  }
}
window.crowMarkdown = { setCatalog, receive, jumpHeading, setFontSize, insertText, key: keyboardKey,
  setModifiers(control, shift) { modifiers = {control, shift}; } };
