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
- macOS right sidebar with Summary and Git views. Summary follows the active file's unsaved text; Markdown headings and Swift, Python, JavaScript/TypeScript, Go, Rust, C/C++, Ruby and shell declarations jump to the insertion caret, including inside rendered Markdown. Code recognition is lexical, not an LSP/compiler symbol index. Toggle the sidebar from the pane header (bottom-right when no tabs are open) or Option-Command-B; drag its left edge to resize.
- Git shows the branch and saved-file index/worktree changes, with file opening and automatic refresh while visible. Local Git and existing terminal SSH connections are supported; remote Git requires Git and a POSIX login shell. It does not stage, commit, fetch or change server configuration.
- macOS shortcuts: Command-plus/minus changes the focused editor/terminal font (Command-equals also enlarges), Command-F searches the active document, Command-Shift-F focuses the existing file search without rewriting its query, Command-comma opens settings, and Command-1…9 selects a tab within the focused pane.
- Explorer search matches names/paths by default. Prefix with `contents:` for literal, case-insensitive text search through local or SSH files; open buffers use their current unsaved text. Results show the first matching line. Binary/unreadable files and files over 2 MB are skipped; content scans are capped at 2,000 files / 32 MB, with visible limit notices. Press Return to refresh; background content refresh is throttled to 15 seconds.
- Explorer search includes a Name/Contents dropdown that preserves the search term, plus clickable/Tab completion for `contents:`. The document search icon toggles its bar; Command-F always opens/focuses it. macOS find/replace has an explicit Match Case checkbox, previous/next matches, Replace and All, with undo. Queries are literal; above 10,000 matches the bar asks for a narrower query before allowing Replace All.
- Save/discard/cancel when closing dirty tabs, quit protection on Mac, external-edit conflict checks and explicit overwrite confirmation.
- SSH without a setup form: on Mac, run `ssh user@host -p 2222` or `ssh config-alias` in Crow's local terminal. After successful authentication a workspace is added automatically, without stealing terminal focus. The + menu also accepts a single SSH command. Mac uses your actual OpenSSH config, agent, keys and known_hosts; any password, passphrase or host verification prompt stays in the terminal. iOS accepts a command and asks for a password only when needed; private-key import remains under Advanced settings and credentials use Keychain.
- SFTP browsing and editing. Saves upload to a temporary file first, check for conflicting changes, then replace using backup/rename with rollback. SFTP v3 replacement is not atomic; a concurrent server writer can still race a save.
- Session restoration for workspaces, tabs, unsaved drafts, splits and preferences. Drafts are stored locally in the session JSON (mode `0600`), not encrypted by Crow. Running shell processes and SSH connections are not restored; reconnect starts a new shell. On iOS, backgrounding persists drafts and foregrounding checks connection state; this does not keep SSH alive indefinitely in the background.

The macOS target is intentionally **not App Sandbox-enabled** so the local shell can run normal developer commands. Only run commands and connect to servers you trust.

### Terminal SSH integration

New Crow local terminals load a private zsh `ssh` function; your shell configuration files are not modified. It invokes `/usr/bin/ssh` and uses a private [OpenSSH multiplex connection](https://man.openbsd.org/ssh_config#ControlMaster) so file operations and additional terminal tabs need no second login. SFTP is spoken directly over that channel, following the [SFTP v3 wire format](https://www.ietf.org/archive/id/draft-ietf-secsh-filexfer-02.txt), not by parsing shell output.

Mac file connections negotiate capabilities in order: the standard SFTP subsystem,
an installed `sftp-server` started through an SSH command, then the same bootstrap
sent through a plain SSH shell channel without a remote command. This handles login
wrappers where interactive login works but command execution does not, without
hard-coding hostnames, operating systems or distribution names. Fallbacks require a
POSIX-compatible login shell and an executable `sftp-server` on PATH or in a standard
OpenSSH location. Crow does not install packages or edit remote SSH/shell settings.
Each handshake has an 8-second deadline; startup banners are bounded and discarded
before the binary protocol starts. Only connection setup is retried, never file writes.
If every method fails, the error includes each attempted method and leaves the
terminal connection open. The selected login environment's default distribution
is used; Crow does not choose or switch WSL distributions.

New Mac SSH workspaces start at the file channel's initial working directory (`.`),
without forcing the SFTP process into `$HOME`. This preserves the SSH login's
starting directory in the shell fallbacks. Once selected, the project folder is
saved and survives reconnects. Later terminal `cd` commands do not move the file
browser. Explicit Home navigation uses the server's home-expansion extension when
available; no continuous directory synchronization or shell-profile injection is used.

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
