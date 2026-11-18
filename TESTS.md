# 시험 기록 (2026-11-15)

두 곳에서 검증: ① Mac Studio(실환경, 실 settings.json은 백업→전환→복원 절차로만 접촉)
② 시험 VM PoieveServer(macOS 27.0.1 arm64, 클린 — LM Studio/Strata/claude 없음, 가짜 픽스처로 대체).

## A. Mac Studio — CLI(P0)
1. **env 추종 증명(에코 서버)**: `CLAUDE_CONFIG_DIR=/tmp/ccswitch-e2e` 격리 + 에코 서버(19311)
   → `claude -p`가 `POST /v1/messages`를 에코 서버로 보냄(모델 echo-model, Bearer lmstudio),
   응답 `ECHO_OK echo-model`. settings.json env가 실로 적용됨을 확인.
2. **감지(실환경)**: current official + LM Studio 1234 serving(모델 12) + Strata 18500 serving
   (qwen3.8-flash-next-iq3_s / iq3_s, n_ctx 131072).
3. **병합 전용**: 실 settings.json 사본으로 strata 전환 → env 외 최상위 키 diff 없음(hooks·model·
   permissions 보존), 공식 복귀 시 관리 키만 삭제(env = CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS 1개).
4. **실 settings.json 왕복**: `switch strata --model iq3_s` → `claude -p` 응답 `REAL_SWITCH_STRATA_OK`
   (로컬 모델 실응답) → `switch official` → 원본과 구조적 동일(non-env diff NONE). 최종 상태=공식.
5. **방어**: 깨진 JSON 거부(파일 무변경, rc=1), 백업 생성/`restore latest`, flock+mtime 재확인 코드,
   로그 마스킹. `check lmstudio`는 첫 버전이 오디오 모델에 막혀 타임아웃 → 모델 최대 4개 순차
   프로브로 수정 후 OK.
6. 참고 사건: 시험 중 Strata 서버(하네스)가 재시작되어 18500을 향하던 기존 세션들이
   ECONNREFUSED를 만남(앱 원인 아님). 서버 복구 후 사용자 세션 정상 재개. 전환 창은 23:24–23:25로
   짧았고 전환 로그로 전부 추적됨.

## B. VM PoieveServer — CLI 전矩阵(가짜 백엔드)
픽스처: `~/.strata/data/native-instances/vm.json`(18500) + 에코 서버, 가짜 `lms`(status/start/stop) +
에코 서버(1234). 실 LM Studio/Strata 설치 없이도 감지·자동기동·중지가 동작하는지 확인.
- status: official stopped(키체인 자격증명 없음), lmstudio stopped, strata serving ✓
- `switch lmstudio`: 파일 없음→새 settings.json 생성 + fake lms로 서버 자동 기동 ✓
- `switch strata` → 8개 env 키 정확히 기록 ✓ / `switch official` → env 삭제(None) ✓
- `backups` → `restore latest`: 복원 전 `pre-restore` 백업 후 복원 ✓
- 깨진 JSON 거부 + 파일 무변경 ✓ / `check strata` HTTP 200 ✓ / `profile strata` 파일+명령 출력 ✓
- 로그: 평문 시크릿 grep 0, 토큰은 `vmse…0000`/`****` 마스킹 ✓
- VM 로케일(en)에서 메뉴·CLI 문구가 영어로 나옴(언어 자동 적응 ✓)

## C. VM — GUI(메뉴바 실클릭)
증거: `docs/screenshots/vm_01_bar.png` ~ `vm_04_restore_submenu.png`, 원 로그 `tests/vm_switch.jsonl`
- 메뉴바 아이콘(SF symbol ⇄ + 상태 점) 렌더 ✓, 메뉴 전체 항목 렌더 ✓(한국어는 Studio에서 확인)
- 메뉴 클릭 전환 → settings env 기록 + LM Studio 서버 자동 기동(curl 200) ✓, 헤더·체크·결과 줄 갱신 ✓
- 서버 중지 → 1234 다운 / 서버 시작 → 1234 200 ✓ (서브메뉴)
- 모델 서브메뉴(LM/Strata 목록) ✓, 백업 복원 서브메뉴(최신 4개 표시) → `restore` → 파일 복원 + ✓ 결과 ✓
- 새 세션 명령 복사 → 로그 `클립보드 복사: claude --settings ".../lmstudio.json"` ✓
- 로그인 시 자동 시작: macOS 27 등록 동의 시트 확인 → enabled:true 로그 → 해제 → enabled:false ✓
- 종료 항목 → 프로세스 종료 ✓

## D. 수락 기준 (§2.7) 대조
| 기준 | 결과 |
|---|---|
| Strata 왕복(실응답) | ✓ (A4) |
| settings.json 병합 전용 | ✓ (A3) |
| 백업 생성·복원 | ✓ (A5, B, C) |
| 깨진 JSON 거부 | ✓ (A5, B) |
| 실행 중 세션 무영향 | ✓ (env 특성상 새 세션만; 사건 관찰로 재확인) |

## E. 남은 개선 후보(기록)
- "복원 완료:", "클립보드 복사:" 등 하드코딩 한국어 문자열 → STRINGS 테이블로 통합
- macOS 27 SMAppService 동의 시트 → 자동시작 토글 UX 안내
- GUI 메뉴 항목 좌표 자동화는 스크린샷 좌표 기반(사람 사용엔 영향 없음)

## F. 최종 설치 시험 (Mac Studio, /Applications)
- `install.sh`로 설치 → 메뉴바 ⇄ 아이콘 확인, 한국어 메뉴 렌더, 현재: 공식 ✓
- 메뉴 클릭으로 Strata 전환 → 실 settings.json env 기록(토큰 마스킹 로그) →
  `claude -p` 실응답 `FINAL_STUDIO_GUI_OK` (로컬 Strata 서버 왕복)
- 메뉴 클릭으로 공식 복귀 → env 마커 키만 남음, `current: official` ✓
- 앱 상주: /Applications/ClaudeAPISwitch.app (pid 확인), 자동시작 OFF 기본
