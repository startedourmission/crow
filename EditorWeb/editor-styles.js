export const markdownEditorCSS = `
  .note-file-heading { margin: 0 0 22px; padding: 0; border: 0; font-size: 2em; line-height: 1.3; font-weight: 650; }
  .note-file-title { resize: none; overflow: hidden; white-space: pre-wrap; overflow-wrap: anywhere; display: block; width: 100%; min-width: 0; padding: 0; border: 0; border-radius: 0; background: transparent; color: inherit; font: inherit; line-height: inherit; outline: none; }
  .note-file-title:focus { box-shadow: 0 1px #a0a0a050; }
  .note-title-error { font-size: 12px; font-weight: 400; color: #b34343; }
  .note-title-error:empty { display: none; }

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
  .frontmatter-heading { margin: 0 0 8px; font-size: 11px; font-weight: 500; color: #85858b; }
  .frontmatter-row { display: grid; grid-template-columns: 26px minmax(90px, 28%) minmax(0,1fr) 24px; align-items: center; gap: 8px; min-height: 38px; border-radius: 5px; }
  .frontmatter-row:hover { background: #80808008; }
  .frontmatter input,.frontmatter textarea,.frontmatter select,.frontmatter button { font: inherit; color: inherit; }
  .frontmatter input:not([type=checkbox]),.frontmatter textarea { min-width: 0; width: 100%; padding: 5px 4px; border: 1px solid transparent; border-radius: 4px; background: transparent; }
  .frontmatter-linked-value { display: flex; align-items: center; min-width: 0; gap: 4px; }
  .frontmatter .frontmatter-linked-value > .has-property-link { width: var(--property-link-width, auto); max-width: calc(100% - 28px); flex: 0 1 auto; }
  .frontmatter .frontmatter-list-item > .has-property-link { width: var(--property-link-width, auto)!important; flex: 0 1 auto; }
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
