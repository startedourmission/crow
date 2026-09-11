# Homebrew 배포 준비 당시의 인계 메모

> 보관용 기록입니다. 아래 상태는 첫 배포 전 로컬 준비 시점의 내용이며,
> 현재 배포 상태나 진행 지침을 뜻하지 않습니다.
> 최신 절차는 [macOS 배포 안내](../docs/RELEASING.md)를 확인하세요.

업데이트: 2026-09-11

## 현재 결정

사용자 요청으로 배포 작업은 여기서 보류하고 앱 기능 개발을 이어간다.
배포를 다시 요청하기 전에는 인증서 발급, 공증 제출, Git 태그, GitHub Release,
Homebrew Tap 생성·공개를 진행하지 않는다.

## 보류 이유

- Xcode 계정은 Personal Team이다.
- Apple Developer Program 등록 과정에서 여권을 요구받아 가입을 보류했다.
- 마지막 확인 당시 이 Mac에는 Apple Development 인증서만 있었고
  Developer ID Application 인증서는 없었다. 재개 시 다시 확인한다.

## 완료한 준비

- `Tools/prepare-macos-release.sh`: 기존 Xcode 빌드와 분리된 미서명 Release archive 생성.
- `Tools/package-macos-release.sh`: ZIP, SHA-256, manifest 생성.
  `--unsigned`는 `UNSIGNED` 파일명과 경고를 사용하며 Cask를 생성하지 않는다.
  `--release`는 Developer ID 서명·Hardened Runtime·timestamp·공증 티켓·Gatekeeper 등을 검사한다.
- `Tools/test-release-packaging.sh`: ZIP 복원, 실행 권한, 리소스, 해시,
  덮어쓰기 방지, 입력 앱 내부 출력 방지, 미서명 앱의 정식 패키징 거부, Cask Ruby 구문 검사.
- `Distribution/homebrew/crow.rb.in`: 개인 Tap용 템플릿. 아직 설치용 Cask가 아니다.
- `Distribution/README.md`: 상세 재개 절차.

## 마지막 검증 결과

- 버전 0.1.0 / 빌드 1, Apple Silicon arm64, 최소 macOS 15.0.
- 별도 Release archive 빌드 2회 성공, 패키징 테스트 통과.
- 최종 로컬 준비 산출물:
  `build/release-0.1.0-arm64.um5FQ4/package/Crow-0.1.0-arm64-UNSIGNED.zip`
- SHA-256: `a51fc2878cdd59abd5f835744191f0ea5103bb2553ac8c08473173a5a6f7355b`
- 위 ZIP은 로컬 미서명 테스트용이며 Git에서 제외된다. 삭제됐으면 다시 빌드한다.
  이후 기능 변경을 포함하지 않으므로 나중에 배포할 때 반드시 새로 빌드한다.
- 서명·공증 성공 경로, 서명된 배포본의 실제 실행, Homebrew 설치/업데이트는 아직 검증하지 않았다.
- 앱 설치·실행이나 사용자 커서 조작 없이 준비 및 패키징 검증만 진행했다.

## Git / 공개 상태

- 마지막 푸시된 커밋: `b7a9a99` (`main`). 앱 기능 수정·아이콘·Markdown 최적화·SSH 수정 포함.
- 배포 준비 스크립트, Distribution 문서 및 README 연결은 이 메모 작성 시점에 미커밋 상태다.
  기존 변경을 보존하고, 커밋·푸시는 사용자가 요청하면 진행한다.
- 이 작업에서 배포용 태그, GitHub Release, Homebrew Tap을 생성하거나 공개하지 않았다.
- 예상 배포 경로는 `startedourmission/crow`의 GitHub Releases와
  `startedourmission/homebrew-tap`의 `Casks/crow.rb`다. 아직 사용 가능한 설치 경로로 안내하지 않는다.

## 재개 순서

1. Apple Developer Program 가입 승인과 Developer ID Application 인증서를 확인한다.
2. 기능 개발이 끝난 소스 커밋, 버전/빌드 번호, 지원 CPU를 확정한다.
   현재는 arm64만 검증했다. Crow 자체 공개 라이선스도 결정이 필요하다
   (준비 당시 루트 LICENSE가 없었으며 임의로 추가하지 않았다).
3. 최신 소스로 다시 Release 빌드하고 의존성 고지를 포함한 뒤 올바르게 서명한다.
4. Apple 공증 승인 후 티켓을 붙이고 `--release` 패키징을 검증한다.
5. 배포본으로 파일 저장, 터미널/한글 입력, Markdown, SSH/SFTP, 역방향 SSH를 테스트한다.
6. 사용자 승인 후에만 Release/Tap을 공개하고 실제 brew 설치·업데이트를 검증한다.

사용자는 긴 문서 링크 대신 한 단계씩 안내받기를 원한다.
재개할 때 전체 절차를 다시 길게 설명하지 말고 현재 필요한 단계부터 안내한다.
