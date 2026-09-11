# macOS / Homebrew 배포 준비 기록

> 이 문서는 첫 배포 전에 작성한 arm64 ZIP 준비 절차를 보관한 기록입니다.
> 아래의 승인 대기·미공개 상태와 Tap 경로는 당시 기준입니다.
> 현재 배포는 [macOS 배포 안내](../docs/RELEASING.md)의 유니버설 DMG·Sparkle 절차를 사용하며,
> 설치 방법은 [프로젝트 README](../README.md#macos-다운로드)를 확인하세요.

작업을 이어가기 전 [현재 상태 및 인계 메모](STATUS.md)를 먼저 확인한다.

현재 단계는 **로컬 준비**다. 공개 GitHub Release나 Homebrew Tap은 아직 만들지 않는다.
Apple Developer Program 승인 전에는 Developer ID 서명·공증을 완료할 수 없다.
아래 도구는 인증서 생성/폐기, 공증 업로드, Git 태그/푸시, Release 공개, 앱 설치를 하지 않는다.

## 1. 지금: 인증서 없이 Release 빌드

프로젝트 루트에서 실행한다. Xcode 프로젝트를 재생성할 필요는 없다.

```sh
bash Tools/prepare-macos-release.sh 0.1.0 1
```

- macOS 15 이상, Apple Silicon (`arm64`)용 Release archive를 빌드한다.
- Intel 지원은 아직 이 배포 경로에서 검증하지 않았으며 Cask도 arm64로 제한한다.
- 버전/빌드 번호는 이 빌드에만 적용된다. 추적 중인 프로젝트 설정은 바꾸지 않는다.
- `build/release-0.1.0-arm64.<임의문자>/`에 별도 DerivedData, archive, 로그를 만든다.
- 기존 Xcode DerivedData의 패키지 체크아웃만 재사용하려면 실행 시
  `CROW_SOURCE_PACKAGES_DIR=/절대경로/SourcePackages`를 지정할 수 있다.
  지정하지 않으면 별도 폴더에 패키지를 준비한다. 잠금 파일 버전을 사용한다.
- Swift 패키지의 LICENSE/NOTICE(내부에 포함된 라이브러리도 포함)와 웹 에디터 라이선스를 앱에 포함한다.
- archive를 만든 뒤 리소스에 고지를 추가하므로 이 산출물은 **서명용 원본이지 배포용 서명본이 아니다**.

산출물:

```text
release-0.1.0-arm64.<임의문자>/
  Crow.xcarchive/
  build.log
  Package.resolved
  source-commit.txt
  source-worktree.txt
  package/
    Crow-0.1.0-arm64-UNSIGNED.zip
    SHA256SUMS
    manifest.json
    DO-NOT-PUBLISH.txt
```

`build/`는 Git에서 제외된다. 실패한 빌드도 진단을 위해 남기며, 재실행 시 새 폴더를 만든다.
이 ZIP을 정식 릴리스 이름으로 바꾸거나 Cask에 연결하지 않는다. Gatekeeper 우회,
`--no-quarantine`, 전역 보안 해제도 배포 방법으로 사용하지 않는다.

## 2. 지금: 패키징 검증

아래 `APP`에는 위에서 생성한 실제 경로를 넣는다.

```sh
APP='/실제/경로/Crow.xcarchive/Products/Applications/Crow.app'
bash Tools/test-release-packaging.sh "$APP"
```

ZIP을 별도 임시 폴더에 풀어 실행 파일과 리소스가 동일한지, 실행 권한이 유지되는지,
SHA-256/메타데이터가 맞는지 확인한다. 기존 출력 덮어쓰기와 미서명 앱의 정식 패키징이
거부되는지도 검사한다. 사용자 앱 실행·설치나 데스크톱 입력은 하지 않는다.
Homebrew 설치/온라인 audit와 서명된 앱의 Gatekeeper 실행 검사는 아직 별도 단계다.

## 3. 가입 승인 후: 서명·공증

1. Xcode 계정에 유료 팀이 나타나면 **Developer ID Application** 인증서를 만든다.
2. 배포할 소스 커밋과 버전/빌드 번호를 확정한다. Crow 자체 소스의 공개 라이선스 정책도 정한다
   (현재 저장소에 루트 LICENSE가 없으며 이 준비 작업에서 임의로 선택하지 않았다).
3. 고지가 포함된 앱과 내부 실행 코드/프레임워크를 Developer ID로 서명한다.
   Hardened Runtime 및 secure timestamp가 필요하며 `get-task-allow`는 없어야 한다.
   **서명에는 `codesign --deep`을 지름길로 쓰지 않고**, 내장 코드를 안쪽부터 올바르게 서명한다.
   인증서가 준비되면 Xcode Developer ID export를 포함한 실제 서명 경로를 검증한다.
4. Apple에 공증을 제출하고 `Accepted` 결과를 확인한다. 실패하면 로그를 확인한다.
5. `xcrun stapler staple /경로/Crow.app`으로 티켓을 붙인다.
6. 그 뒤에는 앱 내용이나 아이콘을 수정하지 않는다. 수정하면 다시 서명·공증해야 한다.

공증용 자격 증명은 로컬 Keychain에 저장하고 저장소/스크립트/채팅에 넣지 않는다.
서명·공증의 성공 경로는 인증서가 없는 현재 환경에서 검증하지 않았다.

참고: [Developer ID](https://developer.apple.com/developer-id/),
[Apple 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
[패키징](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## 4. 공증 후: 최종 ZIP과 Cask 생성

```sh
bash Tools/package-macos-release.sh --release /경로/Crow.app /아직없는/출력폴더
```

검사: Crow bundle ID, 버전/빌드 번호, macOS 최소 버전, arm64, 필수 리소스,
Debug dylib 부재, 서명 무결성, Developer ID 서명, hardened runtime, timestamp,
디버그 entitlement, stapled ticket, Gatekeeper 평가.
실패하면 최종 ZIP이나 Cask를 만들지 않는다. 검증에 온라인 서비스가 필요할 수 있다.

성공 시 `Crow-0.1.0-arm64.zip`, `SHA256SUMS`, `manifest.json`, `crow.rb`를 만든다.
이 시점의 **최종 ZIP 해시**를 Cask에 기록한다. 공증 전 ZIP 해시를 재사용하지 않는다.
출력 폴더가 이미 있으면 덮어쓰지 않는다. 이 도구도 공개/설치를 자동 실행하지 않는다.
출력의 부모 폴더는 미리 존재해야 하며, 입력 앱 내부를 출력 위치로 지정할 수 없다.

## 5. 사용자 승인 후: 공개와 설치 확인

1. 깨끗한 테스트 환경에서 서명된 다운로드본으로 시작/종료, 폴더 열기·저장,
   터미널·한글 입력, Markdown 편집, SSH/SFTP, 역방향 SSH On/Off를 확인한다.
   일반 개발용 앱의 성공만으로 Developer ID 배포본의 성공을 가정하지 않는다.
2. `startedourmission/crow`의 **확정한 소스 커밋**에 `v0.1.0` 태그와 GitHub Release를 만든다.
3. 최종 ZIP과 SHA256SUMS를 첨부한다. 공개 다운로드의 해시가 로컬 해시와 같은지 확인한다.
4. `startedourmission/homebrew-tap` 저장소를 만들고 생성된 `crow.rb`를 `Casks/crow.rb`에 넣는다.
5. 설치/업데이트를 별도 테스트 환경에서 확인한 후 설치 명령을 README에 공개한다.

배포 완료 후 사용자가 실행할 명령:

```sh
brew install --cask startedourmission/tap/crow
# 이후 새 버전이 나오면
brew update
brew upgrade --cask startedourmission/tap/crow
```

아직 공개되지 않았으므로 지금 위 설치 명령을 배포 안내로 사용하지 않는다.
개인 Tap에서 시작하며 공식 homebrew/cask 등록은 별도 작업이다.
템플릿은 버전과 SHA-256이 들어가기 전까지 설치용 파일이 아니다.
볼트·세션·SSH 키를 지우는 `zap`이나 설치 후 자동 실행 코드는 넣지 않았다.

참고: [Tap 관리](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap),
[Cask 형식](https://docs.brew.sh/Cask-Cookbook).
