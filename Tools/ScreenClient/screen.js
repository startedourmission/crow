import RFB from '@novnc/novnc';

let sessionID = '';
const post = (action, extra = {}, session = sessionID) => window.webkit.messageHandlers.screen.postMessage({action, session, ...extra});
let rfb, channel;
class SSHChannel {
    constructor(id) {
        this.id = id;
        this.readyState = 1; this.binaryType = 'arraybuffer'; this.protocol = '';
        this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
        this.pending = []; this.queued = false;
    }
    send(data) {
        if (this.readyState !== 1) return;
        this.pending.push(new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength).slice());
        if (this.queued) return;
        this.queued = true;
        queueMicrotask(() => {
            this.queued = false;
            const length = this.pending.reduce((n, a) => n + a.length, 0);
            if (length > 1024 * 1024) { post('error', {message: 'Screen input queue is too large.'}, this.id); this.close(); return; }
            const bytes = new Uint8Array(length); let offset = 0;
            for (const chunk of this.pending) { bytes.set(chunk, offset); offset += chunk.length; }
            this.pending = [];
            // Batch keys and their releases into the same SSH write.
            let text = '';
            for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192));
            if (this.readyState === 1 && text) post('send', {data: btoa(text)}, this.id);
        });
    }
    close() {
        if (this.readyState === 3) return;
        this.readyState = 3; this.pending = [];
        this.onclose?.({clean: true});
    }
}

window.crowScreen = {
    start(id) {
        rfb?.disconnect();
        sessionID = id;
        const report = (action, extra) => post(action, extra, id);
        channel = new SSHChannel(id);
        rfb = new RFB(document.getElementById('display'), channel, {shared: true});
        rfb.scaleViewport = true; rfb.resizeSession = false;
        document.getElementById('view-only').checked = false;
        document.getElementById('fit').checked = true;
        rfb.compressionLevel = 6; rfb.qualityLevel = 6;
        rfb.addEventListener('connect', () => { report('connected'); rfb.focus(); });
        rfb.addEventListener('disconnect', e => report('disconnected', {clean: e.detail.clean}));
        rfb.addEventListener('securityfailure', e => report('error', {message: e.detail.reason || 'Screen authentication failed.'}));
        rfb.addEventListener('credentialsrequired', e => report('credentials', {types: e.detail.types}));
        rfb.addEventListener('desktopname', e => report('name', {name: e.detail.name}));
    },
    receive(base64, id) {
        if (sessionID !== id || channel?.readyState !== 1) return;
        const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
        channel.onmessage?.({data: bytes.buffer});
    },
    credentials(username, password, id) { if (sessionID === id) rfb?.sendCredentials({username, password}); },
    stop(id) { if (sessionID === id) { rfb?.disconnect(); channel?.close(); } },
};

document.querySelectorAll('[data-key]').forEach(button => {
    button.addEventListener('click', () => { rfb?.sendKey(Number(button.dataset.key)); rfb?.focus(); });
});
document.getElementById('secure-attention').onclick = () => rfb?.sendCtrlAltDel();
document.getElementById('view-only').onchange = e => { if (rfb) rfb.viewOnly = e.target.checked; };
document.getElementById('fit').onchange = e => {
    if (!rfb) return;
    rfb.scaleViewport = e.target.checked; rfb.clipViewport = !e.target.checked;
    rfb.dragViewport = !e.target.checked;
};
document.getElementById('type').onclick = () => {
    const input = document.getElementById('text');
    for (const character of input.value) {
        const code = character.codePointAt(0);
        rfb?.sendKey(code <= 255 ? code : 0x01000000 | code);
    }
    input.value = ''; input.blur(); rfb?.focus();
};
window.addEventListener('error', e => post('error', {message: e.message || 'Screen viewer failed.'}));
window.addEventListener('unhandledrejection', e => post('error', {message: String(e.reason)}));
post('ready');
