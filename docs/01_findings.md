# 1. 조사 결과 (작업 가능 여부)

조사: 2026-11-15 · Mac mini · macOS · Claude Code 2.1.325 (`/opt/homebrew/bin/claude`)

## 결론

**가능하다.** 두 로컬 백엔드 모두 이 기계에서 실제로 `POST /v1/messages`(Anthropic 호환) 응답을 반환하는 것을 확인했고,
스위칭 지점도 명확하다: `~/.claude/settings.json` 의 `env` 블록.
트레이(메뉴바) 아이콘 + 우클릭 컨텍스트 메뉴는 macOS 네이티브 `MenuBarExtra`로 문제없이 구현된다.

---

## 2. 스위칭 지점 (핵심)

Claude Code는 다음 환경변수로 요청 대상을 바꾼다.

| 변수 | 역할 |
|---|---|
| `ANTHROPIC_BASE_URL` | API 루트 주소. Claude Code가 `/v1/messages`를 자체적으로 붙인다 → 백엔드별 `/v1` 표기 차이 주의 |
| `ANTHROPIC_AUTH_TOKEN` | Bearer 토큰 (로컬은 더미/자체 키) |
| `ANTHROPIC_API_KEY` | 남아 있으면 우선순위 충돌 → 전환 시 정리 대상 |
| `ANTHROPIC_MODEL` | 모델 지정 |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | LM Studio 문서에서 `0` 권장 |

반영 방법 후보:

1. **`~/.claude/settings.json` 의 `env`** ← 이 기계에 이미 `env` 블록 존재 → **권장 (기본)**
2. `claude --settings <file>` 플래그 (세션 단위, 부가 기능)
3. 셸 프로파일 export — 현재 이 기계 셸에는 `ANTHROPIC_*` 변수 없음 (공식 API 상태)

주의: `env`는 **새로 시작하는 세션**에만 적용된다. 이미 실행 중인 세션은 유지된다(UI에 명시).

---

## 3. 백엔드 A — LM Studio / Bionic (실측 확인)

- 앱: `/Applications/Bionic.app` — `~/.lmstudio/.internal/app-install-location.json` 이 Bionic.app을 가리킴
- CLI: `~/.lmstudio/bin/lms` — `lms server status/start`, `lms ls` 동작 확인 (모델 11개 / 282.33 GB)
- 서버 실측: `lms server status` → **port 1234** (Bionic PID LISTEN)
  - 그런데 `~/.lmstudio/.internal/http-server-config.json`에는 `"port": 8234`로 저장됨
  - ⇒ **포트 하드코딩 금지, 실측 필수** (설정값과 실제 청취 포트가 불일치)
- 인증: Require Authentication 꺼짐 → `x-api-key: lmstudio` 더미로 통과
- 실측 (port 1234):

```
curl -X POST http://127.0.0.1:1234/v1/messages \
  -H 'anthropic-version: 2023-06-01' -H 'x-api-key: lmstudio' -H 'content-type: application/json' \
  -d '{"model":"qwen/qwen3.8-27b","max_tokens":8,"messages":[{"role":"user","content":"say OK"}]}'
→ {"type":"message","role":"assistant","content":[{"type":"text","text":"OK"}],"model":"qwen/qwen3.8-27b",…}
```

- LM Studio 문서 권장값: `ANTHROPIC_BASE_URL=http://localhost:1234`, `ANTHROPIC_AUTH_TOKEN=lmstudio`,
  `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, 컨텍스트 25k 이상 권장
- 모델 목록: `GET /v1/models` 실시간 조회

## 4. 백엔드 B — Strata (실측 확인)

- 앱: `/Applications/Strata.app` (`ai.strata.desktop`, 0.2.13)
- 서빙: `serve.server --engine strata --host 127.0.0.1 --port 18500`
- 자동감지 소스: `~/.strata/data/native-instances/<uuid>.json` → `host=127.0.0.1`, `port=18500`, `api_key=…`, `model_name=qwen3.8-flas…`
- 인증: **키 필수**. 키 없으면 `{"error":{"type":"authentication_error","message":"missing or wrong API key"}}`
- 실측 (port 18500, `x-api-key`):

```
GET  http://127.0.0.1:18500/v1/models
→ {"data":[{"id":"qwen3.8-flash-next-iq3_s","aliases":["iq3_s"],"meta":{"n_ctx":131072},…}]}

POST http://127.0.0.1:18500/v1/messages   (x-api-key: 위 api_key)
→ {"type":"message","role":"assistant","content":[{"type":"thinking",…}],"model":"qwen3.8-flash-next-iq3_s",…}
```

- Strata 앱 내 안내문(한글 카탈로그에서 실추출): “Anthropic 앱은 /v1/messages를 스스로 붙이므로 이 주소 끝에는 /v1이 없습니다.
  Claude Code에서는 ANTHROPIC_BASE_URL에 이 주소를 넣으세요.”
  ⇒ `ANTHROPIC_BASE_URL=http://127.0.0.1:18500`
- 모델 id: `qwen3.8-flash-next-iq3_s` (별칭 `iq3_s`), n_ctx 131072

## 5. 공식 API 복귀 조건

- `env`에서 `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, `CLAUDE_CODE_ATTRIBUTION_HEADER` 제거
- 로그인 자격증명은 키체인에 존재 확인: `Claude Safe Storage` / `Claude Key` → **재로그인 없이 복귀 가능**
  (`~/.claude/.credentials.json` 없음 → 키체인 방식)

## 6. 위험 / 주의

1. **settings.json 동시 쓰기**: Claude Code도 settings.json을 수정한다(`~/.claude/.settings.lease` 렌트 파일 존재).
   → read-modify-write + 원자적 교체 + 백업 + 재시도 필요.
2. **설정 다층 구조**: 프로젝트 `.claude/settings.local.json`, managed settings, `--settings`가 우선순위 없음/있음 → 전환 후 실제 반영 확인 절차 필요.
3. **포트·키 변동**: Strata 포트는 인스턴스별, LM Studio는 설정≠실제 → 항상 실시간 감지.
4. **시크릿**: Strata `api_key` 평문 저장 → 읽어서 쓰되 앱 저장소/로그에는 마스킹.
5. **서버 미기동**: 전환 전 헬스체크(`GET /v1/models`), 필요 시 자동 기동(`lms server start`).
6. **컨텍스트 크기**: 로컬 모델 n_ctx를 메뉴/경고로 노출 (Claude Code는 대량 컨텍스트 사용).

## 7. 참조

- LM Studio: https://lmstudio.ai/docs/integrations/claude-code · https://lmstudio.ai/docs/developer/anthropic-compat/messages
- Claude Code: https://code.claude.com/docs/en/llm-gateway-connect · https://code.claude.com/docs/en/llm-gateway-protocol
- 환경변수 해설: https://www.requesty.ai/blog/claude-code-environment-variables-anthropic-base-url-auth-token
- Strata: 공개 문서 없음 → 앱 내 Serving 패널 + `~/.strata/data/native-instances/*.json` 실측이 근거
