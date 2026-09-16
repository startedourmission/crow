# Crow macOS 배포

Crow는 이 Mac에 이미 등록된 Apple Developer ID와 `notarytool` 키체인 프로필을
사용해 로컬에서 배포합니다. 인증서를 GitHub Actions로 내보낼 필요가 없습니다.

## 현재 사용하는 서명 정보

- Developer ID: `Developer ID Application: Hyun Gyu Park (M7NU9F8CZN)`
- 공증 프로필: `oh-my-opensnap`
- Sparkle 키체인 계정: `startedourmission-crow`
- Sparkle 공개키: GitHub Actions Secret에도 백업됨

공증 프로필은 다음 명령으로 확인할 수 있습니다.

```sh
xcrun notarytool history --keychain-profile oh-my-opensnap
```

## 새 버전 만들기

1. `project.yml`의 `MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION`을 올립니다.
2. `xcodegen generate`를 실행하고 테스트합니다.
3. 변경을 커밋·푸시합니다.
4. 다음 명령으로 서명·공증된 산출물을 만듭니다.

```sh
SPARKLE_PUBLIC_ED_KEY="$(build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account startedourmission-crow -p)" \
NOTARY_PROFILE=oh-my-opensnap \
APPLE_TEAM_ID=M7NU9F8CZN \
BUILD_NUMBER=4 \
scripts/release-macos.sh 0.1.3 dist
```

위 버전·빌드 번호는 다음 배포 예시입니다. `BUILD_NUMBER`는 반드시 명시하고,
저장소를 최신 상태로 갱신한 뒤 `appcast.xml`의 기존 번호보다 큰 정수를 사용합니다.
스크립트는 번호 누락·중복·역행을 배포 작업 전에 차단합니다.
Git 푸시만으로는 앱 업데이트가 배포되지 않으며, 아래의 appcast·Release 갱신도 필요합니다.
공개키를 넣지 않은 로컬 개발 빌드에서는 업데이트 확인을 의도적으로 비활성화합니다.

스크립트는 다음을 수행합니다.

1. arm64와 x86_64 유니버설 Release Archive 생성
2. Sparkle XPC·Updater·Autoupdate를 안쪽부터 Developer ID로 재서명
3. 앱 ZIP 공증, 스테이플 및 Gatekeeper 검증
4. Applications 바로가기가 포함된 DMG 생성
5. DMG 자체 서명·공증·스테이플 및 Gatekeeper 검증
6. ZIP·DMG와 SHA-256 파일 생성

Apple 공증 결과가 `Accepted`가 아니면 스크립트는 즉시 실패합니다.

## Sparkle과 Homebrew 갱신

Sparkle의 `generate_appcast`로 배포 ZIP을 서명해 루트의 `appcast.xml`을 갱신하고,
DMG SHA-256 값으로 `Casks/crow.rb`를 갱신합니다. 두 파일을 커밋한 뒤 해당
커밋에 버전 태그를 만들고 GitHub Release에 다음 파일을 업로드합니다.

- `Crow-macOS.dmg`
- `Crow-macOS.dmg.sha256`
- `Crow-<버전>-macOS.zip`
- `Crow-<버전>-macOS.zip.sha256`

README의 최신 DMG 링크는 고정 파일명 `Crow-macOS.dmg`를 사용하므로 새 버전에도
자동으로 연결됩니다.

Homebrew 6에서는 비공식 tap을 처음 사용할 때 Cask 신뢰 등록이 필요합니다.

```sh
brew trust --cask startedourmission/crow/crow
brew tap startedourmission/crow https://github.com/startedourmission/crow
brew install --cask crow
```

## 최종 확인

```sh
codesign --verify --deep --strict --verbose=2 Crow.app
spctl --assess --type execute --verbose=2 Crow.app
xcrun stapler validate Crow.app

codesign --verify --strict --verbose=2 Crow-macOS.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 Crow-macOS.dmg
xcrun stapler validate Crow-macOS.dmg
```

앱과 DMG 모두 `accepted`와 `source=Notarized Developer ID`가 표시되어야 합니다.
