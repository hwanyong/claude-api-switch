---
id: 1
type: task
title: README 두 파일에 Release 링크
priority: medium
tags: [model:standard]
depends_on: []
created_at: 2026-11-19T11:40:51Z
updated_at: 2026-11-19T11:40:51Z
status_history: [2026-11-19T11:40:51Z to-do]
---

`README.md:47-48`과 `README.ko.md:46`이 태그 push → GitHub Actions → Release 흐름을 설명하지만 Releases 페이지 링크는 없다. `grep -n -i -E "release|download|badge" README.md README.ko.md`로 재니 링크 줄이 0건이었다(2026-11-19 실측). 미리 지어 온 zip을 받으려는 독자가 Release 페이지를 스스로 찾아야 한다.

할 일: 두 파일의 그 문장에 https://github.com/hwanyong/claude-api-switch/releases 를 링크로 붙인다. 영어판과 한국어판 같은 자리에 같은 링크로, 두 벌이 어긋나지 않게.

끝난 기준: `grep -n "releases" README.md README.ko.md`에 두 파일 각각 한 줄 이상이 나오고, `git diff`에서 표와 목록의 줄바꿈이 깨지지 않았음을 확인한다. ad-hoc 서명과 격리 플래트 각 설명은 그대로 옆에 남아야 한다.
