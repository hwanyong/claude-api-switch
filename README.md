# Claude API Switch (메뉴바 앱)

Claude Code의 API 대상(엔드포인트)을 메뉴바에서 즉시 전환하는 macOS 앱입니다.
LM Studio(Bionic) / Strata(로컬 서빙) / 공식 Claude API를 클릭 한 번으로 바꾸고,
새로 시작하는 `claude` 세션이 바뀐 설정을 사용하게 합니다.

## 빠른 사용
1. `ClaudeAPISwitch.app`을 `/Applications`에 넣고 실행 (설치 스크립트: `install.sh`)
2. 메뉴바의 ⇄ 아이콘 클릭 → `LM Studio (Bionic)` 또는 `Strata` 선택
3. 터미널에서 새 `claude` 세션 시작 → 로컬 모델로 동작 (기존 세션은 그대로)
4. 되돌릴 땐 `공식 Claude API` 선택 (관리 키만 삭제, 키체인 자격증명 유지)

## 메뉴 기능
- 현재 상태 헤더: 어떤 백엔드·모델로 붙어 있는지 (⚠ = 서버 미응답)
- 전환: 공식 / LM Studio (Bionic) / Strata — LM Studio는 서버가 꺼져 있으면 자동으로 `lms server start`
- 모델: 백엔드별 감지 모델 목록에서 선택 (`GET /v1/models` 실측, 별칭/컨텍스트 길이 표시)
- 서버: LM Studio 서버 시작/중지 (lms CLI), Strata 앱 실행
- 지금 상태 점검: 백엔드에 최소 `POST /v1/messages` 왕복 테스트
- 새 세션 실행 명령 복사: `claude --settings ~/.claude/profiles/<백엔드>.json` 을 클립보드에
  (전역 설정을 안 바꾸고 그 터미널 세션만 로컬로 쓰는 방식)
- 백업 복원: 최근 20개 백업 중 선택 복원 (복원 전 현재 상태도 백업: `pre-restore`)
- settings.json 열기 / 로그 폴더 열기
- 로그인 시 자동 시작 (SMAppService, .app 번들로 설치했을 때만; macOS 27에서는 허용 동의 창 표시)
- 종료

## 안전하게 다루는 방식
- `~/.claude/settings.json`은 **병합 전용**: `env` 블록의 관리 키만 추가/삭제하고
  model·permissions·hooks 등 나머지 키와 값은 절대 건드리지 않음 (VM 시험에서 구조 diff 0 확인)
- 관리 키: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`,
  `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_SONNET/OPUS/HAIKU_MODEL`,
  `CLAUDE_CODE_ATTRIBUTION_HEADER`, `ANTHROPIC_API_KEY`(항상 제거)
- 쓰기 전 `flock` 잠금 + mtime 재확인(경쟁 시 최대 3회 재시도), 백업 후 rename(2) 원자적 교체,
  쓰기 후 재검증, 실패 시 백업으로 롤백
- 깨진 settings.json은 수정 거부 (파일 그대로 유지)
- 로그(JSONL)와 저장 설정에서 토큰/키 마스킹 (앞4…뒤4, 절대 평문 기록 안 함 — grep 0 확인)
- 전환은 **새 세션에만** 적용. 실행 중인 Claude Code 세션에는 영향 없음
- 주의: JSON 재직렬화로 settings.json의 키 순서가 바뀔 수 있음(내용 동일)

## 감지 방법
- LM Studio: `lms server status` 포트 파싱 → http-server-config 포트 → 1234 순서로 `GET /v1/models` 프로브.
  기본 토큰 `lmstudio`, `CLAUDE_CODE_ATTRIBUTION_HEADER=0` (LM Studio 공식 문서 권장)
- Strata: `~/.strata/data/native-instances/*.json` 실측 기반 (host/port/api_key/model_name).
  기본 포트 18500, `x-api-key` 필수. 문서 없는 제품이라 실측으로만 확인
- 공식: 키체인 `Claude Safe Storage` 자격증명 유무로 로그인 상태 표시

## CLI (GUI 없이 동일 엔진)
```
claude-switch status [--json]     # 현재 상태 + 백엔드 감지 (토큰 마스킹)
claude-switch list                # 백엔드/모델 요약
claude-switch switch <kind> [--model M] [--no-autostart]   # official|lmstudio|strata
claude-switch models <kind>
claude-switch check <kind>        # POST /v1/messages 왕복 점검
claude-switch profile <kind> [--model M]   # 세션형 프로필 생성 + 명령 출력
claude-switch backups
claude-switch restore <file|latest>
```
`CLAUDE_CONFIG_DIR`를 지정하면 그 디렉터리의 settings.json을 다룹니다(시험 격리용).

## 빌드
```
cd src && swift build -c release
# .app 번들 조립: dist/build_app.sh 참고 (Info.plist LSUIElement, ad-hoc 서명)
```
macOS 13+, Swift 5.9+. 서명/공증은 ad-hoc(`codesign -s -`) — 직접 빌드해 쓰는 로컬 유틸.

## 알려진 한계
- 전역 전환은 새 `claude` 세션부터 적용(메뉴 헤더에 명시)
- Strata는 공식 문서 없음 → 인스턴스 JSON/포트 실측에 의존, 제품 업데이트로 포맷이 바뀌면 감지 실패 가능
- LM Studio = Bionic.app (`~/.lmstudio/bin/lms`)
- 복원/클립보드 완료 문구가 VM처럼 영어 환경에서도 한국어로 노출되는 항목 있음(다국어 정리 필요)
- 세션형 프로필(`--settings`)은 전역 설정 env와 병합되지 않고 덮어씀(claude 동작에 의존)
