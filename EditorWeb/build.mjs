import { build } from 'esbuild';
import { readdir, readFile, writeFile } from 'node:fs/promises';
// Bases/Canvas embedded in notes reuse the preview stylesheet, scoped so it cannot
// restyle the Markdown editor. Menus, popovers and dialogs live on <body>.
const floating = /^(\.menu|\.popover|dialog|\.notice|\.kanban-ghost|\.column-drop|\.color-|\.file-picker|\.file-option)/;
const scope = ':is(.obsidian-embed,.menu,.popover,dialog)';
function scopeCSS(css) {
  return css.replace(/\/\*[\s\S]*?\*\//g, '').replace(/([^{}@]+)\{([^{}]*)\}/g, (rule, selectors, body) => {
    const list = selectors.split(',').map(s => s.trim()).filter(Boolean).flatMap(s => {
      if (/^(html|body)\b/.test(s)) return [];
      if (s === ':root') return [scope];
      if (s === 'main') return ['.obsidian-embed .embed-main'];
      if (floating.test(s)) return [s];
      return [scope + ' ' + s];
    });
    return list.length ? list.join(',') + '{' + body + '}' : '';
  });
}
const embedCSS = scopeCSS(await readFile('obsidian-preview.css', 'utf8'));
await build({ entryPoints: ['editor.js'], bundle: true, format: 'iife', target: 'safari18',
  minify: true, outfile: '../App/Editor/markdown-editor.js', legalComments: 'eof', define: {__EMBED_CSS__: JSON.stringify(embedCSS)} });
await build({ entryPoints: ['obsidian-preview.js'], bundle: true, format: 'iife', target: 'safari18',
  minify: true, outfile: '../App/Editor/obsidian-preview.js', legalComments: 'eof', define: {__EMBED_CSS__: '""'} });
await writeFile('../App/Editor/obsidian-preview.css', await readFile('obsidian-preview.css'));
await build({entryPoints:['crowmap.js'],bundle:true,format:'iife',target:'safari18',minify:true,outfile:'../App/Editor/crowmap.js',legalComments:'eof',define:{__EMBED_CSS__:'""'}});
await writeFile('../App/Editor/crowmap.css',await readFile('crowmap.css'));
// Ship notices for every bundled dependency, independently of minifier annotations.
const notices = [];
async function collect(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const path = `${directory}/${entry.name}`;
    if (entry.name.startsWith('@')) { await collect(path); continue; }
    for (const name of await readdir(path)) {
      if (/^licen[cs]e(?:\.|$)/i.test(name)) notices.push(`${path}\n${await readFile(`${path}/${name}`, 'utf8')}`);
    }
  }
}
await collect('node_modules');
await writeFile('../App/Editor/MarkdownEditor-LICENSES.txt', notices.join('\n\n----------------\n\n'));
