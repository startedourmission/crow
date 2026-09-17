<p align="center">
  <img src="docs/assets/app-icon.svg" alt="Crow 앱 아이콘" width="96" height="96">
</p>

<h1 align="center">Crow</h1>

<p align="center">
  내 컴퓨터와 SSH 서버를 하나의 작업 공간으로.<br>
  Mac · iPhone · iPad에서 터미널, 파일 탐색, 편집기를 함께 사용하세요.
</p>

<p align="center">
  <a href="https://github.com/startedourmission/crow/releases/latest/download/Crow-macOS.dmg">macOS 다운로드</a> ·
  <a href="docs/USAGE.md">사용 안내</a> ·
  <a href="https://github.com/startedourmission/crow/releases">릴리스</a>
</p>

## 주요 기능

- 로컬·SSH 작업 공간, 파일·터미널 탭과 분할 화면
- Codex·Claude·Grok CLI 실행과 대화 기록, tmux 세션 관리
- Markdown·Canvas·Bases 편집, SFTP 파일 탐색과 Git 상태 확인
- SSH 터널을 통한 웹 미리보기와 VNC 서버 화면
- Mac의 Reverse SSH·Reverse Agent와 항상 위에 떠 있는 작은 작업 창
- iPhone·iPad용 키보드 바와 스니펫

에이전트는 실행할 기기에 해당 CLI 설치·로그인이 필요합니다. iPhone·iPad에서는 SSH 서버의 CLI를 사용합니다.

## 설치

**macOS 15 이상 · Apple Silicon 및 Intel**

[DMG 다운로드](https://github.com/startedourmission/crow/releases/latest/download/Crow-macOS.dmg) 후 Crow.app을 Applications 폴더로 옮기세요. Homebrew로도 설치할 수 있습니다.

```sh
brew trust --cask startedourmission/crow/crow
brew tap startedourmission/crow https://github.com/startedourmission/crow
brew install --cask crow
```

Homebrew로 업데이트:

```sh
brew update
brew upgrade --cask --greedy crow
```

앱의 **Crow → Check for Updates…**에서 업데이트합니다. iPhone·iPad는 iOS/iPadOS 18 이상이며 소스에서 빌드할 수 있습니다.

## 개발하기

전체 Xcode와 XcodeGen이 필요합니다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open Crow.xcodeproj
```

`Crow-macOS` 또는 `Crow-iOS` 스킴을 선택하세요.
[빌드·테스트 안내](docs/DEVELOPMENT.md) · [웹 편집기 개발](EditorWeb/README.md) · [macOS 배포](docs/RELEASING.md)

## 사용한 오픈소스

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · [Citadel](https://github.com/orlandos-nl/Citadel) · [Tiptap](https://github.com/ueberdosis/tiptap) · [Sparkle](https://github.com/sparkle-project/Sparkle)
