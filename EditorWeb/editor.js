import { Editor, Extension, createNodeFromContent } from '@tiptap/core';
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
`;
document.head.append(style);
let source = '', records = [], loading = false, initialized = false, pending = null;
let modifiers = {control: false, shift: false};
const send = body => window.webkit.messageHandlers.markdown.postMessage(body);
const shortcuts = Extension.create({
  name: 'crowShortcuts',
  addKeyboardShortcuts() { return { 'Mod-s': () => { send({action: 'save'}); return true; } }; },
});
const extensions = [StarterKit.configure({ link: { openOnClick: false }, trailingNode: false }),
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
      pieces.push({ text: editor.markdown.serialize({type: 'doc', content: [nodes[index++]]}), original: false });
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
    handleClickOn(_view, _pos, node, _nodePos, event) {
      if (!(event.metaKey || event.ctrlKey)) return false;
      const link = node.marks.find(mark => mark.type.name === 'link');
      if (link && /^(https?:|mailto:)/i.test(link.attrs.href)) {
        send({action: 'openLink', url: link.attrs.href}); return true;
      }
      return false;
    },
    handlePaste(_view, event) {
      // Paste only text/Markdown; foreign HTML cannot add embedded resources or styles.
      const text = event.clipboardData?.getData('text/plain');
      if (text === undefined) return false;
      editor.commands.insertContent(text, {contentType: 'markdown'}); return true;
    },
    handleDOMEvents: {
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

function receive(value, blocks, fontSize) {
  document.body.style.fontSize = Math.min(32, Math.max(11, fontSize)) + 'px';
  if (initialized && value === source) return; // Never reset selection or IME on a binding echo.
  if (editor.view.composing) { pending = [value, blocks, fontSize]; return; }
  loading = true;
  try {
    const nodes = []; records = [];
    let offset = 0;
    for (const block of blocks) {
      // generateJSON rebuilds every extension/schema for every block. Reuse the
      // live editor's schema and its cached DOM parser for the whole document.
      const parsed = createNodeFromContent(block.html, editor.schema, {slice: false}).toJSON().content ?? [];
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
window.crowMarkdown = { receive, jumpHeading, setFontSize, insertText, key: keyboardKey,
  setModifiers(control, shift) { modifiers = {control, shift}; } };
