import {build} from 'esbuild';
import {readFile, writeFile} from 'node:fs/promises';
const result = await build({entryPoints: ['screen.js'], bundle: true, minify: true,
    format: 'esm', target: 'safari17', legalComments: 'eof', write: false,
    plugins: [{name: 'crow-mac-vnc-auth', setup(build) {
        build.onLoad({filter: /@novnc\/novnc\/core\/rfb\.js$/}, async ({path}) => {
            const source = await readFile(path, 'utf8');
            const original = 'const types = this._sock.rQshiftBytes(numTypes);';
            if (source.split(original).length !== 2) throw new Error('Review the noVNC authentication patch for this version');
            // Crow only connects through authenticated SSH. When a Mac offers both
            // account login and its separately configured VNC password, prefer the
            // latter. Keep server ordering unchanged for every other combination.
            const patched = `const types = Array.from(this._sock.rQshiftBytes(numTypes));
            this._crowAppleServer = types.includes(securityTypeARD);
            if (types.includes(securityTypeARD) && types.includes(securityTypeVNCAuth)) {
                types.splice(types.indexOf(securityTypeVNCAuth), 1);
                types.unshift(securityTypeVNCAuth);
            }`;
            return {contents: source.replace(original, patched), loader: 'js'};
        });
    }}]});
// noVNC probes WebCodecs with top-level await. An async wrapper lets the single
// bundled asset run from WKWebView's local file without module-origin requests.
await writeFile('../../App/Screen/screen-client.js', '// Crow modification: prefer VNC password when Apple account authentication is also offered; see Tools/ScreenClient/build.mjs.\n(async()=>{\n' + result.outputFiles[0].text +
    '\n})().catch(error=>window.webkit.messageHandlers.screen.postMessage({action:"loaderror",message:String(error)}));\n');
