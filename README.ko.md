# Claude API Switch

[English](README.md) | [한국어](README.ko.md)

Claude Code가 붙는 API 대상을 메뉴바에서 전환하는 macOS 앱이다. 공식 Anthropic API,
LM Studio, Strata 엔진, 그리고 사용자가 선언한 Anthropic 호환 엔드포인트 네 곳 사이를
오가며, 컨텍스트 창은 엔진이 실제로 RAM에 상주시킬 수 있는 분량에 맞춘다.

전환 도구 이상인 부분은 여기 있다. 엔진 자기 로그에서 빈 RAM에 들어가는 KV 캐시 분량과
콜드 프롬프트 재읽기 속도를 측정해, 그 두 값에서 나오는 컨텍스트 창을 settings.json에 쓴다.
Claude Code는 두 측정을 하지 않는다. 알지 못하는 모델 id에는 컨텍스트 창을 어림하고
그 어림을 강제한다.

## 무엇을 고치나

| 증상 | 원인 | 이 앱의 동작 |
| --- | --- | --- |
| 전환했는데 그대로다 | Claude Code는 API 대상을 `~/.claude/settings.json` 의 `env` 블록에서 읽고, 남은 `ANTHROPIC_API_KEY` 가 우선순위를 가져간다 | 전환은 이 앱이 소유한 키(`MANAGED_KEYS` 열한 개)만 쓰고 `ANTHROPIC_API_KEY` 는 언제나 지운다 |
| 로컬 세션이 `prompt too long` 으로 죽는다 | Claude Code는 모르는 모델 id의 컨텍스트 창을 어림하고 그 값을 강제한다 | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 를 엔드포인트가 보고한 `meta.n_ctx` 로 지정한다 |
| 얼마 후 부쩍 느려진다 | 세션이 엔진이 상주시킬 수 있는 KV 캐시를 넘어, 대화가 추방되고 다음 요청마다 프롬프트 전체를 콜드로 재읽는다 | auto-compact 창을 실측 `bytes/token` 과 실측 prefill 속도에서 계산한다 |
| hooks · permissions · model 설정을 잃었다 | 설정 편집기가 파일 전체를 다시 썼다 | `env` 블록만 건드린다. 아래에서 실행으로 확인했다 |
| 이 세션이 로컬 모델인지 화면에 없다 | 표시하는 곳이 없다 | 메뉴바 아이콘, 그리고 세션 안에 Claude Code의 실측 used/window 줄 |

## 바로 쓰기

macOS 13+, Swift 5.9+, Claude Code 설치 필요.

```sh
zsh dist/build_app.sh          # 릴리스 빌드 + .app 번들 + ad-hoc 서명
zsh install.sh                 # /Applications 에 배치하고 실행
```

같은 바이너리가 CLI이기도 하다: `claude-switch status`. `.app` 번들 안에서는
`ClaudeAPISwitch.app/Contents/MacOS/claude-switch` 에 있다.

Release에는 미리 지은 `ClaudeAPISwitch.app.zip` 이 붙는다. 이 번들은 **ad-hoc 서명**이고
Developer ID 서명과 공증이 없으므로, 다운로드본은 `install.sh` 를 돌려 격리 플래트를
지우기까지 Gatekeeper가 막는다. 소스에서 직접 빌드하면 이 단계가 없다.

## 전환하면 무엇이 바뀌나

전환이 건드리는 곳은 한 곳이다: `~/.claude/settings.json` 의 `env` 블록.

| 키 | 이 앱이 소유 | 로컬 엔드포인트로 전환 | 공식 API로 복귀 |
| --- | --- | --- | --- |
| `ANTHROPIC_BASE_URL` | 예 | 엔드포인트 주소, 끝의 `/v1` 없음 | 삭제 |
| `ANTHROPIC_AUTH_TOKEN` | 예 | 엔드포인트 키(`x-api-key` / Bearer) | 삭제 |
| `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` | 예 | 고른 모델 id | 삭제 |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | 예 | `0` (LM Studio 공식 권장값) | 삭제 |
| `ANTHROPIC_API_KEY` | 예, 삭제만 | 삭제(우선순위를 빼앗기지 않기 위해) | 삭제 |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 예 | 모델의 실제 `n_ctx` | 삭제 |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | 예, `--hard` 일 때만 | 계산한 창을 env 형태로 | 삭제 |
| 사용자가 추가한 `env` 키와 최상위 키 전부 | 아니오 | 그대로 | 그대로 |

2026-11-18 에 격리 config 디렉터리와 픽스처 사용자 파일로 다시 확인한 결과:

```
top-level keys: ['env', 'hooks', 'model', 'permissions']
env keys: ['ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
           'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_MODEL',
           'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_ATTRIBUTION_HEADER',
           'CLAUDE_CODE_MAX_CONTEXT_TOKENS', 'MYPRESERVED']
```

`MYPRESERVED` 는 픽스처가 넣은 사용자 `env` 키다. 살아 남는다.

전환은 **새로 시작하는** `claude` 프로세스에만 적용된다. 이미 실행 중인 세션은 시작할 때의
환경을 유지한다. 메뉴 머리줄이 그 사실을 적는다.

## 컨텍스트 정책

모델을 실은 Mac Studio에서 `claude-switch policy strata` 를 돌린 출력:

```
strata: window 56k / model 524k · resident 206k/4 slots · 17kB/tok · 194 tok/s cold · ×2  [cold re-read 300s @ 194 tok/s, resident 206k / 2, model window]
  publish: settings autoCompactWindow=56000 + env CLAUDE_CODE_MAX_CONTEXT_TOKENS=524288
  ⚠ engine evictions=75 since start, parked=1/4
  ⚠ model window exceeds resident budget: 524k > 206k
```

위의 수는 전부 설정값이 아니라 엔진에서 읽었다.

| 양 | 출처 | 이 회의의 값 |
| --- | --- | --- |
| 빈 RAM이 주는 KV 캐시 한도와 파킹 대화 수 | `conversation cache sized from the free RAM: N MiB for up to M parked` | 3584 MiB, 슬롯 4개 |
| 토큰당 KV 바이트 | `snapshot_bytes` 증가량 / 파킹 토큰 증가량, 중앙값 | 17 kB/token |
| 콜드 prefill 속도 | `+ N read in M ms (X tok/s)`, 중앙값 | 194 tok/s |
| 상주 예산 | `cap × 1 MiB ÷ bytesPerToken` | 206k 토큰 |
| 모델 창 | `GET /v1/models` 의 `meta.n_ctx` | 524288 |

쓰는 창은 아래 세 갈래 중 가장 작은 값이고, 4000 눈금으로 내림, 하한 32000, 모델 창을 넘지 않는다.

| 경계 | 기본값 | 이 회의 |
| --- | --- | --- |
| 콜드 재읽기 허용 시간: `coldPrefillSeconds × tok/s` | 300초 | 58.2k |
| 상주 KV 예산의 세션당 몫: `budget / sessions` | 세션 2개 | 103k |
| 모델 창에서 왕복 여유를 뺀 값: `n_ctx − 8000` | - | 516k |

그래서 이 기계에서는 56000 이 채택되고, 옆에 채택 근거가 적힌다(`cold re-read 300s @ 194 tok/s`).
56000 토큰을 194 tok/s 로 재읽는 시간이 약 4.8분이고, 그것이 추방 뒤 콜드 재읽기 한 번의 비용이다.

입력을 덮어써도 계산은 정직하게 남는다:

```sh
claude-switch policy strata --sessions 3 --wait 120 --window auto   # 창은 쓰지 않고 경고만
claude-switch policy custom --window 120k --hard                    # env 형태 고정(/autocompact 보다 우선)
claude-switch policy --json                                         # 백엔드별 기계 판독 출력
```

지어내지 않고 거부하는 경우:

| 상황 | 동작 |
| --- | --- |
| `GET /v1/models` 가 `n_ctx` 를 보고하지 않음 | `model window unknown` 경고, 창을 지정하지 않음 |
| 엔진 로그에 conversation cache 줄이 없음 | `engine residency not measured` 경고, 모델 창 경계만 적용 |
| 사용자 `settings.json` 에 `autoCompactEnabled: false` | 창을 쓰지 않음: 세션을 막는 장치가 없는데 창 값을 쓰면 거짓이 된다 |
| 사용자의 `autoCompactWindow` 가 이미 더 좁음 | 그대로 두고 근거 줄에 그 사실을 적음 |
| 엔드포인트가 다른 기계에 있음 | 상주 예산 없음: 원격 엔진의 RAM 한도를 여기서 읽을 방법이 없다 |

residency 줄은 Strata 엔진 로그에서 산다. LM Studio와 루프백 커스텀 엔드포인트는
모델 창 경계와 콜드 재읽기 경계만 받고 상주 예산 경고를 받지 않는다. 그 두 엔진은
근거가 되는 측정을 내놓지 않는다.

## 세션 안의 경고

세션 프로파일이 Claude Code의 `statusLine` 명령으로 `claude-switch statusline` 을 넣는다.
Claude Code가 세션 JSON을 stdin으로 보내고, 앱은 그 실측 값으로 한 줄을 출력한다.
종료 코드는 항상 0 이어서 status line이 세션을 멈추지 않는다. 이미 있던 사용자의
`statusLine` 명령은 대체하지 않고 앞에 이어 붙인다.

```
echo-model 52k/66k (79%)
```

상주 예산을 넘으면 `⛔ resident 141% of budget: /compact now`, 80퍼센트에서
`⚠ resident 84% of 103k` 가 된다.

`claude-switch watch` 는 보이는 세션 전부의 같은 수치를 낸다. 출처는 두 갈래다:
status line이 남기는 기록, 그리고 프로파일로 시작하지 않은 세션을 찾기 위한
`~/.claude/projects/*/*.jsonl` 뒷부분 스캔.

```
engine: cap 3584 MiB, slots 4, 17 kB/token, cold 193 tok/s
resident budget: 206k tokens (parked 1 conversations, evictions 75)
  switch_claude_code_api  145k/524k budget 103k (141%) ⛔ /compact now  iq3_s
```

## 세션 프로파일: 한 터미널만, 전역 설정은 그대로

```
$ claude-switch profile custom
/tmp/ccdocs/profiles/custom.json
claude --settings "/tmp/ccdocs/profiles/custom.json"
  window 56k / model 66k · ×2  (model window)
  ⚠ engine residency not measured: no conversation-cache lines in the engine log
```

파일은 완전한 Claude Code settings 파일이다(`env`, `autoCompactWindow`, `statusLine`,
그리고 어떤 값을 썼는지 남기는 `_ccswitch` 블록). 엔드포인트 키가 들어가므로 파일
모드는 rename 전에 임시 파일에 지정한다:

```
-rw-------  1 uhd  wheel  917 /tmp/ccdocs/profiles/custom.json
```

전역 전환과 세션 범위는 서로 독립이다. 전역은 공식 API에 두고 한 터미널만 로컬 모델로
돌릴 수 있다.

## 엔드포인트 선언

`POST /v1/messages` 를 Anthropic 응답 꼴로 받는 것이면 무엇이든 된다: llama.cpp 서버,
다른 기계의 LM Link, LiteLLM, 사내 게이트웨이, 시험 픽스처.

```
$ claude-switch custom set --base http://127.0.0.1:19423 --token demokey1234567890 --model echo-model
declared: 127.0.0.1 http://127.0.0.1:19423
serving: 1 models
  echo-model n_ctx=65536
$ claude-switch custom show
base: http://127.0.0.1:19423
token: demo…7890
model: echo-model
```

끝의 `/v1` 은 지운다. Claude Code가 `/v1/messages` 를 스스로 붙이기 때문이다. 키는 이 앱의
config에 저장되고 화면에는 마스킹된 꼴로만 나온다. 메뉴에도 같은 항목이 있다:
**Set custom endpoint…**(커스텀 엔드포인트 설정). 직접 선언한 엔드포인트도 감지는 실시간으로
한다: `GET /v1/models` 가 응답 여부를 정하고, 그 응답의 `meta.n_ctx` 가 모델 창을 정한다.
이 앱이 시작할 방법을 모르는 서버는 시작하려 하지 않는다.

## 메뉴

| 항목 | 동작 |
| --- | --- |
| 머리줄 | 현재 백엔드·모델·주소, `새로 시작하는 세션부터 적용됩니다`, 마지막 작업 결과, 토큰 부하 80퍼센트 경고 |
| Official Claude API / LM Studio (Bionic) / Strata / Custom endpoint | 전환. 현재 항목에 체크, 응답하지 않는 엔드포인트에 `(stopped)` |
| Set custom endpoint…, Remove custom endpoint | 주소·키·모델 id 입력 창 |
| Model | 백엔드별로 감지한 모델을 `n_ctx` 와 함께 묶어 표시 |
| Context / compaction | 백엔드별 계산 창과 근거, 경고, 실시간 토큰 부하, 스위치 세 개(세션 내 경고, 메뉴바 토큰 표시, 창을 Claude Code에 맡김), `Rewrite session profiles now` |
| Server | LM Studio 서버 시작/중지(`lms`), Strata 앱 실행 |
| Check status now | `GET /v1/models` 뒤에 실제 `POST /v1/messages` 왕복 |
| Copy new-session command | 백엔드별로 `claude --settings ~/.claude/profiles/<kind>.json` 을 클립보드에 |
| Restore backup | 디스크에 남은 20개 중 최근 10개 |
| Open settings.json, Open log, Start at login(`SMAppService`), Quit | |

메뉴바 자리는 `switch.2` SF Symbol이고 상태 점이 뒤따른다. 상태 점검이 도는 동안에는
`hourglass` 로 바뀐다.

## CLI

`claude-switch help` 출력:

```
  status [--json]                  current backend + detection
  list                             supported backends
  switch <kind> [--model id]       global switch (official|lmstudio|strata|custom)
  custom set --base URL [--token K] [--model id] [--title NAME]
                                   declare one Anthropic-compatible endpoint
  custom show | custom clear       print / remove the declared endpoint
  models <kind>                    detected models (n_ctx included)
  check <kind>                     POST /v1/messages round trip
  profile <kind> [--model id]      write a session profile + print its command
  policy [kind] [flags] [--json]   auto-compact window / resident budget
                                   (--window 120k|auto, --sessions N, --wait S, --hard/--soft)
  watch [--minutes N] [--json]     per-session context token load
  statusline                       (claude statusLine hook: stdin JSON -> one line)
  backups                          backup list
  restore <file|latest>            restore a backup
```

`CLAUDE_CONFIG_DIR` 는 Claude Code가 따르는 것과 같은 규칙으로 따른다. 시험 절차가
실제 `~/.claude` 대신 픽스처를 상대로 도는 방법이 이것이다.

백엔드별 감지:

| 백엔드 | 찾는 방법 |
| --- | --- |
| official | 키체인 항목 `Claude Safe Storage` 유무로 로그인 상태를 표시(읽기 전용) |
| LM Studio | 포트는 `lms server status` → `~/.lmstudio/.internal/http-server-config.json` → 1234 순서. 이 기계에서는 저장된 포트(8234)와 실제 청취 포트(1234)가 어긋나 있어서 저장값은 참고만 한다. 기본 키 `lmstudio` |
| Strata | `~/.strata/data/native-instances/*.json` 에서 host, port, 키, 모델 id, 엔진 로그 경로를 읽는다. 키가 필수: 없으면 서버가 `authentication_error` 로 답한다 |
| custom | `custom set` 이나 메뉴로 선언한 값을 실시간으로 프로브 |

## settings.json을 잃지 않고 쓰기

Claude Code도 같은 파일을 쓰므로 편집기가 방어적이다(`SettingsEditor.swift`).

| 순서 | 구현 |
| --- | --- |
| 1. 잠금 | `~/.claude/.ccswitch.lock` 에 `flock` 배타 잠금 |
| 2. 파싱 실패면 중단 | 파싱되지 않는 파일은 거부하고 고치지 않는다 |
| 3. 병합 | `MANAGED_KEYS` 에 있는 `env` 키만 더하거나 지운다 |
| 4. 경합 재확인 | Claude Code가 그 사이에 썼을 수 있어 mtime을 다시 보고 최대 3번 시도 |
| 5. 백업 | `~/Library/Application Support/ClaudeAPISwitch/backups` 에 복사, 최근 20개 유지 |
| 6. 원자적 교체 | 같은 디렉터리의 임시 파일에 쓰고 `fsync` 뒤 POSIX `rename` |
| 7. 재읽어 검증 | 있어야 할 키와 없어야 할 키를 확인하고 어긋나면 백업을 되돌린 뒤 예외 |

파싱되지 않는 파일을 상대로 돌린 방어:

```
$ claude-switch switch custom   # settings.json holds truncated JSON
settings.json is not valid JSON: refusing to modify
(exit code 1)

settings.json md5: before=93e6968bdb19c6fb453d971ef4f34621 after=93e6968bdb19c6fb453d971ef4f34621
```

## 시크릿

| 규칙 | 코드 위치 |
| --- | --- |
| 엔드포인트 키는 동작에 필요한 두 파일에만 들어간다: settings.json의 `env` 블록, 세션 프로파일(`0600`) | `envSet`, `writeProfileFile` |
| 이 앱의 로그와 config에는 평문으로 남기지 않는다: `logEvent` 는 키 이름에 `token` 이나 `key` 가 들어간 필드를 마스킹한다 | `Core.swift` |
| 메뉴와 CLI는 `first4…last4`, 8자 이하는 `****` 로 출력한다 | `maskSecret` |
| 키체인은 로그인 상태를 알려고 한 번 읽기만 하고 쓰지 않는다 | `check official`, `gatherStatus` |

## 알려진 한계

- macOS 전용이다. 메뉴바는 AppKit `NSStatusItem` 이고, CLI 쪽은 GUI 없이도 되지만 macOS 보조 도구에 기대는 부분이 있다(`security`, `lms`, `SMAppService`).
- 전환은 새 `claude` 프로세스에만 적용된다. 이미 도는 프로세스의 환경을 바꿀 방법은 없다.
- 상주 KV 예산은 Strata 엔진 로그 규식을 파싱해 얻는다. 다른 엔진에는 모델 창 경계와 콜드 재읽기 경계만 적용하고, 어림 대신 `engine residency not measured` 라고 적는다.
- 컨텍스트 창 진실은 엔드포인트가 `meta.n_ctx` 를 보고하는지에 달려 있다. 보고하지 않는 엔드포인트는 경고하고 창을 쓰지 않는다.
- 세션 프로파일은 그 세션의 전역 `env` 를 대체한다(`claude --settings` 동작). 병합되지 않는다.
- `.app` 번들은 ad-hoc 서명이다. Gatekeeper가 막고, 공증은 없다.
- Strata 인스턴스 JSON 규식은 디스크의 파일에서 역공학한 것이다. 앱 갱신으로 규식이 바뀌면 감지가 실패한다.

## 시험

`TESTING.md` 에 무엇을 어디서 돌렸는지 적었다. Mac Studio에서 실 `settings.json` 을
상대로(백업 → 전환 → 로컬 모델 실응답 → 복원), 클린 macOS VM에서 가짜 `lms` 와 에코
픽스처를 상대로, 그리고 GUI는 메뉴 클릭으로 조작해 확인했다. `tests/echo_server.py` 는
`TESTING.md`의 절차가 쓰는 Anthropic 호환 픽스처로, 실제 모델 없이 전환만 미리 시험해 볼 가장 빠른 길이다.

## 문서

| 파일 | 내용 |
| --- | --- |
| `docs/01_findings.md` | 설계가 기대는 실측. Claude Code가 API 대상을 어디서 읽는지, 각 로컬 서버가 실제로 무엇에 응답하는지, 그것을 입증한 curl 세션 |
| `docs/02_design.md` | 구조, 쓰기 안전 절차, 내린 결정, 단계 계획 |
| `TESTING.md` | 실행한 시험 기록 |
| `SECURITY.md` | 바이너리가 건드리는 자원과 시크릿 처리 |

## 라이선스

MIT. [LICENSE](LICENSE) 참조.
