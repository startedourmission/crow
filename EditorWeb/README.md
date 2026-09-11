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

HTML blocks reuse the editor's existing schema/parser instead of rebuilding all
extensions for each block. Native source-map parsing runs off the UI thread with
stale-result rejection and an evictable 8-entry/8 MiB source-keyed cache. Font-only
updates change CSS without parsing or resetting selection. Initial content is not
editable until its source maps arrive.

Markdown/source mode is an app-session preference, so selecting another Markdown
file (including after visiting code files) keeps the selected mode. Document Find
temporarily exposes source without changing that preference.

Reference: https://tiptap.dev/docs/editor/markdown/getting-started/basic-usage
