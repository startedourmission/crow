# Crow 개발·테스트

[프로젝트 소개](../README.md) · [사용 안내](USAGE.md)

필요한 도구는 전체 Xcode와 XcodeGen입니다. Xcode의 플랫폼 및 Metal Toolchain
컴포넌트도 설치되어 있어야 합니다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open Crow.xcodeproj
```

Xcode에서 `Crow-macOS` 또는 `Crow-iOS` 스킴을 선택합니다.

## 테스트 실행

핵심 로직 테스트:

```sh
swift test --package-path Packages/CrowCore
```

macOS 앱과 터미널 통합 테스트:

테스트 빌드는 별도 DerivedData 경로를 사용합니다. 실행 중인 개발용 Crow를
덮어쓰면 코드 서명 불일치로 키체인 접근이 거부될 수 있습니다.

```sh
bash scripts/test-macos-terminal.sh
xcodebuild test \
  -project Crow.xcodeproj \
  -scheme Crow-macOS \
  -derivedDataPath "${TMPDIR:-/tmp}/crow-macos-tests-${UID}" \
  -destination 'platform=macOS,arch=arm64'
```

iOS 시뮬레이터 테스트:

```sh
xcodebuild test \
  -project Crow.xcodeproj \
  -scheme Crow-iOS \
  -derivedDataPath "${TMPDIR:-/tmp}/crow-ios-tests-${UID}" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

설치된 시뮬레이터 이름에 맞게 destination을 변경하세요. 실제 iPhone·iPad 빌드는
Apple 개발자 서명 팀이 필요합니다.

JavaScript·Python 테스트 (Linux에서도 실행 가능, Node 22+):

```sh
(cd EditorWeb && npm ci --ignore-scripts && npm run build && npm test)
(cd Tools/ScreenClient && npm ci --ignore-scripts && npm run build)
git diff --exit-code -- App/Editor App/Screen   # 커밋된 번들이 빌드 결과와 같은지 확인
python3 -m unittest Tools/Agents/test_history.py
```

`Tools/Agents/test_history.py`의 reverse shell 테스트는 `/bin/zsh`가 없으면 건너뜁니다.

CI(`.github/workflows/ci.yml`)는 pull request, `main`·`ci/**` 푸시, 수동 실행 시 위
JS·Python 테스트와 번들 비교, `swift test --package-path Packages/CrowCore`,
서명 없는 `Crow-macOS` 빌드와 PTY·sshd가 필요 없는 일부 앱 XCTest(`GitAccountTests`,
reverse 에이전트 재연결 테스트), 서명 없는 `Crow-iOS` 시뮬레이터 빌드와 `CrowTests`
컴파일을 실행합니다. 그 밖에 GUI·Keychain·sshd가 필요한 앱 XCTest와 스모크 테스트는
CI에서 실행하지 않으며, 제외 목록과 이유는 워크플로 파일 상단에 있습니다.

추가 터미널·레이아웃·Reverse SSH 검증은 [네이티브 스모크 테스트](../Tools/NativeSmoke/README.md)를 참고하세요.

| 문서 | 내용 |
| --- | --- |
| [Markdown 편집기](../EditorWeb/README.md) | 웹 편집기 소스 수정과 번들 재생성 |
| [앱 아이콘](../Design/AppIcon/README.md) | 원본 아트워크와 플랫폼별 아이콘 내보내기 |
| [macOS 배포](RELEASING.md) | Developer ID 서명, 공증, DMG, Sparkle 및 Homebrew 갱신 |

