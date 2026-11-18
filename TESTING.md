# Test record

Nothing here is a unit test file. Each entry is a command that was run, or a menu that was
clicked, with the output it produced. The approach is bottom-up: the CLI engine was executed
against a real server before any menu existed, and each later layer was checked only for its own
output, on top of the layer already checked.

Two environments were used:

| Environment | What it proved |
| --- | --- |
| Mac Studio, the author's working machine | the real `~/.claude/settings.json`, real LM Studio and Strata servers, real `claude` sessions. The real file was only ever touched through backup, switch, verify, restore |
| A clean macOS VM | detection, autostart and refusal paths against fixtures: a fake `lms` script, echo servers, a hand-written `~/.strata/data/native-instances/vm.json`. English UI strings, because the VM locale was English |

`CLAUDE_CONFIG_DIR` is honoured the way Claude Code honours it, so a run can be aimed at a
fixture directory instead of `~/.claude`.

## A. Mac Studio, CLI (stage P0)

| # | What was run | Result |
| --- | --- | --- |
| 1 | endpoint proof: isolated dir `/tmp/ccswitch-e2e` plus `tests/echo_server.py` on port 19311, then `claude -p` | the request went to the echo server's `POST /v1/messages` with `Bearer lmstudio`, and the answer was `ECHO_OK echo-model`. The `env` block really is what routes a session |
| 2 | `status` on the real machine | current official, LM Studio serving on 1234 with 12 models, Strata serving on 18500 with `qwen3.8-flash-next-iq3_s` (alias `iq3_s`, `n_ctx` 131072 at that date) |
| 3 | merge-only check on a copy of the real `settings.json` | no diff outside `env`; `hooks`, `model`, `permissions` preserved. Back to official removed only the managed keys, leaving one user key |
| 4 | real round trip: `switch strata --model iq3_s`, then `claude -p`; then `switch official` | local model answered `REAL_SWITCH_STRATA_OK`; after the return the file was structurally identical to the original (non-`env` diff empty). Final state: official |
| 5 | defences | malformed JSON refused with the file unchanged and exit code 1; backups created and `restore latest` worked; log lines masked |
| 6 | an incident, recorded honestly | during testing the Strata serving process was restarted, so existing sessions pointing at 18500 got `ECONNREFUSED`. Not caused by this app. The switch window was 23:24 to 23:25 and every step is in the log |

`check lmstudio` initially hung on an audio model. The fix was to probe up to four models, the
selected one first; then it returned OK. That is a case of a check being wrong, not the backend.

## B. Clean VM, CLI against fixtures

Fixtures: `~/.strata/data/native-instances/vm.json` (port 18500) with an echo server, a fake
`lms` supporting `status`, `start` and `stop`, and an echo server on 1234. No real LM Studio or
Strata installed, so detection, autostart and shutdown all had to come from the fixture.

| Check | Result |
| --- | --- |
| `status` | official reported no keychain credential, lmstudio stopped, strata serving |
| `switch lmstudio` with no `settings.json` at all | file created, fake `lms server start` invoked, switch succeeded |
| `switch strata` | exactly the intended env keys written. `switch official` removed them |
| `backups` then `restore latest` | a `pre-restore` backup was taken first, then restored |
| malformed JSON | refused, file unchanged |
| `check strata` | HTTP 200 |
| `profile strata` | file written, command printed |
| log | a `grep` for the plaintext fixture secret returned 0 matches; tokens appear as `vmse…0000` or `****` |
| menu and CLI language | English on the English-locale VM, Korean on the Korean machine |

## C. VM, GUI by menu clicks

Evidence: `docs/screenshots/vm_01_bar.png` through `docs/screenshots/vm_04_restore_submenu.png`,
and the raw log `tests/vm_switch.jsonl`.

| Surface | Result |
| --- | --- |
| Status item | `switch.2` symbol plus state dot rendered; the loading symbol appeared during a refresh |
| Menu | every item rendered; English on this VM |
| Switch by click | `env` written, LM Studio server autostarted (curl 200 afterwards), header, check mark and result line updated |
| Server submenu | stop took 1234 down, start brought it back to 200 |
| Model submenu | both backends' detected model lists rendered |
| Restore submenu | listed the newest backups; choosing one restored the file and logged it |
| Copy new-session command | the log shows the clipboard write with the `claude --settings` command |
| Start at login | macOS 27 registration consent sheet appeared, log shows `enabled: true`, then off |
| Quit | process exited |

## D. Acceptance criteria from the design

| Criterion | Result |
| --- | --- |
| Strata round trip with a real local answer | pass (A4) |
| `settings.json` merge only | pass (A3) |
| Backups created and restorable | pass (A5, B, C) |
| Malformed JSON refused | pass (A5, B) |
| Running sessions unaffected | pass, by the nature of `env` plus the observation in A6 |

## E. Follow-ups recorded at the time, and their state

| Item | State |
| --- | --- |
| Hardcoded Korean strings such as "복원 완료:" | fixed 2026-11-18: they moved into the `STRINGS` table in `Core.swift` |
| macOS 27 `SMAppService` consent sheet | kept as is; the CLI reports `supported only from a .app bundle` when run outside a bundle |
| Menu coordinate automation for screenshots | still coordinate-based. It drives the app, it is not part of it |
| `BackendKind.custom` detected but not switchable | fixed 2026-11-18, see F |
| LM Studio sessions given a Strata-derived KV budget | fixed 2026-11-18: `isLocalKind` takes the endpoint base, so a backend gets a budget only from measurements it produced |

## F. 2026-11-18, the declared endpoint and the guards re-run

Isolated dir `/tmp/ccswitch-verify` and `/tmp/ccdocs`, `tests/echo_server.py` on a test port,
then the built binary. The real `~/.claude/settings.json` was not touched; the app's own
`config.json` and `watch.json` were copied aside and restored afterwards.

| Check | Output |
| --- | --- |
| `custom set --base http://127.0.0.1:<port>/v1` | trailing `/v1` stripped, `declared: 127.0.0.1 http://127.0.0.1:<port>`, `serving: 1 models`, `echo-model n_ctx=65536` |
| `custom show` | `token: demo…7890` |
| `list` | `official lmstudio strata custom` |
| `status` | `custom serving`, model `echo-model (65536 ctx)` |
| `policy custom` | `window 56k / model 66k · ×2 [model window]`, publish line `settings autoCompactWindow=56000 + env CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536`, warning `engine residency not measured` |
| `profile custom` | file written, `ls -l` shows `-rw-------` |
| `check custom` | `127.0.0.1: OK (HTTP 200) model=echo-model` |
| `statusline` fed a session JSON | `echo-model 52k/66k (79%)`, exit code 0 |
| switch against a closed port | exit code 1, message `Custom endpoint does not answer GET /v1/models.` |
| switch against truncated JSON | `settings.json is not valid JSON: refusing to modify`, exit code 1, md5 of the file identical before and after (`93e6968bdb19c6fb453d971ef4f34621`) |
| switch against a fixture user file | `top-level keys: ['env', 'hooks', 'model', 'permissions']`, and the fixture's own `env` key `MYPRESERVED` still present |
| log | `grep -c` for the plaintext fixture key in `switch.jsonl` returned 0 |

## G. Reproducing any of it

```sh
python3 tests/echo_server.py 19311 &
CLAUDE_CONFIG_DIR=/tmp/ccswitch-e2e claude-switch custom set --base http://127.0.0.1:19311
CLAUDE_CONFIG_DIR=/tmp/ccswitch-e2e claude-switch check custom
CLAUDE_CONFIG_DIR=/tmp/ccswitch-e2e claude-switch policy custom
CLAUDE_CONFIG_DIR=/tmp/ccswitch-e2e claude-switch profile custom
CLAUDE_CONFIG_DIR=/tmp/ccswitch-e2e claude --settings /tmp/ccswitch-e2e/profiles/custom.json -p "say OK"
# expect ECHO_OK echo-model
```

Every command above aims at `/tmp/ccswitch-e2e`, so it cannot touch a real `~/.claude`.
