import RFB from '@novnc/novnc';

let sessionID = '';
const post = (action, extra = {}, session = sessionID) => window.webkit.messageHandlers.screen.postMessage({action, session, ...extra});
let rfb, channel;
let viewOnly = false, fit = true;
let clipboardEnabled = false;
let vncClipboardEnabled = false;
let heldModifiers = {};
const swallowedKeys = new Set();
const modifierKeys = [['ctrl', 65507, 'ControlLeft'], ['meta', 65515, 'MetaLeft'], ['alt', 65513, 'AltLeft'], ['shift', 65505, 'ShiftLeft']];
class CrowRFB extends RFB {
    _handleKeyEvent(keysym, code, down, ...rest) {
        // noVNC normally maps a Mac client's left Command key to Alt for PC servers.
        // Preserve Command/Option when the server advertises Apple authentication.
        if (this._crowAppleServer) {
            const keys = {MetaLeft: 65515, MetaRight: 65516, AltLeft: 65513, AltRight: 65514};
            keysym = keys[code] ?? keysym;
        }
        super._handleKeyEvent(keysym, code, down, ...rest);
    }
}
function sendShortcut(keysym, code, modifiers) {
    if (!rfb || viewOnly) return;
    const desired = {...modifiers};
    if (rfb._crowAppleServer && desired.ctrl && !desired.meta) { desired.ctrl = false; desired.meta = true; }
    for (const [name, key, code] of modifierKeys) rfb.sendKey(key, code, false);
    for (const [name, key, code] of modifierKeys) if (desired[name]) rfb.sendKey(key, code, true);
    rfb.sendKey(keysym, code, true); rfb.sendKey(keysym, code, false);
    for (const [name, key, code] of modifierKeys) rfb.sendKey(key, code, !!heldModifiers[name]);
}
for (const type of ['keydown', 'keyup']) document.addEventListener(type, event => {
    heldModifiers = {ctrl: event.ctrlKey, meta: event.metaKey, alt: event.altKey, shift: event.shiftKey};
    if (type === 'keyup' && swallowedKeys.delete(event.code)) {
        event.preventDefault(); event.stopImmediatePropagation(); return;
    }
    if (type !== 'keydown' || !clipboardEnabled || viewOnly ||
        !document.getElementById('display').contains(event.target) || !(event.ctrlKey || event.metaKey) ||
        event.altKey || event.shiftKey || !['KeyC', 'KeyV'].includes(event.code)) return;
    event.preventDefault(); event.stopImmediatePropagation(); swallowedKeys.add(event.code);
    if (event.repeat) return;
    if (event.code === 'KeyV') post('paste', {modifiers: heldModifiers});
    else { sendShortcut(99, 'KeyC', heldModifiers); post('copy'); }
}, true);
window.addEventListener('blur', () => { heldModifiers = {}; swallowedKeys.clear(); });
function applyOptions() {
    document.getElementById('view-only').checked = viewOnly;
    document.getElementById('fit').checked = fit;
    if (!rfb) return;
    rfb.viewOnly = viewOnly;
    rfb.scaleViewport = fit; rfb.clipViewport = !fit; rfb.dragViewport = !fit;
    document.getElementById('keyboard').disabled = viewOnly;
    document.getElementById('text').disabled = viewOnly;
}
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
    configure(readOnly, fitToWindow, desktop, clipboard = false, vncClipboard = clipboard) {
        viewOnly = readOnly; fit = fitToWindow;
        clipboardEnabled = clipboard;
        vncClipboardEnabled = vncClipboard;
        document.body.classList.toggle('desktop', desktop);
        applyOptions();
    },
    start(id) {
        rfb?.disconnect();
        resetTyping();
        sessionID = id;
        const report = (action, extra) => post(action, extra, id);
        channel = new SSHChannel(id);
        rfb = new CrowRFB(document.getElementById('display'), channel, {shared: true});
        rfb.resizeSession = false;
        rfb.showDotCursor = true;
        applyOptions();
        rfb.compressionLevel = 6; rfb.qualityLevel = 6;
        rfb.addEventListener('connect', () => { report('connected', {appleServer: !!rfb._crowAppleServer}); rfb.focus(); });
        rfb.addEventListener('disconnect', e => report('disconnected', {clean: e.detail.clean}));
        rfb.addEventListener('securityfailure', e => report('error', {message: e.detail.reason || 'Screen authentication failed.'}));
        rfb.addEventListener('credentialsrequired', e => report('credentials', {types: e.detail.types}));
        rfb.addEventListener('desktopname', e => report('name', {name: e.detail.name}));
        rfb.addEventListener('clipboard', e => {
            if (vncClipboardEnabled && !viewOnly && e.detail.text.length <= 1_000_000) report('clipboard', {text: e.detail.text});
        });
    },
    receive(base64, id) {
        if (sessionID !== id || channel?.readyState !== 1) return;
        const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
        channel.onmessage?.({data: bytes.buffer});
    },
    credentials(username, password, id) { if (sessionID === id) rfb?.sendCredentials({username, password}); },
    clipboard(text, id) {
        if (sessionID === id && vncClipboardEnabled && !viewOnly) rfb?.clipboardPasteFrom(text);
    },
    finishPaste(modifiers, id) {
        if (sessionID === id && clipboardEnabled && !viewOnly) sendShortcut(118, 'KeyV', modifiers);
    },
    nativeShortcut(key, id) {
        if (sessionID !== id || !clipboardEnabled || viewOnly) return;
        if (key === 'v') post('paste', {modifiers: {meta:true}});
        else if (key === 'c') { sendShortcut(99, 'KeyC', {meta:true}); post('copy'); }
    },
    stop(id) { if (sessionID === id) { rfb?.disconnect(); channel?.close(); } },
};

const input = document.getElementById('text');
let typed = '', composing = false;
const forwardedKeys = new Set();
function resetTyping() { typed = ''; input.value = ''; composing = false; forwardedKeys.clear(); }
function sendText(text) {
    for (const character of text) {
        const code = character.codePointAt(0);
        rfb?.sendKey(code === 10 ? 65293 : code <= 255 ? code : 0x01000000 | code);
    }
}
function flushTyping() {
    if (composing || !rfb || viewOnly) return;
    // Compare committed text so IME composition, replacement and deletion don't
    // send partial syllables or duplicate the final composition input event.
    const before = Array.from(typed), after = Array.from(input.value);
    let prefix = 0;
    while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix++;
    for (let i = prefix; i < before.length; i++) rfb.sendKey(65288);
    sendText(after.slice(prefix).join(''));
    typed = input.value;
}
input.addEventListener('compositionstart', () => { composing = true; });
input.addEventListener('compositionend', () => { composing = false; flushTyping(); });
input.addEventListener('input', event => { if (!event.isComposing) flushTyping(); });
input.addEventListener('beforeinput', event => {
    if (!composing && event.inputType === 'deleteContentBackward' && input.value === '') {
        event.preventDefault(); if (!viewOnly) rfb?.sendKey(65288);
    }
});
for (const type of ['keydown', 'keyup']) input.addEventListener(type, event => {
    if (composing || event.isComposing || event.keyCode === 229) return;
    const special = /^(Enter|Tab|Escape|ArrowLeft|ArrowRight|ArrowUp|ArrowDown|Home|End|PageUp|PageDown|Delete|Control|Alt|Meta|Shift|F\d{1,2})$/.test(event.key);
    if (!special && !(event.ctrlKey || event.metaKey || event.altKey) && !forwardedKeys.has(event.code)) return;
    // Text comes through input/composition events; hardware shortcuts and
    // navigation keys still use noVNC's normal key-down/key-up tracking.
    event.preventDefault(); event.stopPropagation();
    if (type === 'keydown') forwardedKeys.add(event.code); else forwardedKeys.delete(event.code);
    document.querySelector('#display canvas')?.dispatchEvent(new KeyboardEvent(type, event));
});
input.addEventListener('blur', () => {
    // Releasing focus must not leave a modifier held on the remote desktop.
    const canvas = document.querySelector('#display canvas');
    for (const code of forwardedKeys) canvas?.dispatchEvent(new KeyboardEvent('keyup', {code}));
    forwardedKeys.clear();
});
document.getElementById('keyboard').onclick = () => {
    const row = document.getElementById('typing');
    row.hidden = !row.hidden;
    document.getElementById('keyboard').setAttribute('aria-expanded', String(!row.hidden));
    if (row.hidden) { input.blur(); rfb?.focus(); }
    else input.focus(); // Within the tap event so iOS can open the software keyboard.
};
document.querySelectorAll('[data-key]').forEach(button => {
    // Keep an open software keyboard while tapping the special-key row.
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => {
        rfb?.sendKey(Number(button.dataset.key));
        if (!document.getElementById('typing').hidden) input.focus(); else rfb?.focus();
    });
});
document.getElementById('secure-attention').onclick = () => rfb?.sendCtrlAltDel();
document.getElementById('view-only').onchange = e => { viewOnly = e.target.checked; applyOptions(); };
document.getElementById('fit').onchange = e => {
    fit = e.target.checked; applyOptions();
};
document.getElementById('type').onclick = () => {
    flushTyping(); resetTyping(); input.blur();
    document.getElementById('typing').hidden = true;
    document.getElementById('keyboard').setAttribute('aria-expanded', 'false');
    rfb?.focus();
};
window.addEventListener('error', e => post('error', {message: e.message || 'Screen viewer failed.'}));
window.addEventListener('unhandledrejection', e => post('error', {message: String(e.reason)}));
post('ready');
