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
View Only controls. The mobile keyboard controls stay available on iOS. The
Mac's Clipboard menu enables synchronization: local clipboard changes
are sent while the viewer is active, and incoming text updates the Mac clipboard
without echoing it back. Sync is off by default and pauses in View Only mode.
Text mode uses the server's VNC clipboard support (Unicode requires extended
clipboard support). Include Images uses an SSH command with macOS's built-in
AppKit scripting bridge for PNG/TIFF images and Unicode text in both directions.
It requires the SSH account to match the active Mac desktop user, installs no
remote files or services, and bounds images to 20 MB / 40 megapixels. Files are
not transferred. Command/Ctrl-V synchronizes the client clipboard before issuing
remote Paste; Copy copies the remote selection and retrieves the result. Apple
servers retain Command/Option mappings instead of noVNC's PC-oriented mapping.
Empty server cursors use noVNC's visible dot cursor fallback.

The build applies one checked patch to upstream `core/rfb.js`: when the server
offers both Apple account authentication and VNC password authentication, Crow
prefers the configured VNC password. Other security-type combinations retain
their original ordering, including account-only servers. The patch also records
Apple authentication support for keyboard mapping. This policy is only
used inside Crow's authenticated SSH tunnel. `build.mjs` contains the full patch
and rejects builds if its source anchor changes. The original source is available from the tag linked above
and from the `@novnc/novnc` npm archive pinned with integrity in
`package-lock.json`. The library is MPL-2.0, with BSD/MIT components; its license
texts and author list are included as `App/Screen/noVNC-*.txt` and copied into
the app bundle. The Crow HTML and bridge are separate from upstream sources.

`vnc-fixture.py` is a loopback-only protocol test double. It fragments a raw red
framebuffer, requests credentials, records keyboard/pointer events, and allows
reconnection. It advertises Apple account authentication before VNC password
authentication and checks the DES response for the fixed test password `fixture`.
The checks reject a wrong password before retrying with the correct one.
It is never included in the app or used as a real screen server. The integration
checks exercise the actual WKWebView and SSH transport on macOS (Citadel and
OpenSSH) and iOS (Citadel). Run iOS checks with the repository's
`scripts/test-ios-ssh.py SIMULATOR_UDID`; macOS checks are included in
`SSHIntegrationTests`.
