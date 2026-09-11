<img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon-mac-256.png" alt="Crow app icon" width="128" height="128">

# Crow

Mac, iPhone, iPad에서 로컬 폴더와 SSH 서버를 한곳에서 다루는 개발 작업 공간입니다.
터미널과 일반 텍스트 편집기를 함께 제공하며, Markdown·소스 코드·설정 파일을
빠르게 열고 편집할 수 있습니다.

## macOS 다운로드

### [최신 Crow DMG 다운로드](https://github.com/startedourmission/crow/releases/latest/download/Crow-macOS.dmg)

- 지원 운영체제: macOS 15 Sequoia 이상
- 지원 Mac: Apple Silicon 및 Intel
- 배포 파일은 Developer ID로 서명하고 Apple 공증을 거칩니다.

설치는 간단합니다.

1. 위 링크에서 `Crow-macOS.dmg`를 다운로드합니다.
2. DMG를 열고 `Crow.app`을 `Applications` 폴더로 드래그합니다.
3. 응용 프로그램 폴더에서 Crow를 실행합니다.

정상 배포본은 Apple 공증을 받은 파일이므로 Gatekeeper를 끄거나 터미널에서
격리 속성을 삭제할 필요가 없습니다.

아직 Release가 한 번도 게시되지 않았다면 최신 다운로드 링크가 404를 반환할
수 있습니다. 이 경우 [Releases](https://github.com/startedourmission/crow/releases)
페이지에서 배포 상태를 확인해 주세요.

## Homebrew로 설치

Crow 저장소를 처음 한 번만 tap으로 등록한 뒤 설치합니다.

```sh
brew trust --cask startedourmission/crow/crow
brew tap startedourmission/crow https://github.com/startedourmission/crow
brew install --cask crow
```

첫 번째 명령은 Homebrew 6의 비공식 tap 보호 정책에 따라 Crow Cask만 명시적으로
신뢰하는 단계입니다. 저장소 전체를 신뢰하지 않아도 됩니다.

Homebrew를 통한 수동 업그레이드는 다음과 같습니다.

```sh
brew upgrade --cask --greedy crow
```

## 자동 업데이트

Crow는 Sparkle의 서명된 업데이트 피드를 자동으로 확인합니다. 새 버전이 있으면
앱 안에서 안내하며, 언제든지 메뉴의 **Crow → Check for Updates…**를 선택해 직접
확인할 수 있습니다.

업데이트 파일도 최초 설치 파일과 마찬가지로 Developer ID 서명과 Apple 공증,
Sparkle EdDSA 서명 검증을 거칩니다.

## 주요 기능

- 로컬 폴더와 여러 SSH 호스트를 각각 독립된 작업 공간으로 관리
- macOS 실제 로그인 셸과 PTY 기반 터미널 탭·분할·크기 조절
- 한글 IME 조합 중 문자가 PTY로 잘못 전송되지 않는 터미널 입력 처리
- Markdown, txt, json, yaml, 소스 코드 등 UTF-8 일반 텍스트 편집
- 실행 취소, 찾기·바꾸기, 줄 번호, 들여쓰기, 글꼴 크기 조절
- 파일명·경로 검색과 `contents:` 접두사를 이용한 파일 내용 검색
- 파일·폴더 생성, 이름 변경, 가져오기 및 복구 가능한 삭제
- 작업 공간별 파일 탭, 터미널, 분할 화면, 임시 초안 복원
- 로컬 및 원격 Git 브랜치·변경 파일 확인
- SFTP 파일 탐색과 충돌 감지 저장
- macOS에서 기존 OpenSSH 설정, 에이전트, 키, `known_hosts` 사용
- 서버의 에이전트가 임시 SSH 경로를 통해 Mac에서 명령을 실행할 수 있는
  Reverse SSH 기능

## SSH 사용

Mac의 Crow 터미널에서 평소처럼 SSH 명령을 실행하면 됩니다.

```sh
ssh user@example.com
ssh user@example.com -p 2222
ssh my-config-alias
```

Crow는 시스템 OpenSSH 설정과 에이전트, 키를 그대로 사용합니다. 비밀번호,
키 암호, 호스트 확인 질문은 터미널 안에서 처리되며 Crow가 별도로 저장하지
않습니다. 연결이 완료되면 해당 서버가 작업 공간에 자동으로 추가됩니다.

원격 파일은 SFTP로 읽고 씁니다. 저장할 때 임시 파일과 백업·이름 변경 절차를
사용하고 외부 변경을 감지하지만, SFTP v3의 교체 작업 자체는 원자적이지 않아
동시에 같은 파일을 쓰는 다른 프로그램과 충돌할 수 있습니다.

## 데이터와 보안

macOS 버전은 로컬 셸과 일반 개발 명령을 실행해야 하므로 App Sandbox를 사용하지
않습니다. 신뢰할 수 있는 명령과 서버에만 연결하세요.

- 로컬 삭제 파일은 작업 공간 루트의 `.crow-trash`로 이동합니다.
- 원격 삭제 파일은 같은 서버의 숨김 `.crow-trash-…` 경로로 이동합니다.
- 저장하지 않은 초안과 세션 정보는 로컬 JSON 파일에 권한 `0600`으로 저장되며
  별도 암호화되지는 않습니다.
- SSH 개인키와 인증 정보는 macOS Keychain 및 시스템 OpenSSH가 관리합니다.
- 실행 중인 셸 프로세스와 SSH 연결은 앱 재시작 후 자동 복원되지 않습니다.

## 개발하기

필요한 도구는 전체 Xcode와 XcodeGen입니다. Xcode의 플랫폼 및 Metal Toolchain
컴포넌트도 설치되어 있어야 합니다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open Crow.xcodeproj
```

Xcode에서 `Crow-macOS` 또는 `Crow-iOS` 스킴을 선택합니다.

핵심 로직 테스트:

```sh
swift test --package-path Packages/CrowCore
```

macOS 앱과 터미널 통합 테스트:

```sh
bash scripts/test-macos-terminal.sh
xcodebuild test \
  -project Crow.xcodeproj \
  -scheme Crow-macOS \
  -destination 'platform=macOS,arch=arm64'
```

iOS 시뮬레이터 테스트:

```sh
xcodebuild test \
  -project Crow.xcodeproj \
  -scheme Crow-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

설치된 시뮬레이터 이름에 맞게 destination을 변경하세요. 실제 iPhone·iPad 빌드는
Apple 개발자 서명 팀이 필요합니다.

## 배포 관리

Developer ID 서명, Apple 공증, DMG 생성, Sparkle appcast와 Homebrew Cask 갱신
절차는 [배포 문서](docs/RELEASING.md)에 정리되어 있습니다.

터미널 렌더링에는 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), iOS 및
일부 SSH 연결에는 [Citadel](https://github.com/orlandos-nl/Citadel)을 사용합니다.
