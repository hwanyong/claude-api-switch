# 2. Design

Premise: the measurements in [01_findings.md](01_findings.md). Both local backends answer
`POST /v1/messages`, and the switching point is the `env` block of `~/.claude/settings.json`.

This document records the design as planned on 2026-11-15, and marks where the shipped code
went a different way. Where the two disagree, the code is right and the note says so.

## 2.1 Goals

| Goal | Realised as |
| --- | --- |
| A menu bar resident app whose icon shows which API Claude Code is on | `NSStatusItem` with the `switch.2` symbol and a coloured state dot |
| One click between official, LM Studio, Strata | plus a fourth target added later: a user-declared endpoint |
| No hand-typed ports, keys or model ids for the known backends | `Discovery.swift` probes live: `GET /v1/models` decides serving |
| Always reversible | 20 backups, a restore submenu, `restore` in the CLI, no keychain change |

Non-goals, still true: no proxy, no token accounting across providers, no Windows, no
multi-user deployment, no Homebrew formula.

## 2.2 The unit of switching: a profile

A profile is the set of `env` entries written for one backend.

| Profile | Written env |
| --- | --- |
| official | the eleven managed keys are removed (the keychain credential is then used) |
| LM Studio | `ANTHROPIC_BASE_URL=http://127.0.0.1:<measured port>`, `ANTHROPIC_AUTH_TOKEN=lmstudio`, five model keys, `CLAUDE_CODE_ATTRIBUTION_HEADER=0` |
| Strata | same shape, with `ANTHROPIC_AUTH_TOKEN` from `native-instances/*.json` |
| custom | the address, key and model id you declared with `custom set` or the menu |

Plus the two context keys when a policy was derived: `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, and
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` only under `--hard`.

The merge rule: every other `env` key and every other top-level key is left alone. The
before/after shape from the original design still holds:

| File position | Before a switch to Strata | After |
| --- | --- | --- |
| `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `"1"` | `"1"` (untouched) |
| `env.ANTHROPIC_BASE_URL` | absent | `http://127.0.0.1:18500` |
| `env.ANTHROPIC_AUTH_TOKEN` | absent | the instance `api_key` |
| `env.ANTHROPIC_MODEL` | absent | `iq3_s` |
| top-level `hooks`, `model`, `permissions` | present | present |

## 2.3 Architecture as shipped

Eleven Swift files, no third-party dependency, one SPM executable target.

| Module | File | Responsibility |
| --- | --- | --- |
| entry point | `main.swift` | no arguments: run the AppKit app; any argument: run the CLI and exit with its code |
| status item and menu | `UIApp.swift` | `NSStatusItem`, menu rebuild, the custom endpoint dialog, toggles, autostart through `SMAppService` |
| CLI | `CLI.swift` | twelve subcommands, `--json` output for the machine-readable ones |
| engine | `Engine.swift` | `gatherStatus`, `switchTo`, `policyFor`, `writeProfileFile`, `checkBackend` |
| discovery | `Discovery.swift` | Strata instance JSON, LM Studio port probing and `lms` control, declared endpoint probing |
| HTTP | `HTTPKit.swift` | `GET /v1/models` with three auth styles, `POST /v1/messages` probe, `meta.n_ctx` parsing |
| settings editing | `SettingsEditor.swift` | `flock`, merge-only write, backup, atomic replace, read-back verify, rollback, restore |
| policy | `Policy.swift` | engine log parsing into `Residency`, `derivePolicy`, warning set, what to publish |
| watch | `Watch.swift` | status line, live session records, transcript tail scan |
| persistence | `Store.swift` | app config: selected model per backend, policy overrides, the declared endpoint, language |
| shared | `Core.swift` | managed key list, paths, atomic `jsonWrite`, process helpers, masking, the string table |

Drift from the 2026-11-15 plan, which proposed `SwiftUI MenuBarExtra`: the shipped app uses
AppKit `NSStatusItem` with an `NSMenu` built in code. The menu needs disabled informational
rows, attributed titles for state suffixes, and per-item represented objects; that is cheaper
in `NSMenu` than in `MenuBarExtra`. `main.swift` sets `setActivationPolicy(.accessory)`.

## 2.4 Writing settings.json (as built)

Claude Code edits the same file, so the write path is `SettingsEditor.apply(set:remove:tag:)`:

| Step | Code |
| --- | --- |
| 1 | `open(~/.claude/.ccswitch.lock)` then `flock(LOCK_EX)` |
| 2 | `readDoc()`: an empty file is treated as `{}`, a file that fails to parse throws and nothing is written |
| 3 | change only the `env` dictionary entries named by `set` and `remove` |
| 4 | recheck the file's mtime; if it moved, sleep 0.3 s and retry, up to 3 attempts |
| 5 | copy the current file to `~/Library/Application Support/ClaudeAPISwitch/backups/<timestamp>-<tag>.json`, keeping the 20 newest |
| 6 | `jsonWrite`: write `<path>.ccswitch.tmp` in the same directory, set the POSIX mode on the temp file, `fsync`, then `rename(2)` |
| 7 | re-read and check every key that must be present and every key that must be gone; on mismatch copy the backup over the file and throw |

Two drift notes:

| Planned | Shipped | Why |
| --- | --- | --- |
| Backups in `~/.claude/backups`, five kept | `~/Library/Application Support/ClaudeAPISwitch/backups`, 20 kept | the app's own directory survives a Claude Code reset, and five was too few to walk back a bad afternoon |
| Key-by-key textual edit to preserve byte order | JSON round trip with `.sortedKeys`, `env` merged | simpler and provably merge-only at the key level. Key order in `settings.json` can change; contents cannot. This is a real, disclosed difference |
| Menu text: "최근 5회" | the restore submenu lists the 10 newest | one line of code, more history in reach |

## 2.5 Session-scoped launching

`claude --settings <file>` was confirmed in `claude --help` on 2026-11-15.

- The app writes `~/.claude/profiles/<kind>.json`, a complete settings file for that session.
- The menu copies the command (`Copy new-session command`), and the CLI prints it.
- Global switching and session scope stay independent: global can stay official while one
  terminal runs the local model.
- The profile carries the endpoint key, so it is written `0600`.
- `claude --settings` replaces rather than merges the `env` block for that session; the file is
  therefore self-contained.

## 2.6 The context policy (added after the switcher worked)

Inputs, all measured, none configured: `Residency` from the engine log, `meta.n_ctx` from the
endpoint, `autoCompactWindow` and `autoCompactEnabled` from the user's `settings.json`, and the
user's overrides in `Store.BackendPolicy`.

`derivePolicy` publishes `min(coldPrefillSeconds × tok/s, resident budget ÷ sessions,
n_ctx − 8000)`, rounded down to a 4000 grid, floored at 32000, never above `n_ctx`, never
replacing a tighter user window. It publishes nothing when `autoCompactEnabled` is false or when
`--window auto` was asked for, and it says which in `windowReason`.

The surface: `policy` in the CLI, the Context submenu, the `autoCompactWindow` in a session
profile, the two env keys in a global switch, and `statusline` for the in-session warning.
The full derivation and the honest-refusal table are in the README; the numbers behind them are
in [01_findings.md](01_findings.md) section 6.

## 2.7 Stages, and what happened

| Stage | Deliverable | Result |
| --- | --- | --- |
| P0 | CLI engine only | done first, verified against a real local server before any UI existed (see `TESTING.md` section A) |
| P1 | menu bar: icon, switching, status, health check | done |
| P2 | model choice, server start/stop, backup restore, log, Korean and English strings, login item | done; the hardcoded strings were moved into `STRINGS` on 2026-11-18 |
| P3 | ad-hoc signing, install script, resilience | done, plus CI builds (2026-11-18) |
| P4, unplanned | user-declared endpoint, the context policy work | added 2026-11-18 as part of preparing this repository for publication |

## 2.8 Decisions

| Date | Decision |
| --- | --- |
| 2026-11-15 | Swift, SPM, macOS 13+. Global `settings.json` and session profiles both. Server auto-start and manual toggle both. Model chosen from the detected `/v1/models` list |
| 2026-11-18 | Publish under MIT. Add the custom endpoint rather than publish a switcher that only knows two private products. Ship the `.app` through GitHub Actions instead of committing a binary. Keep the bundle identifier `com.uhd.claudeapiswitch` |

## 2.9 Risks and their handling

| Risk | Handling |
| --- | --- |
| Concurrent writes to `settings.json` lose someone's change | lock, mtime recheck, backup, atomic replace, verify, rollback |
| A stored port differs from the listening port | probe live, treat the stored value as a hint |
| `ANTHROPIC_API_KEY` left behind wins precedence | remove-only management of that key on every switch |
| The new environment reaches only new processes | stated in the menu header and in the switch result |
| A local engine's log format is private | parse only what is there, warn when a number is missing, never estimate a number |
| The app is itself running while pointed at a local engine | the app makes no Claude API calls of its own, so switching cannot break the app |
| Detection formats change with an app update | documented in "Known limitations"; a format change produces an explicit "not detected", not a wrong endpoint |
