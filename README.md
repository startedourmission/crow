# Crow

SSH workspace for iPhone, iPad, and Mac. Terminal plus a plain-text editor.
Looks like VS Code, splits like Orca, without the agent IDE or the companion-app story.

- **Workspaces, not one blob.** Local vault is one workspace. Each SSH host opens another. Files and the terminal belong to the workspace you are in.
- **Editor is format-agnostic.** Markdown is first-class. txt, json, yaml, conf, and the rest open in the same editor.
- **Terminal IME is the product.** Marked Hangul never goes to the PTY. Only committed UTF-8 does.

## Open

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xed Crow.xcodeproj
```

Schemes: `Crow-iOS`, `Crow-macOS`.

```sh
swift test --package-path Packages/CrowCore
# macOS: build the app and test AppKit input against the SwiftTerm screen buffer
bash scripts/test-macos-terminal.sh
```

## Available now

- White theme with a dark navy accent; responsive Mac, iPad and iPhone layouts.
- Real macOS login shell (`zsh`) through a PTY, terminal tabs, resize, interrupt and terminal split. iOS uses SSH for real shells; IME Lab is intentionally an echo-only input test.
- Separate file tabs, drafts and terminal instances per workspace. Editor split is available on regular-width screens.
- Folder import, directory navigation, file/folder creation, rename and recoverable deletion. Local deletions move to the workspace root's hidden `.crow-trash`; remote deletions rename to a hidden `.crow-trash-…` sibling. The status message shows the recovery location.
- Native plain-text editing with undo, find/replace, line numbers, tab indentation and font settings. macOS also supports block indent/outdent and automatic newline indentation. UTF-8 files up to 16 MB are supported; binary files are rejected.
- Save/discard/cancel when closing dirty tabs, quit protection on Mac, external-edit conflict checks and explicit overwrite confirmation.
- SSH host management, password or OpenSSH Ed25519/RSA private-key authentication (including passphrases), host-key fingerprint approval and changed-key rejection. Credentials and trusted host keys are stored in the OS Keychain.
- SFTP browsing and editing. Saves upload to a temporary file first, check for conflicting changes, then replace using backup/rename with rollback. SFTP v3 replacement is not atomic; a concurrent server writer can still race a save.
- Session restoration for workspaces, tabs, unsaved drafts, splits and preferences. Drafts are stored locally in the session JSON (mode `0600`), not encrypted by Crow. Running shell processes and SSH connections are not restored; reconnect starts a new shell. On iOS, backgrounding persists drafts and foregrounding checks connection state; this does not keep SSH alive indefinitely in the background.

The macOS target is intentionally **not App Sandbox-enabled** so the local shell can run normal developer commands. Only run commands and connect to servers you trust.

## Test and run

In Xcode choose `Crow-macOS` → **My Mac** → Run, or `Crow-iOS` → an installed iPhone/iPad simulator → Run. A full Xcode installation and its platform/Metal components are required. Device builds also require your signing team.

```sh
swift test --package-path Packages/CrowCore
xcodebuild test -project Crow.xcodeproj -scheme Crow-macOS -destination 'platform=macOS,arch=arm64'
xcodebuild test -project Crow.xcodeproj -scheme Crow-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild test -project Crow.xcodeproj -scheme Crow-iOS -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
```

Use a simulator name installed on your machine. The macOS integration suite starts an isolated loopback-only `sshd` with temporary keys; it does not enable Remote Login or change system SSH configuration. It exercises host-key approval/rejection, SFTP round trips/conflicts, real shell input, Hangul commit/backspace, resizing and interrupts.

Verified on this development Mac and iPhone/iPad simulators. Physical-device touch keyboards, external Korean keyboards, real-network interruptions and long background periods still require device testing. This is a plain-text workspace, not an LSP/debugger/Git GUI.

Terminal rendering uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm); SSH/SFTP uses [Citadel](https://github.com/orlandos-nl/Citadel).
