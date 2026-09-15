import {build} from 'esbuild';
import {readFile, writeFile} from 'node:fs/promises';
const result = await build({entryPoints: ['screen.js'], bundle: true, minify: true,
    format: 'esm', target: 'safari17', legalComments: 'eof', write: false,
    plugins: [{name: 'crow-mac-vnc-auth', setup(build) {
        build.onLoad({filter: /@novnc\/novnc\/core\/rfb\.js$/}, async ({path}) => {
            const source = await readFile(path, 'utf8');
            const original = 'const types = this._sock.rQshiftBytes(numTypes);';
            if (source.split(original).length !== 2) throw new Error('Review the noVNC authentication patch for this version');
            // Account selection must not silently downgrade to a shared VNC password.
            // Other servers retain their own authentication ordering.
            const patched = `const types = Array.from(this._sock.rQshiftBytes(numTypes));
            this._crowAppleServer = types.some(type => [30, 33, 35, 36].includes(type));
            if (this._crowAppleServer) {
                const preferred = this._crowAccountMode === false ? securityTypeVNCAuth : securityTypeARD;
                if (!types.includes(preferred)) {
                    const reason = this._crowAccountMode === false
                        ? 'This Mac does not offer shared VNC password access.'
                        : 'This Mac does not offer account authentication supported by this viewer. No shared desktop was opened.';
                    this.dispatchEvent(new CustomEvent('securityfailure', {detail: {reason}}));
                    return this._fail(reason);
                }
                types.splice(types.indexOf(preferred), 1);
                types.unshift(preferred);
            }`;
            return {contents: source.replace(original, patched), loader: 'js'};
        });
    }}]});
// noVNC probes WebCodecs with top-level await. An async wrapper lets the single
// bundled asset run from WKWebView's local file without module-origin requests.
await writeFile('../../App/Screen/screen-client.js', '// Crow modification: select Mac account or explicit shared-desktop authentication; see Tools/ScreenClient/build.mjs.\n(async()=>{\n' + result.outputFiles[0].text +
    '\n})().catch(error=>window.webkit.messageHandlers.screen.postMessage({action:"loaderror",message:String(error)}));\n');
