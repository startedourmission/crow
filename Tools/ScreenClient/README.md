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

The upstream source is unmodified. It is available from the tag linked above
and from the `@novnc/novnc` npm archive pinned with integrity in
`package-lock.json`. The library is MPL-2.0, with BSD/MIT components; its license
texts and author list are included as `App/Screen/noVNC-*.txt` and copied into
the app bundle. The Crow HTML and bridge are separate from upstream sources.

`vnc-fixture.py` is a loopback-only protocol test double. It fragments a raw red
framebuffer, requests credentials, records keyboard/pointer events, and allows
reconnection. Its authentication deliberately accepts any 16-byte response;
it is never included in the app or used as a real screen server. The integration
checks exercise the actual WKWebView and SSH transport on macOS (Citadel and
OpenSSH) and iOS (Citadel). Run iOS checks with the repository's
`scripts/test-ios-ssh.py SIMULATOR_UDID`; macOS checks are included in
`SSHIntegrationTests`.
