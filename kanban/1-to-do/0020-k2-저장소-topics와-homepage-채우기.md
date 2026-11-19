---
id: 2
type: task
title: 저장소 topics와 homepage 채우기
priority: low
tags: [model:fast]
depends_on: []
created_at: 2026-11-19T11:40:51Z
updated_at: 2026-11-19T11:40:51Z
status_history: [2026-11-19T11:40:51Z to-do]
---

`gh repo view hwanyong/claude-api-switch --json repositoryTopics,homepageUrl`의 결과가 `topics: []`, `homepageUrl: ""`였다(2026-11-19 실측). 계정의 다른 저장소(`claude-code-mods`, `terminal-browser` 등)는 topics를 쓴다.

할 일: topic을 채운다. 후보는 `claude-code`, `macos`, `swift`, `menubar` 네 개다. homepage를 저장소 URL로 둘지는 정하지 않았다. 저장소 설정과 같은 자리의 일이라 한 번에 처리한다.

명령 예: `gh api -X PUT /repos/hwanyong/claude-api-switch/topics -H "Accept: application/vnd.github.mercy-preview+json" -f "names[]=claude-code" -f "names[]=macos" -f "names[]=swift" -f "names[]=menubar"`

끝난 기준: 앞의 `gh repo view` 명령이 네 topic을 돌려준다.
