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
```

SSH transport is the next slice. IME Lab is an echo terminal so Hangul can be verified on device first.
