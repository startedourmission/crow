import {build} from 'esbuild';
import {writeFile} from 'node:fs/promises';
const result = await build({entryPoints: ['screen.js'], bundle: true, minify: true,
    format: 'esm', target: 'safari17', legalComments: 'eof', write: false});
// noVNC probes WebCodecs with top-level await. An async wrapper lets the single
// bundled asset run from WKWebView's local file without module-origin requests.
await writeFile('../../App/Screen/screen-client.js', '(async()=>{\n' + result.outputFiles[0].text +
    '\n})().catch(error=>window.webkit.messageHandlers.screen.postMessage({action:"loaderror",message:String(error)}));\n');
