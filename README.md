<p align="center">
  <img src="docs/assets/app-icon.svg" alt="Crow — 은빛 까마귀 앱 아이콘" width="128" height="128">
</p>

<h1 align="center">Crow</h1>

<p align="center">
  내 컴퓨터와 SSH 서버를 하나의 작업 공간으로.<br>
  Mac · iPhone · iPad에서 터미널, 파일 탐색, 텍스트 편집을 함께 사용하세요.
</p>

<p align="center">
  <a href="https://github.com/startedourmission/crow/releases/latest/download/Crow-macOS.dmg">macOS 다운로드</a> ·
  <a href="#설치">설치 안내</a> ·
  <a href="#주요-기능">주요 기능</a> ·
  <a href="#개발하기">개발하기</a>
</p>

## 설치

**macOS 15 Sequoia 이상 · Apple Silicon 및 Intel 지원**

[**Crow-macOS.dmg 다운로드 →**](https://github.com/startedourmission/crow/releases/latest/download/Crow-macOS.dmg)

DMG를 열고 **Crow.app을 Applications 폴더로 드래그**한 뒤 실행하세요.
배포본은 Developer ID 서명과 Apple 공증을 거칩니다.
버전별 파일과 변경 사항은 [Releases](https://github.com/startedourmission/crow/releases)에서 확인할 수 있습니다.

iPhone·iPad는 iOS/iPadOS 18 이상을 지원하며, 소스 빌드는 아래 [개발하기](#개발하기)를 참고하세요.

### Homebrew

```sh
brew trust --cask startedourmission/crow/crow
brew tap startedourmission/crow https://github.com/startedourmission/crow
brew install --cask crow
```

첫 줄은 [Homebrew 6의 tap 신뢰 설정](https://docs.brew.sh/Tap-Trust)에 따라 Crow Cask를 신뢰하도록 등록합니다.

### 업데이트

새 버전은 앱에서 안내합니다. **Crow → Check for Updates…** 메뉴로 직접 확인할 수도 있습니다.
자동 업데이트에는 Sparkle의 서명 검증을 사용합니다.

> **0.1.0 또는 0.1.1을 사용 중인가요?**  해당 버전은 업데이트 설정 오류로
> **Check for Updates…**가 동작하지 않습니다. 위의 DMG를 다시 내려받아 Applications의
> Crow.app을 한 번 교체해 주세요. 0.1.2부터는 앱 안에서 정상적으로 업데이트할 수 있습니다.

Homebrew로 수동 업데이트하려면:

```sh
brew update
brew upgrade --cask --greedy crow
```

## 주요 기능

| 기능 | 할 수 있는 일 |
| --- | --- |
| 작업 공간 | 로컬 폴더와 여러 SSH 서버 관리, 파일·터미널 탭과 분할 화면, 임시 초안 복원 |
| 에이전트 터미널 | 새 탭에서 Codex·Claude·Grok CLI 실행, 아이콘과 작업 공간별 세션 목록 |
| tmux 관리 | 로컬·SSH 호스트의 세션 조회·생성·접속·이름 변경·종료 |
| 터미널 | macOS 로컬 로그인 셸, SSH 터미널, 한글 IME 입력, 클립보드 이미지 업로드 |
| 서버 화면 | SSH 터널로 서버의 VNC 화면 보기·마우스·터치·키보드 조작 |
| 편집기 | Markdown 렌더링 기본·소스 모드, UTF-8 텍스트·코드 편집, 찾기·바꾸기, 줄 번호·들여쓰기 |
| 파일과 Git | SFTP 탐색·저장, 로컬·SSH 이미지 미리보기, 파일 검색, 외부 변경 감지, Git 브랜치·변경 파일 확인 |
| SSH 키 | Ed25519 키 생성, Ed25519·RSA OpenSSH 키 가져오기, 기기별 Keychain 보관 |
| Mac 전용 | 기존 OpenSSH 설정 사용, Reverse SSH, 다른 창 위에 유지되는 작은 작업 창 |
| 모바일 입력 | iPhone·iPad 키보드 바와 키 조합 설정, iPhone 스니펫 빠른 삽입 |

아래 기능 설명은 현재 소스 기준입니다. 설치한 릴리스에 따라 제공 범위가 다를 수 있습니다.

## 사용하기

### 새 탭에서 에이전트 사용하기

탭 표시줄의 **+ → Codex / Claude / Grok**에서 현재 작업 폴더에 CLI를 실행합니다.
왼쪽 **Workspaces** 버튼(겹친 작업 공간 아이콘)에서 호스트·작업 공간·tmux를 함께 관리합니다.
**Local / SSH 호스트 → 작업 공간 → 터미널·에이전트** 순서로 묶습니다. 작업 공간을 클릭하면
해당 폴더와 열린 파일·터미널로 전환하고, 아래 세션을 클릭하면 해당 터미널을 선택합니다.
Local은 항상 맨 위에, 원격 호스트는 최근 접속 순으로 표시합니다.
각 호스트의 프로젝트는 이름 사전순이며, 고정한 프로젝트도 Pinned 안에서 이름순으로 표시합니다.
호스트 접속 시각은 저장되어 앱을 다시 열어도 순서가 유지됩니다.
호스트 헤더는 `사용자@주소`로 표시하고, 이름을 누르면 바로 연결합니다. 왼쪽 화살표로 목록을 접고 펼칩니다.
상단 왼쪽 아이콘으로 호스트와 작업 공간 목록을 모두 접거나 펼칩니다. tmux 하위 목록은 포함하지 않습니다.
작업 공간과 세션은 단계별로 들여씁니다.
폴더 전체 경로는 작업 공간의 우클릭 메뉴 **Copy Path**에서 복사합니다.

앱의 동작 메뉴·우클릭 메뉴·선택 드롭다운은 같은 커스텀 팝업을 사용합니다. 토글은 오른쪽에 배치하며, 하위 메뉴의 동작을 선택하면 상위 메뉴도 닫힙니다.
탭 우클릭의 **Close Other Tabs**는 해당 분할 영역에서 클릭한 탭만 남깁니다. 다른 분할 영역은 유지하며, 저장하지 않은 파일이나 작업 중인 터미널이 있으면 한 번 확인합니다. 저장 실패·취소 시 닫지 않고, 확인 이후 새로 연 탭도 유지합니다.

Workspaces의 **+**에서 로컬 폴더 또는 연결된 SSH 호스트의 폴더를 엽니다.
macOS의 로컬 폴더 선택창에서 경로를 입력하면 폴더 후보가 나오며 Tab으로 완성할 수 있습니다.
같은 호스트의 같은 폴더는 기존 작업 공간으로 돌아가고, 다른 폴더는 별도로 추가합니다.
세션 목록은 표시등과 닫기 버튼을 사용하고, 작업 중인 터미널·에이전트만 닫기 확인을 표시합니다.
호스트를 제거하면 연결된 작업 공간도 목록에서 제거합니다. 저장하지 않은 파일은 먼저 저장하거나 닫아야 합니다.
SSH 명령어 입력창에서 자동 인증, 비밀번호, 저장된 키를 선택할 수 있고 Mac에서는 키 파일도 선택할 수 있습니다.
tmux가 없는 호스트에는 설치 버튼이 나타나며 해당 호스트의 터미널에서 패키지 관리자로 설치합니다.

우측 **Agents** 탭은 현재 폴더의 Codex·Claude·Grok 저장 세션을 표시합니다. 마지막 대화 두 줄을 미리 보고,
펼치면 첫 프롬프트와 최근 메시지 세 개를 확인합니다. 재개, 새 대화로 분기, 기록 삭제를 지원합니다.
기록은 CLI의 저장소에서 읽고 30초마다 갱신합니다. 로컬·SSH 호스트에 Python 3가 필요하며,
최대 100개를 표시하고 스캔 제한에 도달하면 안내합니다. Codex·Grok 삭제는 해당 CLI의 기본 삭제 기능을 사용합니다.

바로 옆 **Skills** 아이콘은 포커싱한 터미널의 현재 경로(선택한 tmux pane 포함)에 해당하는 스킬을 표시합니다.
**Settings → Agents**에서 사용할 Claude·Codex·Grok을 켜고 끌 수 있습니다. 선택은 새 탭,
역방향 에이전트 생성, 스킬 필터, 사용량 표시에 적용되며 꺼둔 에이전트의 스킬·사용량 조회도 생략합니다.
기본값은 모두 켜짐이며, 기존 터미널과 대화 기록은 유지합니다. Skills 상단의 에이전트 아이콘을
누르면 해당 종류만 조회하며, 새로고침과 검색도 선택한 에이전트에 적용됩니다.
Claude·Codex 아이콘, 이름, 설명, 출처를 보여주며 검색·새로고침과 `SKILL.md` 열기를 지원합니다. 로컬과 SSH에서 같은 방식으로 동작합니다.
Codex는 해당 호스트 CLI의 `skills/list`로 활성 스킬을 조회합니다. Claude는 [스킬 경로·우선순위](https://code.claude.com/docs/en/skills)에 따라 프로젝트·사용자·관리 폴더와 활성 설치 플러그인의 파일을 읽습니다. Claude 내장 명령, 계정 동기화 스킬, 실행 시 `--add-dir`·`--plugin-dir` 등의 추가 경로는 이 파일 목록에 포함하지 않습니다.
Grok은 [`grok inspect --json`](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/08-skills.md)의 현재 폴더 보고서를 사용하며, 비활성 스킬은 제외합니다. 해당 명령을 지원하는 CLI가 필요합니다.
탭을 열거나 경로를 바꾸거나 새로고침할 때만 조회하며 최대 500개를 표시합니다. 스킬 본문과 스크립트를 실행하지 않고 상시 색인도 만들지 않습니다.

왼쪽 **Automations**는 현재 기기의 사용자 crontab과 macOS launchd 정의·실행 상태를 읽습니다.
cron 주기·명령어·활성 여부와 원본 crontab, launchd 주요 필드와 plist 원문을 편집할 수 있습니다.
다른 곳에서 수정한 내용을 덮어쓰지 않도록 저장 전 변경을 확인합니다. launchd는 파일 저장 후 **Reload Job**으로 적용하며,
다시 로드하면 RunAtLoad 작업이 실행될 수 있습니다. 시스템 파일은 연결 사용자의 권한에 따라 읽기 전용입니다.

하단 오른쪽에서 Crow 프로세스의 메모리·CPU를 확인할 수 있습니다.
AI 사용량은 선택한 기기의 CLI 계정 한도이며 5분마다 갱신합니다. 누르면 사용 비율과 리셋 시간을 확인합니다.
macOS Claude 로그인은 수동 새로고침에서 키체인 접근을 허용한 뒤 메모리에만 유지합니다.
CLI 미설치·로그인 만료·조회 실패는 사용량 0% 대신 별도로 표시합니다.
`.canvas`와 `.base`도 기본으로 렌더링하며 상단 버튼으로 소스 편집으로 전환할 수 있습니다. Obsidian 본체 코드를 복제하지 않고 공개 [JSON Canvas 규격](https://jsoncanvas.org/spec/1.0/)과 [Bases 문서](https://obsidian.md/help/bases/syntax)를 기준으로 구현했습니다.

- Canvas: 텍스트·파일·링크·그룹 카드, 연결선, 확대·이동·화면 맞춤을 지원합니다. 카드 헤더를 끌어 이동하고 모서리로 크기를 조절하며, 연결점을 다른 카드로 끌어 연결합니다. 더블 클릭으로 내용·연결선을 편집하고 선택 도구로 색상 변경·삭제할 수 있습니다. 변경은 Save/⌘S로 저장합니다.
- Bases: 현재 로컬/SSH 워크스페이스의 파일과 Markdown frontmatter를 table/cards/list로 표시합니다. 보기 추가, 열 선택, 필터·정렬·그룹 설정과 검색을 지원합니다. 노트 속성은 셀 더블 클릭이나 연필 버튼으로 수정하며 해당 Markdown 파일에 바로 저장합니다. 보기 설정은 Save/⌘S로 저장합니다. 파일·수식 속성은 읽기 전용입니다.
- 두 형식 모두 실행 취소·다시 실행을 지원합니다. Bases 속성 저장은 기존 본문·YAML 주석을 보존하고 다른 편집기나 외부 파일 변경과 충돌하면 덮어쓰지 않습니다. 외부 파일 변경은 새로고침으로 반영합니다.

Bases는 최근 파일 목록·본문을 메모리에 캐시하고, 재열기 시 먼저 표시한 뒤 크기·수정 시각이 바뀐 파일을 다시 읽습니다. 캐시는 최대 4개 워크스페이스·총 32 MB 비용 한도로 제한하며 메모리 압박 시 해제됩니다. 최초 폴더 검색과 SSH 전송 비용은 남습니다. 수식과 YAML 해석 결과도 재사용합니다.

Markdown 렌더링의 frontmatter는 읽기 전용 속성 표로 표시하며 Source에서 수정합니다. HTTP/HTTPS 링크는 한 번 클릭하면 문서가 속한 워크스페이스의 Crow 브라우저 탭에서 열립니다. `Internal links & backlinks` 설정은 기본 꺼짐입니다. 켜면 `[[노트]]`, `[[노트|별칭]]`과 상대 경로 Markdown 링크를 사용할 수 있습니다. 백링크는 목록을 펼치거나 새로고침할 때만 Bases와 같은 제한·캐시로 계산하며, 상시 색인·임베딩·별도 데이터베이스는 만들지 않습니다. 작업공간 밖으로 나가는 경로와 이름이 중복된 링크는 열지 않습니다. 전체 Obsidian 문법(임베드·블록 참조 등)을 지원하는 것은 아닙니다.

Obsidian 플러그인 뷰·고급 수식 전체·요약 계산은 지원하지 않으며, 지원하지 않는 표현식은 오류로 표시합니다. 최대 2,000개 파일/3,000개 폴더, Markdown 파일당 512 KB·총 20 MB로 제한하고 생략한 파일은 안내합니다.

**새 탭 → Web Browser** 또는 워크스페이스의 **+ → Web Browser**로 웹 페이지를 탭 안에서 엽니다. 주소창, 뒤로/앞으로, 새로고침, URL 복사와 탭/주소 복원을 지원합니다. 원격 워크스페이스에서 `localhost:3000` 같은 주소를 입력하면 기존 SSH 연결로 전용 포트 포워딩을 만들고, 상단에 `localhost → 사용자@호스트 via SSH`를 표시합니다. 탭을 닫거나 SSH를 끊으면 해당 포워딩도 정리합니다. 브라우저 쿠키와 캐시는 탭별 메모리에만 유지합니다.

원격 미리보기는 같은 출처의 상대 경로 요청과 WebSocket을 지원합니다. 내부적으로 로컬 포트를 사용하므로, 코드에 박아 둔 별도 `localhost` URL·특정 Origin/쿠키 도메인·localhost 전용 HTTPS 인증서가 필요한 앱은 개발 서버 설정을 조정해야 할 수 있습니다. 페이지 내부의 포워딩되지 않은 localhost 요청은 이 기기의 서비스로 연결되지 않도록 차단합니다. 외부 HTTP/HTTPS 사이트는 일반 연결을 사용합니다.

Markdown 파일은 기본으로 렌더링 화면을 표시합니다. **Settings → Editor → Default Markdown view**에서
Rendered / Source를 선택할 수 있으며, 선택은 재시작 후에도 유지됩니다. 다른 텍스트·코드 파일은 소스로 엽니다.

파일 탐색기 우클릭 메뉴에서 **Move… / Copy Path / Delete…**를 사용할 수 있습니다.
이동은 로컬·SSH 모두 작업 공간 안의 폴더를 선택하며, 열린 파일의 미저장 초안도 유지합니다.
파일 탐색기는 현재 작업 공간의 폴더만 표시합니다. SSH 연결이 끊겨도 폴더와 탭 목록은 남습니다.
작업 공간 하나를 목록에서 제거해도 같은 호스트의 다른 작업 공간 연결은 유지됩니다.
새 터미널과 에이전트는 해당 작업 공간 폴더에서 시작합니다.
iPhone에서는 하단 제목 또는 **Session and Settings → Workspaces**에서 같은 목록을 엽니다.
호스트 행의 연결 버튼과 메뉴에서 연결·해제·폴더 열기·호스트 편집·삭제를 관리합니다.

실행할 Mac 또는 SSH 서버에 해당 CLI가 설치되어 있고 로그인되어 있어야 합니다.
기본 실행은 YOLO 모드입니다. 슬래시 커맨드, 모델 선택과 도구 승인은 원래 CLI 화면에서 처리합니다.
Crow는 채팅 UI·에이전트 프로토콜·대화 기록 저장을 별도로 구현하지 않습니다.
워크스페이스의 에이전트 행은 **Working**(작업 중), **Idle**(입력 대기),
**Needs input**(질문·승인 응답 필요)을 표시합니다. 현재 터미널 화면을 이용한 추정이며,
판별할 수 없는 화면은 **Running**으로 남깁니다. 별도 에이전트 서버나 대화 기록 저장은 없습니다.
탭을 다시 열면 새 CLI 프로세스가 실행되며, 이전 대화를 이어가려면 CLI의 세션 복원 기능을 사용하세요.
iPhone·iPad에서는 SSH 서버에 연결해 사용합니다.

각 호스트 아래 **tmux**를 펼치면 그 호스트의 기본 소켓 세션을 불러옵니다.
여러 작업 공간이 있어도 호스트당 한 목록만 표시하며, **+**로 생성하고,
세션 → 윈도우 → pane을 펼쳐 원하는 위치를 클릭하면 터미널에서 접속합니다.
이미 접속한 세션은 열린 터미널 탭을 재사용하며, 윈도우·pane 클릭은 해당 위치로 포커스를 이동합니다.
tmux 터미널에서 에이전트를 선택하면 활성 pane의 폴더에서 실행하고, 종료 후 같은 셸로 돌아옵니다.
로컬 tmux의 Reverse Agent도 해당 pane에서 기존 SSH 인증 연결을 사용합니다. 실행 중인 프로그램이 있는 pane에는 명령을 보내지 않습니다.
세션 행의 **+**로 새 윈도우를 만들고, 윈도우·pane 행의 분할 버튼으로 좌우 또는 상하로 나눕니다.
새 항목은 생성 후 바로 포커스되며, 분할은 대상 pane의 현재 폴더를 이어받습니다.
세션 메뉴에서 이름 변경·종료를, 윈도우와 pane의 **×**에서 개별 종료를 할 수 있습니다.
닫기 확인은 **Enter**, 취소는 **Escape**로 처리합니다. `Ctrl-B`, `D`로 접속만 해제할 수 있습니다.
선택한 작업 공간·tmux 세션은 하위 목록까지 같은 배경으로 묶고 선택한 행은 더 진하게 표시합니다.
호스트에 tmux가 없으면 설치가 필요하다는 메시지를 표시합니다.

새 터미널은 UTF-8 문자 로케일로 시작하며, SSH 셸에서는 호스트에 설치된 UTF-8 로케일을 사용합니다.
새 tmux 세션에도 문자 로케일을 전달해, 기존 tmux 서버가 `C` 로케일로 시작했더라도 한글 입력이
깨지지 않도록 합니다. 이미 실행 중인 셸의 로케일은 이 설정으로 소급 변경되지 않습니다.

### 서버 화면 보기와 조작

SSH 연결 후 터미널·파일 탐색기의 모니터 아이콘 또는 iPhone 메뉴의 **Server Screen**을
열고 상단 **Connect…**에서 VNC 포트(기본 `5900`)를 지정합니다. 서버에는 화면 공유 또는
VNC 서버가 실행 중이어야 합니다. Mac은 **시스템 설정 → 일반 → 공유 → 화면 공유**에서
접근 계정을 설정할 수 있습니다([Apple 안내](https://support.apple.com/en-euro/guide/mac-help/-mh11848/mac)).
Windows·Linux는 별도의 VNC 서버가 필요합니다. 연결 대상은 SSH 서버에서 본
`127.0.0.1`이므로 WSL 내부 SSH에 접속했다면 그 환경에서 VNC 서비스에 접근할 수 있어야 합니다.

Mac에서는 기본으로 선택한 SSH 계정의 화면 공유 인증을 사용하며, 로그인 창에는 해당 계정의
Mac 로그인 암호를 입력합니다. 창 제목에도 `사용자@호스트`가 표시됩니다.
공용 바탕화면에 접속하려면 **··· → Screen Login → Shared desktop (VNC password)**를 선택하세요.
계정 인증을 지원하지 않는 Mac에 공용 VNC 암호로 자동 전환하지 않습니다.
화면 공유 암호는 저장하지 않으며, 화면 데이터와 입력은 기존 SSH 연결을 통해 전달합니다.
화면을 닫아도 터미널과 파일 연결은 유지됩니다. 마우스·터치로 조작하고,
휴대폰·태블릿에서는 **Keyboard**로 키보드를 열어 바로 입력할 수 있습니다.
상단 버튼으로 연결·연결 해제하고, **···** 메뉴에서 닫기, **View Only**, **Fit to Window**를 조절합니다.
Mac의 **Sync Clipboard**와 **Include Images (Mac Server)**는 기본으로 켜져 있으며 같은 메뉴에서 끌 수 있습니다.
SSH를 통한 이미지·텍스트 클립보드 동기화는 화면 인증 계정과 SSH 계정이 같을 때만 사용합니다.
공용 바탕화면이나 다른 계정은 VNC 텍스트 동기화를 사용하며 이미지 전송은 지원하지 않습니다.
**View Only**는 조작을 잠그고, **Fit to Window**를 끄면 원래 크기로 표시해 이동합니다.
앱이 백그라운드로 가면 화면 전송은 종료되므로 복귀 후 다시 연결하세요.

### iPhone·iPad의 백그라운드 SSH

앱을 잠깐 나갈 때 iOS의 추가 실행 시간을 요청하고 SSH 연결을 유지합니다.
복귀할 때 기존 연결을 검사하고, 끊겼거나 응답하지 않는 연결은 자동으로 재접속합니다.
재접속 때문에 선택한 작업 공간이나 화면을 바꾸지 않으며, 직접 끊은 연결은 복구하지 않습니다.

iOS가 부여하는 백그라운드 시간은 제한되어 있어 무기한 연결 유지는 보장하지 않습니다
([Apple 개발자 문서](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)).
재접속은 새 SSH 연결과 셸을 만들며, 끊긴 셸의 실행 작업까지 복원하지는 않습니다.
장시간 작업을 유지하려면 서버의 `tmux` 같은 세션 관리 도구를 함께 사용하세요.

### Reverse SSH · macOS

서버에서 실행 중인 에이전트가 **내 Mac에서 명령을 실행하거나 파일을 수정**할 수 있습니다.

1. Workspaces 호스트 헤더에서 SSH 연결 버튼 오른쪽의 **원형 되돌림 화살표**를 누릅니다.
2. 준비가 끝나면 접속 명령이 자동으로 클립보드에 복사됩니다. 서버 터미널이나 에이전트에서 실행하면 별도 비밀번호 입력 없이 내 Mac에 연결됩니다.
3. 버튼을 다시 누르면 연결 중인 역방향 세션도 즉시 종료됩니다. 명령을 다시 복사하려면 호스트 메뉴의 **Copy Reverse SSH Command**를 사용합니다.

터미널 SSH뿐 아니라 Crow에 저장한 키·비밀번호로 연결한 호스트에서도 기존 SSH 연결을 사용합니다.
Crow 서버 설치, 기기 등록, 별도 공개키 복사는 필요하지 않습니다.
준비나 연결 유지에 실패하면 호스트 이름과 실패 단계를 오류창에 표시합니다.
Mac의 시스템 원격 로그인을 켤 필요도 없습니다. 토글을 켤 때마다 임시 SSH 키를 만들며,
접속한 프로세스는 현재 Mac 사용자 권한으로 작업합니다. 서버에서 SSH 포트 포워딩을
허용해야 하며, macOS 사이에서만 지원합니다.

임시 접속 파일은 서버의 로그인 계정만 읽을 수 있도록 저장합니다(폴더 700, 키 600).
클라이언트 사이의 접근을 분리하려면 서버에서 서로 다른 SSH 계정을 사용하세요.
같은 서버 계정의 프로세스들은 해당 계정에 저장된 역방향 통로를 사용할 수 있습니다.

여러 기기의 역방향 연결을 동시에 켤 수 있으며, 접속 명령마다 임시 키와 대상 Mac의
호스트 키가 고정됩니다. 한 연결을 꺼도 다른 연결은 유지됩니다. 기존 tmux 세션이나
에이전트에서도 사용할 수 있고, `SSH_CONNECTION` 환경변수가 없거나 오래되어도 동작합니다.

### Reverse Agent · macOS

로컬 워크스페이스의 탭 **+ → Reverse Agent…**에서 SSH 서버와 Claude·Codex·Grok을
선택합니다. 현재 작업 폴더가 자동으로 적용됩니다. Crow가 서버 연결과 Reverse SSH를 준비하고 접속 명령을
복사한 다음, 서버에 로그인된 CLI를 실행합니다. 양쪽 Mac에 Python 3이 필요하며,
선택한 서버에는 해당 CLI의 설치와 로그인이 완료되어 있어야 합니다.
필요한 도구 설정을 지원하지 않는 구버전 CLI는 실행 전에 업데이트 안내를 표시합니다.

에이전트의 파일 읽기·수정과 명령 실행은 전용 MCP 도구를 통해 클라이언트에서 수행합니다.
작업 폴더는 세션을 만들 때 고정되며, 탭·파일 탐색기·Git은 로컬 워크스페이스에 남습니다.
대화 기록은 서버에 저장되고 해당 탭의 에이전트 패널에서 재개·분기·삭제할 수 있습니다.
서버의 로그인 정보는 클라이언트로 복사하지 않습니다.

연결 종료나 앱 재실행 후에는 탭 메뉴의 **Restart Reverse Agent…**로 통로를 다시 준비합니다.
기존 대화를 이어가려면 에이전트 패널에서 저장된 대화를 재개하세요.
클라이언트 명령은 최대 120초 동안 실행되며 종료 시 남은 자식 프로세스도 정리하므로,
계속 실행할 개발 서버는 일반 터미널에서 시작하세요. 이 기능은 파일시스템 마운트나
프로세스 보안 격리가 아니며, 기존 Reverse SSH와 동일한 사용자 권한으로 동작합니다.

<details>
<summary><strong>SSH 연결과 원격 파일 편집</strong></summary>

iPhone·iPad에서 터미널 시작 폴더는 호스트의 **Remote folder** 설정을 따릅니다.
`~`는 서버 사용자의 홈입니다. Windows SSH 서버가 WSL을 기본 셸로 여는 구성이면
호스트 편집에서 **WSL default shell**을 켜세요. 이 옵션은 기존 호환 동작대로
선택한 원격 프로젝트 폴더에서 터미널을 시작합니다. 변경 후에는 다시 접속하세요.

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

</details>

<details>
<summary><strong>SSH 키 생성·가져오기·관리</strong></summary>

iPhone·iPad에서 새 SSH 명령으로 연결하면 인증 화면에서 비밀번호 또는 SSH 키를 선택합니다.
저장한 키 선택, 키 생성·가져오기도 같은 흐름에서 진행할 수 있습니다.

Mac, iPhone, iPad에서 **Workspaces 상단 열쇠 버튼** 또는 **Settings → SSH Keys**를 엽니다.

Mac에서는 `~/.ssh`의 Ed25519·RSA OpenSSH 개인키가 **On This Mac · ~/.ssh**에
자동으로 표시됩니다. 키를 선택하면 공개키를 볼 수 있고, **Add to SSH Keys** 또는
**Use This Key**로 앱에 등록할 수 있습니다. 암호가 걸린 키는 이때 암호를 입력합니다.
이미 등록한 키는 중복 표시하지 않으며, 원본 파일은 변경하지 않습니다.

1. **+ → Generate New Key**에서 이름을 입력하고 Ed25519 키를 생성합니다.
   기존 Ed25519·RSA OpenSSH 개인키는 **Import Key**로 가져올 수 있습니다.
2. 키 상세 화면의 **Copy Public Key**로 공개키를 복사해 서버에 등록합니다.
3. 호스트 편집 화면에서 **Authentication → SSH Key → Choose or Create SSH Key…**를
   열고 **Use This Key**를 선택한 뒤 저장합니다. 여러 호스트에서 같은 키를 사용할 수 있습니다.

키 이름 변경과 삭제는 키 상세 화면에서 합니다. 저장된 호스트가 사용하는 키는
다른 키로 교체한 뒤 삭제할 수 있습니다. 개인키는 해당 기기의 Keychain에 저장되며
기기 간 자동 동기화되지 않습니다. Mac에서 앱의 저장된 키를 선택하면 입력한
호스트·포트로 직접 연결하며, 기존에 저장한 SSH 명령 옵션은 대체됩니다.

</details>

<details>
<summary><strong>파일 자동 갱신, 이미지 붙여넣기와 입력 도구</strong></summary>

- 로컬·SSH 파일 탐색기에서 PNG, JPEG, GIF, WebP, HEIC, TIFF 등 시스템이 지원하는 이미지를 클릭하면
  같은 파일 탭에 미리보기가 열립니다. **Fit**, **100%**, 확대·축소 버튼과 핀치 제스처를 지원합니다.
  투명 영역은 체크무늬로 표시하며, 이미지는 읽기 전용입니다. 최대 50 MB까지 열고 큰 이미지는
  긴 변 4096픽셀로 축소해 표시합니다. 애니메이션 이미지는 첫 프레임을 보여줍니다.
- 열어 둔 로컬·SSH 파일이 다른 프로그램에서 바뀌면 자동으로 갱신합니다.
  미저장 편집이 있으면 그대로 보존하고 외부 변경 안내와 다시 불러오기 버튼을 표시합니다.
- SSH 터미널에서 **Ctrl+V**를 누르면 클립보드 이미지를 서버의 임시 PNG 파일로
  업로드하고 경로를 입력합니다. Enter는 추가하지 않습니다. Mac의 **Cmd+V**는 기존
  텍스트 붙여넣기입니다. iOS에서는 붙여넣기 또는 키보드 바의 Ctrl 다음 v도 사용할 수 있습니다.
  에이전트가 이미지 파일 경로 입력을 지원해야 하며, 업로드 파일은 사용 후 서버에서 삭제할 수 있습니다.
- iPhone·iPad의 터미널과 문서 편집기는 같은 가로 스크롤 키보드 바를 사용합니다.
  **Settings → Keyboard Bar**에서 현재 목록의 키를 삭제·정렬하고, 아래 키 버튼을
  눌러 Shift+Tab 같은 조합을 만든 뒤 **Add**로 추가합니다.
- iPhone 하단의 **Snippets** 버튼에서 텍스트를 저장하고 목록을 탭하면 현재 커서에
  삽입합니다. Mac·iPad에서는 왼쪽 내비게이션의 스니펫 버튼으로, Mac 호버 창에서는 하단 버튼으로 엽니다.
  저장한 텍스트 뒤에 Enter를 추가하지 않습니다. 목록 관리는 설정에서도 가능합니다.
- iPhone 문서 제목 옆 디스크 버튼으로 저장합니다. 터미널·문서 전환 버튼을 길게 누르면
  약한 햅틱과 함께 문서는 위, 터미널은 아래에 배치된 열린 탭 그리드에서 선택할 수 있습니다.
- iPad 워크스페이스 선택기는 Mac처럼 왼쪽 패널 하단에 있습니다. 오른쪽 패널의
  **Summary / Git** 탭에서 문서 목차와 SSH 작업 공간의 Git 상태를 확인합니다.
  Git 탭은 볼트와 하위 폴더의 Git 프로젝트 목록을 먼저 보여줍니다. 볼트 자체가
  저장소여도 프로젝트를 한 번 선택해야 브랜치와 변경 파일이 표시됩니다.
  **Projects**로 목록에 돌아가 다른 저장소를 선택할 수 있습니다.
  하단에는 원격 저장소 주소와 커밋 작성자를 표시합니다. **Settings → GitHub Credentials**에서
  계정 ID와 토큰을 기기 Keychain에 저장·수정·삭제할 수 있습니다. 저장할 때 네트워크 인증은 하지 않습니다.
  저장한 자격 증명은 이후 기능에서 필요할 때 읽을 수 있으며, 현재 터미널 Git 인증에는 자동 적용하지 않습니다.
  읽을 수 없는 하위 폴더가 있으면 안내와 함께 접근 가능한 저장소를 표시합니다.
  상단은 Mac과 같은 36pt 탭·패널 제목줄을 사용합니다.
- 문서 검색 버튼 오른쪽의 **…** 메뉴에서 **Move File…**로 워크스페이스 안의 다른 폴더로
  이동하거나 **Download File…**로 기기에 복사본을 저장합니다. 이미지 도구 모음에도 같은 메뉴가 있습니다.
  SSH 파일도 지원하며, 이동 시 열린 탭과 미저장 편집을 유지합니다. 내려받기는 최대 50 MB이며,
  이미지는 미리보기 변환본이 아닌 원본, 수정 중인 문서는 현재 편집 내용을 저장합니다.
- 파일 탐색기를 우클릭한 뒤 **Show Hidden Files**를 선택하면 숨김 항목 표시와 검색을 켤 수 있습니다.
  SSH 프로젝트 폴더 선택창은 이 설정과 무관하게 숨김 폴더도 표시합니다.
  **From Terminal…**에서 같은 작업 공간의 열린 터미널을 고르면 보고된 현재 폴더로 이동합니다.
  새 SSH 터미널의 bash·zsh 셸은 폴더를 자동 보고하며, 경로가 아직 없는 터미널은 선택할 수 없습니다.
  원격 프로젝트 선택 아이콘은 SSH 작업 공간에만 표시됩니다.
- Mac의 **File → New Window** (`⌘⇧N`)는 독립된 작업 창을 엽니다. 저장소 선택, 탭,
  미저장 편집, 터미널·SSH 연결과 세션 저장 파일은 창마다 따로 유지하며, 메뉴와 단축키는 활성 창에 적용됩니다.
- Mac의 좌측 패널 토글 왼쪽 **Float Window** 버튼으로 작은 창을 띄울 수 있습니다.
  다른 창이나 Space를 사용해도 위에 유지되며, 상단 **Restore Window** 버튼으로 원래 크기로 돌아갑니다.

파일 내용 검색에는 `contents:` 접두사를 사용합니다. 예: `contents:TODO`.

</details>

<details>
<summary><strong>데이터 저장과 접근 권한</strong></summary>

macOS 버전은 로컬 셸과 일반 개발 명령을 실행해야 하므로 App Sandbox를 사용하지
않습니다. 신뢰할 수 있는 명령과 서버에만 연결하세요.

- **Settings → Files → Delete moves files to**에서 복구 폴더(기본값) 또는 휴지통을 선택합니다.
  복구 폴더는 해당 작업 공간 루트의 `.crow/recovery/`입니다. 휴지통은 파일이 있는 기기·저장소의 기능을 사용합니다.
  원격 Mac은 Foundation, Linux 서버는 `gio` 또는 `trash-put`이 필요합니다. 지원하지 않으면 파일을 그대로 두고 오류를 표시합니다.
  기존 로컬 `.crow-trash`와 현재 원격 폴더의 `.crow-trash-…` 복구 항목도 다음 삭제 시 이 안으로 합쳐집니다.
- 저장하지 않은 초안과 세션 정보는 로컬 JSON 파일에 권한 `0600`으로 저장되며
  별도 암호화되지는 않습니다.
- 앱에 저장한 SSH 개인키와 인증 정보는 각 기기의 Keychain이 관리합니다.
  Mac 터미널의 SSH 명령은 시스템 OpenSSH 설정을 사용합니다.
- 실행 중인 셸 프로세스와 SSH 연결은 앱 재시작 후 자동 복원되지 않습니다.
- Reverse SSH를 끄면 임시 접속 권한을 폐기하고 서버의 접속 파일을 정리합니다.
  역방향 SSH는 macOS 기기 간에만 지원합니다. Linux·WSL·Windows로 확인된 호스트에는 역방향 버튼이 표시되지 않습니다.
  접속 파일은 서버 홈의 `.crow/reverse-ssh/`에 연결별로 저장합니다.
  서버 연결이 끊긴 상태라면 이 안에 폴더가 남을 수 있지만 기존 명령으로 재접속할 수는 없습니다.

</details>

## 개발하기

필요한 도구는 전체 Xcode와 XcodeGen입니다. Xcode의 플랫폼 및 Metal Toolchain
컴포넌트도 설치되어 있어야 합니다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
open Crow.xcodeproj
```

Xcode에서 `Crow-macOS` 또는 `Crow-iOS` 스킴을 선택합니다.

<details>
<summary><strong>테스트 실행</strong></summary>

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

추가 터미널·레이아웃·Reverse SSH 검증은 [네이티브 스모크 테스트](Tools/NativeSmoke/README.md)를 참고하세요.

</details>

| 문서 | 내용 |
| --- | --- |
| [Markdown 편집기](EditorWeb/README.md) | 웹 편집기 소스 수정과 번들 재생성 |
| [앱 아이콘](Design/AppIcon/README.md) | 원본 아트워크와 플랫폼별 아이콘 내보내기 |
| [macOS 배포](docs/RELEASING.md) | Developer ID 서명, 공증, DMG, Sparkle 및 Homebrew 갱신 |

## 사용한 오픈소스

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) ·
[Citadel](https://github.com/orlandos-nl/Citadel) ·
[Tiptap](https://github.com/ueberdosis/tiptap) ·
[Sparkle](https://github.com/sparkle-project/Sparkle)
