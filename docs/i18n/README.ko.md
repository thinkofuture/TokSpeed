<p align="center">
  <img src="../../Resources/AppIcon.png" alt="TokSpeed 아이콘" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>AI가 게으름 피우는지 메뉴 막대에서 확인하세요.</strong><br>
  Codex, OpenCode, Claude Code, Antigravity, Hermes, Cursor의 토큰 생성 속도를 표시하는 가벼운 macOS 메뉴 막대 앱.
</p>

<p align="center">
  로컬 로그만 읽습니다 — API 키 불필요, 업로드 없음, 네트워크 요청 없음.
</p>

<br>

---

<br>

## 빌드, 테스트 및 실행

macOS 13+와 Xcode Command Line Tools가 필요합니다.

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

유니버설 바이너리 빌드 또는 전체 테스트 실행:

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## 패널 및 기능

- **추세 그래프**: 표시된 도구마다 최근 완료된 호출 최대 60건을 공통 속도 축으로 그리며, 활성 도구는 구분 색상과 간결한 Y축 눈금을 제공합니다. 포인트나 카드에 마우스를 올리면 해당 곡선과 상세 정보가 강조됩니다.
- **상세 목록**: **설정 → 패널 보기**에서 전환할 수 있습니다. 진행 중이거나 최근 세션이 2개 이상이면 각 세션의 제목과 속도가 하위 행으로 표시됩니다.
- **고정 및 순서 변경**: 카드를 클릭해 주 소스를 고정하거나 해제하고, 드래그(또는 VoiceOver 동작)로 순서를 바꿀 수 있습니다.
- **설정 및 연동**: **로그인 시 실행**, 도구 표시/숨김, 순서 재설정, 로컬 **진단 정보**(`TokSpeed --diagnostics`), 그리고 사용자 동의 없이 설정 파일을 수정하지 않는 명시적 **Cursor 훅** / **Hermes 플러그인** 관리를 지원합니다.

## 도구별 측정 방식

- **OpenCode**: V2에서는 첫 토큰부터 스트림 종료까지(0.12초 이상, 3,000 tok/s 이하)를 우선 사용하고, 그 외에는 E2E 시간으로 계산합니다.
- **Antigravity**: Antigravity Desktop, `agy` CLI 및 T3 Code Antigravity ACP 로컬 데이터베이스를 읽습니다.
- **Hermes**: 별도 설정 없이 `logs/agent.log`에서 완료된 호출을 읽습니다. 설정 또는 `--install-hermes-plugin`(`--force`로 업그레이드)으로 플러그인을 설치하고 `hermes plugins enable tokspeed-metrics`로 활성화하면 스트림 속도 추정치와 진행 중인 요청의 경과 시간을 볼 수 있습니다.
- **Cursor**: 설정이나 `--install-cursor-hook`으로 명시적 활성화 시 경량 `tokspeed-cursor-hook` 헬퍼가 전체 턴 속도를 기록하며 4 MB마다 `.1`로 로테이션합니다.

## 라이선스

[MIT License](../../LICENSE)
