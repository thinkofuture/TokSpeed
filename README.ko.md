<p align="center"><img src="Resources/AppIcon.png" alt="TokSpeed 아이콘" width="120" /></p>
<h1 align="center">TokSpeed</h1>
<p align="center"><strong>AI가 게으름 피우는지 메뉴 막대에서 확인하세요.</strong></p>
<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <strong>한국어</strong> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a>
</p>

---

TokSpeed는 **Codex, OpenCode, Claude Code, Antigravity**의 로컬 기록을 읽어 토큰 생성 속도와 최근 호출 추이를 보여 주는 가벼운 macOS 메뉴 막대 앱입니다. API 키나 추가 모델 호출이 필요하지 않습니다.

## 빌드 및 실행

**macOS 13 이상**과 Swift 5 언어 모드를 지원하는 Xcode Command Line Tools가 필요합니다. 시스템 AppKit 및 SQLite를 사용하며 외부 의존성이 없습니다. 현재 Mac의 아키텍처(Apple Silicon 또는 Intel)로 빌드되며 유니버설 바이너리는 아닙니다.

필요하면 명령줄 도구를 설치한 뒤 다운로드하거나 복제한 저장소에서 실행하세요.

```sh
xcode-select --install
bash scripts/build.sh
open build/TokSpeed.app
```

앱은 Dock이 아닌 메뉴 막대에만 표시됩니다. 설치하지 않은 도구는 요약, 소스 선택 및 사용자 지정 순서에서 숨깁니다. 설치했지만 기록이 없으면 ‘데이터 없음’으로 표시합니다. UI는 시스템의 선호 언어를 따르며 영어, 중국어 간체·번체, 일본어, 한국어, 독일어, 프랑스어, 스페인어를 지원하고 나머지는 영어로 표시합니다. 시스템 언어 변경 후 앱을 다시 시작하세요.

- **설정…**: macOS 기본 창에서 변경 사항을 즉시 저장합니다. ‘종료’는 메뉴 마지막에 있습니다.
- **소스 / 표시**: ‘자동’ 또는 고정 도구를 선택하고 ‘숫자와 단위’, ‘숫자만’, ‘아이콘만’을 사용합니다. 호출 대기 중에는 속도(`tok/s`) 대신 경과 초(`s`), 유휴 상태에는 번개만 표시합니다.
- **도구 순서**: 열린 패널에서 도구 카드를 직접 드래그합니다. 삽입선으로 위치를 확인하고 놓으면 저장됩니다. 카드 영역 밖에 놓거나 Escape를 누르면 취소됩니다. 기본 순서는 Claude Code → Codex → OpenCode → Antigravity입니다. 자동 소스 선택에는 영향을 주지 않으며 VoiceOver에서 위/아래 이동 동작을 제공합니다.
- 추이 곡선은 부드럽게 연결하되 인접 데이터의 범위를 넘지 않습니다.

`build/TokSpeed.app`을 응용 프로그램 폴더로 옮길 수 있습니다. 삭제 시 앱을 종료하고 지우세요. 소스·표시·순서 설정은 UserDefaults에 저장되며 종료 후 `defaults delete io.github.thinkofuture.tokspeed`로 지울 수 있습니다.

현재 소스 코드로 제공됩니다. 로컬 ad-hoc 서명만 적용하며 Developer ID 서명 및 Apple 공증은 없습니다. 시스템 도구로 `Resources/AppIcon.png`에서 앱 아이콘을 생성합니다.

## 데이터 소스 및 개인정보

| 소스 | 기본 위치 |
| --- | --- |
| Codex | `~/.codex/sessions/`, `~/.codex/archived_sessions/`의 rollout JSONL. `CODEX_HOME` 지원 |
| OpenCode | `~/.local/share/opencode/opencode.db`. 리더가 구현한 V1/V2 테이블 구조 지원 |
| Claude Code | `~/.claude/projects/`의 JSONL. 하위 에이전트 제외. `CLAUDE_CONFIG_DIR` 지원 |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db`, `conversations/*.db` |

- 모든 도구를 설치할 필요는 없습니다. 데스크톱 앱과 `PATH` 및 일반 설치 경로의 실행 가능한 CLI를 로컬에서 감지합니다. 남아 있는 로그만으로는 설치로 판단하지 않습니다. 감지는 자동 갱신되고, 고정한 소스가 사라지면 설정을 유지하며 자동 선택으로 전환합니다. 각 소스는 전면 창과 무관하게 최근 기록을 선택합니다.
- 로그에 대화가 포함될 수 있습니다. 통계에 필요한 필드를 분석하지만 업로드·네트워크 요청·원본 수정은 하지 않습니다. SQLite는 읽기 전용입니다.
- 소스·표시·순서 설정만 저장하며 대화 사본은 만들지 않습니다. 진단 출력의 세션 ID와 로컬 경로는 공유 전에 가리세요.
- Finder로 실행하면 보통 터미널 환경 변수를 상속하지 않습니다. 사용자 지정 데이터 경로는 변수를 설정한 뒤 터미널에서 앱 내부 실행 파일을 직접 시작하세요.

## 측정 및 한계

로컬 기록에 기반한 추정값으로, **토큰별 순간 속도나 엄밀한 도구 간 벤치마크가 아닙니다.**

- Codex, OpenCode, Claude Code의 이번 응답 속도는 완료된 호출의 총 출력 토큰 ÷ 해당 호출의 총 소요 시간입니다. 첫 호출 완료 전에는 초만 표시할 수 있습니다.
- 측정 구간은 도구에 따라 다르며 첫 토큰 대기 시간 등을 포함할 수 있습니다. Claude Code는 요청 시작 기록이 필요하고 첫 완전한 출력 블록까지 측정합니다. 필드가 부족하면 데이터가 없을 수 있습니다.
- Antigravity는 지난 호출의 출력 토큰 ÷ (첫 토큰 대기 시간 + 스트리밍 시간)을 완료 후 갱신합니다.
- 토큰 수는 각 소스의 보고를 따르며 추론 토큰을 포함할 수 있습니다. 그래프는 최근 최대 12회 호출이며 초별 샘플이 아니고 소스마다 세로축이 다릅니다.
- 원본 형식은 이 프로젝트가 관리하지 않습니다. 도구 업데이트, 사용자 지정 경로, 누락 필드로 데이터 누락이나 오차가 생길 수 있으며 모든 버전과의 호환성을 보장하지 않습니다.

## 기본 검사

실제 대화를 읽거나 앱 설정을 바꾸지 않고 설치 감지 및 숨김, 8개 언어와 대체 언어, 표시 모드, 순서 저장, 곡선, 밝은·어두운 테마, 아이콘, Codex 분할 쓰기를 확인합니다.

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

`-AppleLanguages '("ko-KR")'`로 언어를 지정하고 `--preview-directory <디렉터리>`로 밝은·어두운 미리보기를 저장합니다.

## 라이선스

코드는 [MIT License](LICENSE)를 따릅니다. 타사 아이콘의 출처와 라이선스는 [Resources/Logos/NOTICE.md](Resources/Logos/NOTICE.md)에 있으며 앱에 동봉합니다. 브랜드 및 상표는 각 소유자의 자산입니다. 본 프로젝트는 해당 업체와 제휴하거나 보증받지 않으며 코드 라이선스는 상표권을 부여하지 않습니다.
