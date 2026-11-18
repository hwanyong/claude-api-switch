# 1. Findings: is this possible, and against what

Measured on 2026-11-15 on a Mac mini, macOS, Claude Code 2.1.325 (`/opt/homebrew/bin/claude`).
Every claim below came from a command that was run on that machine, and the command is printed.

## Conclusion

Yes. Both local backends return a real Anthropic-compatible `POST /v1/messages` response on
that machine, and the switching point is one place: the `env` block of `~/.claude/settings.json`.
A menu bar item with a click menu needs nothing beyond the macOS native status item API.

## 2. The switching point

Claude Code chooses its API target from environment variables, and `settings.json` can set them.

| Variable | Role |
| --- | --- |
| `ANTHROPIC_BASE_URL` | API root. Claude Code appends `/v1/messages` itself, so the per-backend `/v1` spelling matters |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token. For local servers it is the server's own key or a dummy |
| `ANTHROPIC_API_KEY` | If it is left in `env`, it takes precedence over the target you meant. Cleaned on every switch |
| `ANTHROPIC_MODEL` | Model selection |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | LM Studio's documentation recommends `0` |

Three ways to apply them, checked on that machine:

| Route | Status on this machine | Use |
| --- | --- | --- |
| `env` block of `~/.claude/settings.json` | the block already existed | the default, and what the app writes |
| `claude --settings <file>` | flag present in `claude --help` | per-session scope, added as a feature |
| `export` in the shell profile | no `ANTHROPIC_*` variable in the shell there | not used: it would need a shell restart |

`env` reaches **newly started** sessions. A session already running keeps the environment it
started with, and the UI says so.

## 3. Backend A: LM Studio (installed here as Bionic.app)

| Item | Measured |
| --- | --- |
| App | `/Applications/Bionic.app`; `~/.lmstudio/.internal/app-install-location.json` points at it |
| CLI | `~/.lmstudio/bin/lms`; `lms server status`, `lms server start`, `lms ls` all worked (11 models, 282.33 GB) |
| Listening port | `lms server status` reported **1234** (Bionic process listening) |
| Stored port | `~/.lmstudio/.internal/http-server-config.json` said `"port": 8234` |
| Consequence | **never hardcode a port**: the stored value and the listening value disagree |
| Authentication | "Require Authentication" off, so the dummy `x-api-key: lmstudio` passes |

Round trip on port 1234:

```
curl -X POST http://127.0.0.1:1234/v1/messages \
  -H 'anthropic-version: 2023-06-01' -H 'x-api-key: lmstudio' -H 'content-type: application/json' \
  -d '{"model":"qwen/qwen3.8-27b","max_tokens":8,"messages":[{"role":"user","content":"say OK"}]}'
→ {"type":"message","role":"assistant","content":[{"type":"text","text":"OK"}],"model":"qwen/qwen3.8-27b",…}
```

LM Studio's own Claude Code page recommends `ANTHROPIC_BASE_URL=http://localhost:1234`,
`ANTHROPIC_AUTH_TOKEN=lmstudio`, `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, and a context of at least
25k tokens. The model list comes from `GET /v1/models` at request time.

## 4. Backend B: Strata

| Item | Measured |
| --- | --- |
| App | `/Applications/Strata.app` (`ai.strata.desktop`, 0.2.13) |
| Serving process | `serve.server --engine strata --host 127.0.0.1 --port 18500` |
| Detection source | `~/.strata/data/native-instances/<uuid>.json`: `host`, `port`, `api_key`, `model_name`, engine `log` path, engine `args` (`--max-context`) |
| Authentication | key required. Without one: `{"error":{"type":"authentication_error","message":"missing or wrong API key"}}` |
| Documentation | none public. Everything in this section is read off disk and off the wire |

```
GET  http://127.0.0.1:18500/v1/models
→ {"data":[{"id":"qwen3.8-flash-next-iq3_s","aliases":["iq3_s"],"meta":{"n_ctx":131072},…}]}

POST http://127.0.0.1:18500/v1/messages   (x-api-key: the api_key above)
→ {"type":"message","role":"assistant","content":[{"type":"thinking",…}],"model":"qwen3.8-flash-next-iq3_s",…}
```

The app's own Serving panel says, in Korean, that Anthropic clients append `/v1/messages`
themselves, so the address it shows has no trailing `/v1`. Hence `ANTHROPIC_BASE_URL=http://127.0.0.1:18500`.

## 5. What returning to the official API needs

Remove `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` and
`CLAUDE_CODE_ATTRIBUTION_HEADER` from `env`. The login credential was found in the keychain
(`Claude Safe Storage`, `Claude Key`), and `~/.claude/.credentials.json` does not exist, so the
return path needs no re-login.

## 6. Context window truth, found while the context policy was being built

Three measurements that changed the design:

| Measurement | Consequence for the app |
| --- | --- |
| Claude Code 2.1.325 assigns a context window to a model id it does not recognise and then enforces that assignment | the real window has to be stated: `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, taken from the endpoint's `meta.n_ctx` |
| The engine log writes its own KV cache cap (`conversation cache sized from the free RAM: N MiB for up to M parked`) and its prefill speed (`+ N read in M ms (X tok/s)`) | a resident token budget is computable: `cap ÷ bytes per token`. The log also writes `parked=… bytes=… evictions=…`, whose deltas give bytes per token |
| An eviction costs one cold re-read of the prompt | the auto-compact window should be bounded by `patience seconds × tok/s`, not by the model window alone |

A run on a Mac Studio with a loaded engine, `claude-switch watch --minutes 30`:

```
engine: cap 3584 MiB, slots 4, 17 kB/token, cold 193 tok/s
resident budget: 206k tokens (parked 1 conversations, evictions 75)
  switch_claude_code_api  145k/524k budget 103k (141%) ⛔ /compact now  iq3_s
```

The model window is 524288 while the engine can hold 206k tokens of KV cache, and the session
was already at 145k. That gap is what the policy section of the README derives a window from.

## 7. Risks found before writing code

| Risk | Handling |
| --- | --- |
| Claude Code writes `settings.json` too (a `~/.claude/.settings.lease` file exists) | read-modify-write under `flock`, mtime recheck, atomic replace, backup, rollback |
| Settings are layered: project `.claude/settings.local.json`, managed settings, `--settings` | verify the effect after a switch instead of assuming precedence |
| Ports and keys drift per instance | always detect live, never cache a port |
| The Strata `api_key` sits on disk in plaintext | read it, write it where Claude Code needs it, mask it in this app's log and UI |
| A server may not be running | health check before switching, `lms server start` when the backend supports it |
| Local models carry small `n_ctx` while Claude Code uses a lot of context | surface `n_ctx` in the menu and warn under 25k |

## 8. References

| Topic | Source |
| --- | --- |
| LM Studio | https://lmstudio.ai/docs/integrations/claude-code and https://lmstudio.ai/docs/developer/anthropic-compat/messages |
| Claude Code gateways | https://code.claude.com/docs/en/llm-gateway-connect and https://code.claude.com/docs/en/llm-gateway-protocol |
| Environment variable notes | https://www.requesty.ai/blog/claude-code-environment-variables-anthropic-base-url-auth-token |
| Strata | no public documentation. The evidence is the app's Serving panel and `~/.strata/data/native-instances/*.json` |
