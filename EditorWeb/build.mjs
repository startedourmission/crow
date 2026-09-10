import { build } from 'esbuild';
import { readdir, readFile, writeFile } from 'node:fs/promises';
await build({ entryPoints: ['editor.js'], bundle: true, format: 'iife', target: 'safari18',
  minify: true, outfile: '../App/Editor/markdown-editor.js', legalComments: 'eof' });
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
