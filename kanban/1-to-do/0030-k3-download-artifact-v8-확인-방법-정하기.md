---
id: 3
type: decision
title: download-artifact v8 확인 방법 정하기
priority: medium
tags: [model:user]
depends_on: []
created_at: 2026-11-19T11:40:51Z
updated_at: 2026-11-19T17:44:55Z
status_history: [2026-11-19T11:40:51Z to-do]
---

`.github/workflows/build.yml`의 pin이 2026-11-19에 `actions/checkout@v7` · `actions/upload-artifact@v7` · `actions/download-artifact@v8`로 올라갔다. release 잡은 `v*` 태그 push에서만 돌고, branch push(run 7·9)에서는 `skipped`였다. 태그 `v0.1.0`은 올림 이전 커밋 `a4f1dc6`을 가리키므로 이미 나온 릴리스는 `@v4`로 돈 결과다. 즉 `@v8`은 이 저장소에서 아직 한 번도 실행되지 않았다.

v8의 계약(이름으로 지정한 산출물을 워크스페이스 루트에 내려놓는다)은 임시 저장소 `hwanyong/ci-probe-artifact-actions`(삭제됨)의 run 1 job `probe`에서 확인했다. 그 실행은 `Starting download of artifact to: /home/runner/work/<repo>/<repo>`를 로그에 남겼고, 같은 워크플로에서 업로드하지 않은 산출물을 요청한 단계는 `failure`로 보고서 이 검사가 실패를 보인다는 것을 함께 보였다.

정할 것 두 갈래.

- 지금 확인: 릴리스 `v0.1.0`을 지우고 태그를 `cddd71d`로 옮겨 다시 돌린다. 자산 URL 경로는 같고 다운로드 수 2가 0으로 돌아간다. `gh release create`는 이미 있는 릴리스에서 실패하므로 지우지 않고 태그만 옮기면 release 잡이 실패한다.
- 기다림: 다음 `v*` 태그에서 저절로 붙는다. 어긋나면 그때 고친다.

결정이 나면 실행 카드를 따로 만들고 이 카드를 그 의존으로 둔다.

## Comments

### c1 [report] from=main to=k3 at=2026-11-19T17:44:55Z

2026-11-19: 커밋 b14ece8이 on.push와 pull_request에 paths-ignore를 넣었다(kanban/**와 .uhd-kanban/**). 카드만 고친 커밋은 macos-15 빌드를 띄우지 않는다. 태그 push는 path 필터를 평가하지 않는다는 규격 문장 때문에 v* 릴리스는 그대로 돈다. 이 카드의 두 갈래(지금 확인하기 / 다음 태그까지 기다리기)는 아직 정해지지 않았다.
