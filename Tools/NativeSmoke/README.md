# Native checks without taking over the desktop

Run `zsh Tools/run-native-smoke.sh` from the repository. This compiles the production
Markdown and window-movement components into a separate temporary app, without loading
the user's vault, session, SSH connections or preferences.

The app prohibits activation, keeps its windows outside screen bounds, and dispatches
events only to its own windows. It never posts CGEvents, warps the pointer, changes
input sources or activates Crow. The test also watches for accidental activation of
the smoke app; the user can freely switch between their own apps while it runs.

Coverage:

- actual NSWindow mouse-event dispatch and native window hit testing;
- native `performDrag(with:)` handoff and `isMovable` remaining enabled;
- local and multiplexed remote Git status, including quoted paths and shell-only SSH;
- exclusion of editor, button and file-list coordinates from window dragging;
- bundled WebKit editor initialization and several Markdown fixtures;
- direct rich-text edits, exact source preservation, undo/redo and save;
- native NSTextInputClient Korean marked-text composition and commit.
- code-block trailing-line rendering and exact fence preservation after editing;
- disposable loopback SSH servers offering different capabilities: standard SFTP,
  failed subsystem with working exec, failed exec with working bash/zsh shell input,
  a stalled subsystem, noisy startup banners, and rejection of every transport;
- multi-packet file read/write, listing, rename, conflict protection and close
  without interrupting another multiplexed session or resurrecting a closed channel.
  No user server is contacted; these emulate capabilities, not a Windows/WSL runtime.

Build output is retained in the printed `/tmp/crow-native-smoke.*` directory for diagnosis.

For the full production SwiftUI layout, first build `Crow-macOS`, then run:

```sh
zsh Tools/run-full-window-smoke.sh /path/to/Crow-DerivedData
```

This links the existing Debug app library into a separate activation-prohibited
fixture with a disposable vault. It tests native drag handoff from blank tab-bar
and sidebar space, tab/file/close-button/editor hit-test exclusions, resizing,
sidebar hide/show, and closing the last tab. It does not launch or restart the user's Crow.
It also clicks summary headings/functions in the right sidebar and checks the native
insertion caret, scrolling, rendered Markdown selection, and active-file switching.
Search checks cover prefix completion with a window-local Tab event, find-bar toggling,
the Match Case checkbox, case-sensitive/insensitive replacement, and Replace All undo.
They also verify the absence of find-bar X buttons, current/total match navigation,
manual-selection and replacement updates, and borderless find-button hover colors.
Hover checks dispatch window-local mouse-movement events through NSApp (without
moving the desktop pointer), compare rendered pixels for plain/filled/disabled
buttons, and require a clearly visible color change for explorer toolbar actions,
sidebar toggles, and summary headings. They also check that file/tab hover regions
do not intercept native input and the collapsed sidebar's reopen button is on the left.

Both fixtures override `performDrag(with:)` to record the request without entering
Window Server pointer tracking. They verify routing and that OS window movement is
enabled, not end-to-end physical dragging, snapping, or macOS keyboard shortcuts.
Those require a separate manual check; these tests never take over the user's cursor.
