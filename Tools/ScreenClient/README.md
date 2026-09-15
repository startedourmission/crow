# Crow screen client

Crow bundles [noVNC 1.7.0](https://github.com/novnc/noVNC/tree/v1.7.0) in
`App/Screen/screen-client.js`. `screen.js` provides a WebSocket-shaped native
message bridge; no websockify service, external web page, or listening port is
needed on the client. The native transport opens an SSH `direct-tcpip` channel
to `127.0.0.1:<VNC port>` on the SSH server. OpenSSH connections on macOS use
`ssh -W` over the existing control socket instead.

Rebuild with Node.js and npm:

```sh
cd Tools/ScreenClient
npm ci --ignore-scripts
npm run build
```

Commit the generated JS when changing the source or dependencies. Xcode builds
use this checked-in bundle and do not invoke npm or download browser code.
The async wrapper supports noVNC's top-level H.264 capability probe in a local
WKWebView script. Screen data and input are bounded and tagged per session so
closing or reconnecting cannot deliver old input to a new connection.

On macOS the viewer opens in a separate, resizable window with native Fit and
View Only controls. On iOS, Keyboard opens a live input field; committed text
is sent immediately, including IME composition, and Done dismisses it. Special
keys scroll independently so Keyboard and View Only remain visible. Touch gestures
and hardware keys use noVNC's canvas handlers, with native WebKit touch handling
enabled and browser panning disabled only over the remote screen.
The native screen toolbar shows Connect/Disconnect beside its controls menu.
The title identifies the SSH account and host rather than replacing them with the
server's computer name. Screen Login defaults to Workspace account: on Apple
servers Crow chooses ARD account authentication and fixes the login name to the
selected workspace's SSH account. Enter that account's Mac login password;
SSH keys cannot substitute for a screen-sharing account password.
Shared desktop (VNC password) is an explicit alternative in the controls menu.
It authenticates the shared desktop, not the selected account. Ordinary non-Apple
VNC servers continue using their supported authentication methods.

On Mac, Sync Clipboard and Include Images are enabled by default. Sync pauses in
View Only mode. Local clipboard changes are sent while the viewer is active, and
incoming text updates the Mac clipboard without echoing it back.
The SSH/AppKit clipboard bridge is used only after Mac account authentication
with the same username as the current SSH connection. It transfers text and
PNG/TIFF images (20 MB / 40 megapixels), preserves both representations, and
installs no remote files or services. Shared-desktop connections and different
screen/SSH accounts use VNC text clipboard support; they never access the SSH
account's pasteboard. Unicode requires extended VNC clipboard support.
If the native helper fails, VNC text synchronization continues and the helper error
is shown with a Retry action. Image-only paste is suppressed when image transfer
is unavailable, so it cannot paste unrelated server clipboard contents.
Command/Ctrl-V synchronizes the client clipboard before issuing
remote Paste; Copy copies the remote selection and retrieves the result. Apple
servers retain Command/Option mappings instead of noVNC's PC-oriented mapping.
Empty server cursors use noVNC's visible dot cursor fallback.

The build applies one checked patch to upstream `core/rfb.js`: Apple account
authentication is preferred in workspace-account mode, while the shared VNC
password is selected only in explicit shared-desktop mode. Unsupported Apple
account methods fail without falling back to a shared desktop. Apple server
capabilities are also retained for keyboard mapping. `build.mjs` checks its source
anchor before applying the patch. The original source is available from the tag linked above
and from the `@novnc/novnc` npm archive pinned with integrity in
`package-lock.json`. The library is MPL-2.0, with BSD/MIT components; its license
texts and author list are included as `App/Screen/noVNC-*.txt` and copied into
the app bundle. The Crow HTML and bridge are separate from upstream sources.

`vnc-fixture.py` is a loopback-only protocol test double. It fragments a raw red
framebuffer, requests credentials, records keyboard/pointer events, and allows
reconnection. It offers VNC password before ARD account authentication and verifies
the chosen method. ARD credentials are independently decrypted using DH/MD5/AES;
only the fixture's two test accounts and the password `fixture` are accepted.
Additional modes exercise account-only, plain VNC, and unsupported Apple account
servers. Checks reject incorrect passwords and cross-account login overrides,
verify explicit shared-desktop mode, and ensure a mismatched screen account does
not touch the SSH account's named test pasteboard.
These protocol fixtures do not establish how a particular macOS server chooses a
GUI session when other users are logged in; that requires a real multiuser Mac check.
It is never included in the app or used as a real screen server. The integration
checks exercise the actual WKWebView and SSH transport on macOS (Citadel and
OpenSSH) and iOS (Citadel), including synthetic DOM touch gestures, hardware key
events, live input and IME commits. These checks do not synthesize UIKit touches
or test a physical iPad keyboard. Run iOS checks with the repository's
`scripts/test-ios-ssh.py SIMULATOR_UDID`; macOS checks are included in
`SSHIntegrationTests`.
