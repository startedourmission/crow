# Crow Markdown editor

The checked-in `App/Editor/markdown-editor.js` runs offline inside WKWebView's isolated
client world. Xcode builds do not need Node or network access. Page JavaScript and
remote resource loading stay disabled.

To rebuild after editing `editor.js` (Node 22+):

```
npm ci --ignore-scripts
npm run build
```

Commit the source, lockfile, generated bundle and generated license notices together.
Tiptap/ProseMirror owns rich-text selection, composition, undo and Markdown input rules.
The bridge preserves unmodified source blocks and source-mappable text edits; structural
edits serialize only the changed blocks into Markdown.

Reference: https://tiptap.dev/docs/editor/markdown/getting-started/basic-usage
