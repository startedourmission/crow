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
- Real macOS login shell (`zsh`) through a PTY, terminal tabs, resize, interrupt and terminal split. iOS uses SSH for real shells. Input regression fixtures run only in tests; there is no IME Lab workspace in the app.
- Separate file tabs, drafts and terminal instances per workspace. Editor split is available on regular-width screens.
- Folder import, directory navigation, file/folder creation, rename and recoverable deletion. Local deletions move to the workspace root's hidden `.crow-trash`; remote deletions rename to a hidden `.crow-trash-…` sibling. The status message shows the recovery location.
- Native plain-text editing with undo, find/replace, line numbers, tab indentation and font settings. macOS also supports block indent/outdent and automatic newline indentation. UTF-8 files up to 16 MB are supported; binary files are rejected.
- Save/discard/cancel when closing dirty tabs, quit protection on Mac, external-edit conflict checks and explicit overwrite confirmation.
- SSH without a setup form: on Mac, run `ssh user@host -p 2222` or `ssh config-alias` in Crow's local terminal. After successful authentication a workspace is added automatically, without stealing terminal focus. The + menu also accepts a single SSH command. Mac uses your actual OpenSSH config, agent, keys and known_hosts; any password, passphrase or host verification prompt stays in the terminal. iOS accepts a command and asks for a password only when needed; private-key import remains under Advanced settings and credentials use Keychain.
- SFTP browsing and editing. Saves upload to a temporary file first, check for conflicting changes, then replace using backup/rename with rollback. SFTP v3 replacement is not atomic; a concurrent server writer can still race a save.
- Session restoration for workspaces, tabs, unsaved drafts, splits and preferences. Drafts are stored locally in the session JSON (mode `0600`), not encrypted by Crow. Running shell processes and SSH connections are not restored; reconnect starts a new shell. On iOS, backgrounding persists drafts and foregrounding checks connection state; this does not keep SSH alive indefinitely in the background.

The macOS target is intentionally **not App Sandbox-enabled** so the local shell can run normal developer commands. Only run commands and connect to servers you trust.

### Terminal SSH integration

New Crow local terminals load a private zsh `ssh` function; your shell configuration files are not modified. It invokes `/usr/bin/ssh` and uses a private [OpenSSH multiplex connection](https://man.openbsd.org/ssh_config#ControlMaster) so file operations and additional terminal tabs need no second login. SFTP is spoken directly over that channel, following the [SFTP v3 wire format](https://www.ietf.org/archive/id/draft-ietf-secsh-filexfer-02.txt), not by parsing shell output.

Restart the app or open a new terminal after updating to activate integration. `command ssh`, `/usr/bin/ssh`, custom overrides of the `ssh` function, tunnel-only/remote-command sessions and explicit multiplex-control commands remain terminal-only. Automatic registration is for interactive connections from Crow's Mac local terminal, not Terminal.app or remote shells. The command box is a single SSH command parser, not a shell: pipelines, substitutions and shell operators are rejected. Config aliases and agent access are Mac-only.

Disconnecting a workspace closes its UI channels; an SSH command still running in the original local terminal is independent (use `exit` there). Crow-owned master connections use a 60-second idle persistence and are closed on normal app shutdown. Running SSH processes are never restored after restart; the saved command can be used to reconnect. Connection arguments/paths are stored locally with the session, so do not embed passwords or other secrets in command arguments.

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

Terminal rendering uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm); iOS and legacy saved connections use [Citadel](https://github.com/orlandos-nl/Citadel). New Mac command connections use the system OpenSSH client.
