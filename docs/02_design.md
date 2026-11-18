# 2. 기획 · 설계

전제: `01_findings.md`의 실측 결과(두 백엔드 모두 `/v1/messages` 동작, 스위칭 지점 = `~/.claude/settings.json` 의 `env`)

## 2.1 목표

- 메뉴바(트레이) 상주 앱. 아이콘 하나로 **현재 Claude Code가 어느 API를 쓰는지** 보이게 한다.
- 우클릭(또는 클릭) 컨텍스트 메뉴에서 **공식 Claude API ↔ LM Studio(Bionic) ↔ Strata** 로 즉시 전환.
- 전환 실패를 줄이기 위해 포트·키·모델은 **직접 입력 없이 자동 감지**.
- 언제든 원래대로 되돌릴 수 있다(백업·복원, 재로그인 불필요).

비목표(우선): 프록시/캐시/토큰 통계, 창(Windows) 지원, 팀 배포.

## 2.2 핵심 개념: 프로파일

전환_UNIT은 "프로파일" = settings.json `env`에 넣을 환경변수 세트.

| 프로파일 | env 내용 |
|---|---|
| **공식 API** | 위 4개 키를 **삭제** (키체인 자격증명 사용) |
| **LM Studio(Bionic)** | `ANTHROPIC_BASE_URL=http://127.0.0.1:<실측포트>`<br>`ANTHROPIC_AUTH_TOKEN=lmstudio`<br>`ANTHROPIC_MODEL=<선택모델>`<br>`CLAUDE_CODE_ATTRIBUTION_HEADER=0` |
| **Strata** | `ANTHROPIC_BASE_URL=http://127.0.0.1:<실측포트>`<br>`ANTHROPIC_AUTH_TOKEN=<native-instances의 api_key>`<br>`ANTHROPIC_MODEL=<실측모델 id>` |
| 사용자 커스텀 | 추후 (예: 원격 rig의 LM Link, 다른 Mac mini) |

- 다른 env 키(예: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`)와 settings의 나머지 항목은 **건드리지 않는다**(merge-only).
- `~/.claude/settings.json` 실례(현재) → 전환 후 기대 diff:

```jsonc
// before
"env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" }
// after (Strata)
"env": {
  "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
  "ANTHROPIC_BASE_URL": "http://127.0.0.1:18500",
  "ANTHROPIC_AUTH_TOKEN": "<strata api_key>",
  "ANTHROPIC_MODEL": "iq3_s"
}
```

## 2.3 UI (메뉴바)

아이콘: 문자/심볼 + 색 배지 (예: 공식=회색, LM Studio=초록, Strata=주황) + 로딩 중 스피너.

메뉴 구성(한국어):

```
현재: Strata · iq3_s · 131k 컨텍스트        ● (자동감지)
────────────────────────────────
공식 Claude API로 전환
LM Studio (Bionic)로 전환
Strata로 전환
────────────────────────────────
모델 ▸   (GET /v1/models 실시간: iq3_s, qwen/qwen3.8-27b, …)
서버 ▸   LM Studio 서버 시작/중지 · Strata 상태 확인
────────────────────────────────
지금 상태 점검            (헬스체크: /v1/models + 최소 /v1/messages)
새 세션부터 적용됩니다 — 안내
settings.json 열기
백업 복원 ▸ (최근 5회)
로그 열기
────────────────────────────────
설정…  ·  종료
```

핵심 UX 원칙
- 전환 후 토스트: "적용 완료. **새로 실행하는 claude 세션**부터 적용됩니다."
- 서버가 꺼져 있으면 전환 실패 대신 "서버 시작" 1단계 자동 실행 → 실패 시 원인 표시(port 불일치/미설치).
- 시크릿은 메뉴/로그에 마스킹(`50a2…ec0e`).

## 2.4 아키텍처

```
MenuBarApp (SwiftUI MenuBarExtra)
   └─ SwitchEngine (핵심 로직, CLI로도 재사용)
        ├─ BackendDiscovery   LM Studio: lms server status + 포트 프로빙(설정값 불신)
        │                     Strata: ~/.strata/data/native-instances/*.json → host/port/api_key/model
        ├─ ModelCatalog       GET /v1/models (+ n_ctx 노출)
        ├─ HealthCheck        /v1/models, 최소 /v1/messages 왕복
        ├─ SettingsEditor     settings.json read→merge→validate→백업→원자적 교체→재검증
        ├─ ProfileStore       앱 설정(프로파일/모델 우선순위) → ~/Library/Application Support/…(로컬 디스크)
        └─ AuditLog           전환 기록(누가/언제/무엇→무엇, 이전 백업 경로)
```

설정 쓰기 안전 절차 (중요 — Claude Code도 같은 파일을 쓴다)
1. `~/.claude/settings.json` 읽기 → JSON 파싱 실패 시 **중단**(파일에 손대지 않음)
2. 백업: `~/.claude/backups/switch-<timestamp>.settings.json` (최근 5개 유지)
3. `env`의 4개 관리 키만 추가/갱신/삭제, 그 외 바이트 단위 보존을 위해 JSON 재직렬화 대신 **키 단위 편집** 권장
4. tmp에 쓰고 `rename`으로 교체(같은 파일시스템 = 로컬 home이므로 가능)
5. 재읽어 기대값 확인 → 실패 시 자동 롤백 + 로그

주의: 이 프로젝트 폴더 `~/LOCAL/...` 은 **SMB 마운트**(rename 미지원, 한글 파일명 NFD 분해). 앱 설정·백업은 로컬(`~/Library`)에 두고, 소스코드는 로컬 디스크에서 빌드 권장.

## 2.5 기술 스택

- **권장: Swift + SwiftUI `MenuBarExtra`** (macOS 13+). 의존성 없음, 메모리 ~20MB, 상주용 최적. `swift build`(SPM) 또는 Xcode 프로젝트.
- 대안 A: Python + `rumps` → 개발 속도 빠름, 상주비용 큼(인터프리터)·packaging 번거로움.
- 대안 B: Electron/Tauri → 트레이+메뉴는 가능하나 이 용도엔 과중.

## 2.6 개발 단계 (MVP 먼저, 각 단계 끝에서 실사용 검증)

| 단계 | 산출물 | 완료 기준 |
|---|---|---|
| P0 검증 CLI | `switch-profile <official\|lmstudio\|strata>` (Swift 또는 Python) | 실제 `claude` 새 세션이 Strata/LM Studio `/v1/messages`로 응답, 공식 복귀 확인 |
| P1 메뉴바 MVP | 아이콘 + 3개 전환 + 상태 표시 + 헬스체크 | 우클릭 메뉴로 3방향 전환, 앱 재시작 후 상태 유지 |
| P2 실사용 보강 | 모델 선택, 서버 시작/중지, 백업 복원, 로그, 한국어/영어 로케일, 로그인 시 자동시작 | 서버 꺼진 상태에서도 전환 성공률 100% (자동 기동) |
| P3 배포·견고화 | 여러 Strata 인스턴스·LM Link(원격) 프로파일, ad-hoc 서명, 설치 스크립트 | 재부팅 후에도 정상 동작 |

## 2.7 테스트/수락 기준

1. 공식→Strata: `claude -p "hi"`가 Strata 로그에 잡히고 응답, Strata 종료 시 명확한 오류.
2. Strata→LM Studio: 다른 모델로 전환 후 응답, `n_ctx` 부족 경고 노출.
3. →공식 복귀: env 4키 삭제, 로그인 그대로 유지(`Claude Safe Storage`健재), 동작 확인.
4. 동시성: 전환 직전 Claude Code가 settings.json을 수정해도 사용자 설정(`hooks`, `permissions`) 보존.
5. 파싱 실패/권한 오류 시 파일 원본 그대로 + 오류 메시지.

## 2.8 위험과 대응

| 위험 | 대응 |
|---|---|
| settings.json 동시 수정 유실 | 잠금(flock) + 백업 + 원자적 교체 + 롤백 |
| LM Studio 포트 설정≠실제(8234 vs 1234) | `lms server status`+포트 프로빙, 설정값은 참고만 |
| Strata 인스턴스/포트 변경 | json 재파싱, 다중 인스턴스 시 선택 UI |
| `ANTHROPIC_API_KEY` 잔존으로 우선순위 충돌 | 전환 시 해당 키도 env에서 정리 |
| 세션에 이미 반영된 env | 메뉴에 "새 세션부터 적용" 명시, 필요 시 "새 터미널 열기" 보조 |
| 앱이 자기 자신을 전환(Strata로 실행 중인 도구) | 앱은 Claude API를 쓰지 않으므로 무관 — 문서에 명시 |

## 2.9 확정 결정 (2026-11-15 사용자 선택)

1. **스택: Swift + SwiftUI `MenuBarExtra`** (macOS 13+, SPM 빌드)
2. **적용 범위: 전역 `settings.json` + 세션형 런처 둘 다**
3. **서버 자동 기동 + 수동 토글 둘 다**
4. **모델: `/v1/models` 감지 목록에서 선택** (컨텍스트 길이 표시)

## 2.10 세션형 런처 상세

`claude --settings <file|json>` 플래그 존재 확인됨(도움말 실측). 동작:

- 앱이 프로파일별 파일 생성: `~/.claude/profiles/<profile>.settings.json`
  (전역 settings와 같은 env 세트가 그 파일 안에만 존재)
- 메뉴 항목 "이 프로파일로 새 Claude 세션 실행"
  - 기본: 명령어 클립보드 복사 → `claude --settings ~/.claude/profiles/strata.settings.json`
  - 보조: 설정에서 고르면 터미널(Doghoodie 등) 탭으로 바로 실행
- 전역 전환과 독립 → "전역=공식, 이 세션=Strata" 병행 가능

## 2.11 다음 할 일 (P0)

1. Swift SPM 골격 + `SwitchEngine` CLI (`switch-profile official|lmstudio|strata`, `--list`, `--status`)
2. P0 실측 시나리오 3종 (2.7의 1~3번) 통과 확인
3. 통과 후 P1 메뉴바 UI 착수
