# Claude API Switch

[English](README.md) | [한국어](README.ko.md)

A macOS menu bar app that repoints Claude Code between the official Anthropic API,
LM Studio, a Strata engine, or one Anthropic-compatible endpoint you declare, and
sizes the context window to what your engine can actually keep in RAM.

The part that is not just a switcher: it reads the engine's own log to measure how
much KV cache fits in free memory and how fast the engine re-reads a cold prompt,
then publishes the context window that follows from those two numbers. Claude Code
does neither measurement. For a model id it does not recognise it guesses a context
window and then enforces that guess.

## What it fixes

| Symptom | Cause | What this app does |
| --- | --- | --- |
| "I switched and nothing changed" | Claude Code reads the endpoint from the `env` block of `~/.claude/settings.json`, and a leftover `ANTHROPIC_API_KEY` wins precedence | A switch writes only the keys it owns (the eleven in `MANAGED_KEYS`) and always removes `ANTHROPIC_API_KEY` |
| "My local session dies with `prompt too long`" | Claude Code guesses the context window of an unknown model id and enforces that guess | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is set from the `meta.n_ctx` the endpoint itself reports |
| "It works, then gets crawlingly slow after a while" | The session outgrew the KV cache the engine can hold, so conversations get evicted and each next request re-reads the whole prompt cold | The auto-compact window is set from measured `bytes/token` and measured prefill speed |
| "I lost my hooks / permissions / model settings" | A config editor rewrote the whole file | Only the `env` block is touched. Verified below: `hooks`, `model`, `permissions` and your own `env` keys survive |
| "Is this session on the local model or not?" | Nothing shows it | Menu bar icon plus an in-session status line that prints the real used/window pair from Claude Code |

## Quick start

Requirements: macOS 13 or later, Swift 5.9 or later, Claude Code installed.

```sh
zsh dist/build_app.sh          # release build, .app bundle, ad-hoc signature
zsh install.sh                 # copies to /Applications and launches it
```

The same binary is a CLI: `claude-switch status`. Inside a `.app` bundle it is at
`ClaudeAPISwitch.app/Contents/MacOS/claude-switch`.

Pushing a `v*` tag makes GitHub Actions build the bundle on a macOS runner, smoke test
the binary inside it, and attach `ClaudeAPISwitch.app.zip` to a Release
(`.github/workflows/build.yml`). That bundle is **ad-hoc signed**: no Developer ID
signature, no notarization, so Gatekeeper blocks a download until `install.sh` clears the
quarantine flag. Building from source skips all of it.

## What changes when you switch

A switch touches one place: the `env` block of `~/.claude/settings.json`.

| Key | Owned by this app | On switch to a local endpoint | On switch back to official |
| --- | --- | --- | --- |
| `ANTHROPIC_BASE_URL` | yes | endpoint base, no trailing `/v1` | removed |
| `ANTHROPIC_AUTH_TOKEN` | yes | endpoint key (`x-api-key` / Bearer) | removed |
| `ANTHROPIC_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL` | yes | the selected model id | removed |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | yes | `0` (LM Studio's own recommendation) | removed |
| `ANTHROPIC_API_KEY` | yes, remove-only | removed, so it cannot win precedence | removed |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | yes | the model's real `n_ctx` | removed |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | yes, only with `--hard` | the derived window, env form | removed |
| `env` keys you added, and every top-level key | no | left alone | left alone |

Re-verified on 2026-11-18 against an isolated config dir with a fixture user file:

```
top-level keys: ['env', 'hooks', 'model', 'permissions']
env keys: ['ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
           'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_MODEL',
           'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_ATTRIBUTION_HEADER',
           'CLAUDE_CODE_MAX_CONTEXT_TOKENS', 'MYPRESERVED']
```

`MYPRESERVED` is the fixture's own `env` key. It survives.

A switch applies to **new** `claude` processes. A session that is already running
keeps the environment it started with; the menu says so in its header.

## The context policy

`claude-switch policy strata` on a real Mac Studio with a Strata engine loaded:

```
strata: window 56k / model 524k · resident 206k/4 slots · 17kB/tok · 194 tok/s cold · ×2  [cold re-read 300s @ 194 tok/s, resident 206k / 2, model window]
  publish: settings autoCompactWindow=56000 + env CLAUDE_CODE_MAX_CONTEXT_TOKENS=524288
  ⚠ engine evictions=75 since start, parked=1/4
  ⚠ model window exceeds resident budget: 524k > 206k
```

Every number above is read from the engine, not configured:

| Quantity | Source | Value in this run |
| --- | --- | --- |
| KV cache cap in free RAM, and how many conversations it parks | `conversation cache sized from the free RAM: N MiB for up to M parked` | 3584 MiB, 4 slots |
| Bytes of KV per token | delta of `snapshot_bytes` over delta of parked tokens, median | 17 kB/token |
| Cold prefill speed | `+ N read in M ms (X tok/s)`, median | 194 tok/s |
| Resident budget | `cap × 1 MiB ÷ bytesPerToken` | 206k tokens |
| Model window | `meta.n_ctx` from `GET /v1/models` | 524288 |

The published window is the smallest of three bounds, rounded down to a 4000 grid,
with a floor of 32000 and never above the model window:

| Bound | Default | This run |
| --- | --- | --- |
| Patience for one cold re-read: `coldPrefillSeconds × tok/s` | 300 s | 58.2k |
| Fair share of the resident KV cache: `budget / sessions` | 2 sessions | 103k |
| Model window minus one round trip of headroom: `n_ctx − 8000` | - | 516k |

So 56000 wins on this machine, and the reason string prints next to it
(`cold re-read 300s @ 194 tok/s`). 56000 tokens at 194 tok/s is about 4.8 minutes,
which is what a cold re-read after an eviction costs.

Override any input, and the derivation stays honest:

```sh
claude-switch policy strata --sessions 3 --wait 120 --window auto   # warn only, publish no window
claude-switch policy custom --window 120k --hard                    # pin the env form (beats /autocompact)
claude-switch policy --json                                         # machine-readable, per backend
```

It refuses rather than invents:

| Situation | Behaviour |
| --- | --- |
| `GET /v1/models` reports no `n_ctx` | warns `model window unknown`, states no window |
| No conversation-cache lines in the engine log | warns `engine residency not measured`, bounds the window by the model window only |
| `autoCompactEnabled: false` in your `settings.json` | publishes no window at all: nothing bounds the session, and a published number would be a lie |
| Your own `autoCompactWindow` is already tighter | leaves it alone and says so in the reason |
| The endpoint is on another host | no KV budget: a remote engine's RAM limit is not readable from here |

Residency lines are read from the Strata engine's log. LM Studio and a declared
loopback endpoint get the model-window bound and the cold re-read bound, and no
resident-budget warning, because they do not produce the measurements.

## In-session warning

The session profile installs `claude-switch statusline` as Claude Code's `statusLine`
command. Claude Code pipes its session JSON on stdin; the app prints one line from
Claude Code's own numbers and always exits 0, so a status line cannot break a session.
Your existing `statusLine` command is chained, not replaced: its output is kept and
the token figure is appended.

```
echo-model 52k/66k (79%)
```

Over the resident budget the line becomes `⛔ resident 141% of budget: /compact now`,
at 80 percent `⚠ resident 84% of 103k`.

`claude-switch watch` reports the same figure for every session it can see, from two
sources: the records the status line writes, and a tail scan of
`~/.claude/projects/*/*.jsonl` for sessions that were not started from a profile.

```
engine: cap 3584 MiB, slots 4, 17 kB/token, cold 193 tok/s
resident budget: 206k tokens (parked 1 conversations, evictions 75)
  switch_claude_code_api  145k/524k budget 103k (141%) ⛔ /compact now  iq3_s
```

## Session profile: one terminal, no global change

```
$ claude-switch profile custom
/tmp/ccdocs/profiles/custom.json
claude --settings "/tmp/ccdocs/profiles/custom.json"
  window 56k / model 66k · ×2  (model window)
  ⚠ engine residency not measured: no conversation-cache lines in the engine log
```

The file is a complete Claude Code settings file (`env`, `autoCompactWindow`,
`statusLine`, plus a `_ccswitch` block that records which numbers were used and when).
It holds the endpoint key, so the mode is set on the temp file before the rename:

```
-rw-------  1 uhd  wheel  917 /tmp/ccdocs/profiles/custom.json
```

Global and session scope stay independent: the global setting can stay on the official
API while one terminal runs the local model.

## Declaring an endpoint

Anything that answers `POST /v1/messages` with the Anthropic shape: llama.cpp servers,
LM Link on another machine, LiteLLM, a corporate gateway, a test fixture.

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

A trailing `/v1` is stripped, because Claude Code appends `/v1/messages` itself. The
key is stored in the app's own config and printed masked everywhere. The menu has the
same entry: **Set custom endpoint…**. Detection stays live even for a hand-declared
endpoint: `GET /v1/models` decides whether it is serving, and its `meta.n_ctx` decides
the model window. Nothing tries to start a server this app does not know how to start.

## Menu

| Item | Behaviour |
| --- | --- |
| Header lines | current backend, model and base, `new claude sessions only`, the last result, a token-load warning at 80 percent |
| Official Claude API / LM Studio (Bionic) / Strata / Custom endpoint | switch; a check mark shows the current one, `(stopped)` marks an endpoint that does not answer |
| Set custom endpoint…, Remove custom endpoint | address, key and model id dialog |
| Model | detected models per backend with `n_ctx`, grouped by backend |
| Context / compaction | derived window per backend with its reason, warnings, live token load, and three toggles: in-session warning, token load in the menu bar, let Claude Code pick the window (warn only); plus Rewrite session profiles now |
| Server | Start or Stop LM Studio server (`lms`), Launch Strata app |
| Check status now | `GET /v1/models` plus a real `POST /v1/messages` round trip |
| Copy new-session command | `claude --settings ~/.claude/profiles/<kind>.json` onto the clipboard, per backend |
| Restore backup | the 10 newest of the 20 backups kept on disk |
| Open settings.json, Open log, Start at login (`SMAppService`), Quit | |

The menu bar title is the `switch.2` SF Symbol with a coloured state dot; while a
status check runs it shows `hourglass`.

## CLI

`claude-switch help` prints this:

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

`CLAUDE_CONFIG_DIR` is honoured exactly as Claude Code honours it, which is how the
test suite runs against a fixture instead of a real `~/.claude`.

Detection, per backend:

| Backend | How it is found |
| --- | --- |
| official | presence of the `Claude Safe Storage` keychain item, read-only, to report login state |
| LM Studio | port from `lms server status`, then `~/.lmstudio/.internal/http-server-config.json`, then 1234. The stored config port and the listening port disagree on this machine (8234 stored, 1234 listening), so the stored value is only a hint. Default key `lmstudio` |
| Strata | `~/.strata/data/native-instances/*.json` for host, port, key, model id and engine log path. A key is required: without one the server answers `authentication_error` |
| custom | what you declared with `custom set` or the menu, probed live |

## Writing settings.json without losing anything

Claude Code writes the same file, so the editor is defensive. `SettingsEditor.swift`:

| Step | Implementation |
| --- | --- |
| 1. Lock | `flock` exclusive on `~/.claude/.ccswitch.lock` |
| 2. Parse or stop | a file that fails to parse is refused, never repaired |
| 3. Merge | only the `env` keys in `MANAGED_KEYS` are added or removed |
| 4. Race check | the file's mtime is rechecked, up to 3 attempts, because Claude Code may have written it in between |
| 5. Backup | a copy goes to `~/Library/Application Support/ClaudeAPISwitch/backups`, the 20 newest are kept |
| 6. Atomic replace | temp file in the same directory, `fsync`, POSIX `rename` |
| 7. Read back and verify | every key that should be set, and every key that should be gone; a mismatch copies the backup back and throws |

The guard, run against a truncated file:

```
$ claude-switch switch custom   # settings.json holds truncated JSON
settings.json is not valid JSON: refusing to modify
(exit code 1)

settings.json md5: before=93e6968bdb19c6fb453d971ef4f34621 after=93e6968bdb19c6fb453d971ef4f34621
```

## Secrets

| Rule | Where |
| --- | --- |
| An endpoint key appears only in the two files that need it to work: the `env` block of `settings.json` and the session profile (`0600`) | `envSet`, `writeProfileFile` |
| The app's own log and config never hold it in plaintext: `logEvent` masks any field whose key contains `token` or `key` | `Core.swift` |
| Menu and CLI print `first4…last4`, and `****` for keys of 8 characters or fewer | `maskSecret` |
| The keychain is read once, read-only, to report whether you are logged in; it is never written | `check official`, `gatherStatus` |

## Known limitations

- macOS only. The menu bar is `NSStatusItem` (AppKit); the CLI half has no GUI dependency but still assumes macOS helpers (`security`, `lms`, `SMAppService`).
- A switch reaches new `claude` processes only. There is no way to change the environment of a process that is already running.
- The resident KV budget is parsed from the Strata engine's log format. Other engines get the model-window and cold-read bounds only, and the app says `engine residency not measured` instead of estimating.
- Context-window truth depends on the endpoint reporting `meta.n_ctx`. An endpoint that does not is warned about, and no window is published for it.
- Session profiles replace the global `env` for that session (`claude --settings` semantics); they are not merged with it.
- A `.app` bundle is ad-hoc signed. Gatekeeper complains, and there is no notarization.
- The Strata instance JSON format is reverse-engineered from files on disk; an app update can change it and detection will fail.

## Tests

`TESTING.md` records what was run and where: Mac Studio against the real
`settings.json` (backup, switch, real local response, restore), a clean macOS VM
against fake `lms` and echo fixtures, and the GUI driven by menu clicks.
`tests/echo_server.py` is the Anthropic-compatible fixture the suite uses; it is also
the quickest way to try a switch without a real model.

## Documentation

| File | Contents |
| --- | --- |
| `docs/01_findings.md` | the measurements the design rests on: where Claude Code reads its endpoint, what each local server actually answers, with the curl sessions that proved it |
| `docs/02_design.md` | architecture, the safety procedure, the decisions taken and the stage plan |
| `TESTING.md` | the executed test record |
| `SECURITY.md` | what the binary touches, and how secrets are handled |

## License

MIT. See [LICENSE](LICENSE).
