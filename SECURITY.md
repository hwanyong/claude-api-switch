# Security policy

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** form on the repository's Security tab
(private vulnerability reporting). A fix and a disclosure note follow the report.

Do not open a public issue for a vulnerability.

## What the binary touches

| Resource | Access | Where |
| --- | --- | --- |
| `~/.claude/settings.json` | read, and writes only inside the `env` block | `SettingsEditor.swift` |
| `~/.claude/.ccswitch.lock` | create, `flock` exclusive lock | `SettingsEditor.swift` |
| `~/.claude/profiles/<kind>.json` | create with mode `0600` | `Engine.swift` |
| `~/Library/Application Support/ClaudeAPISwitch/` | own config, log, and up to 20 backups | `Core.swift` (`Paths`) |
| macOS keychain | one read-only lookup of `Claude Safe Storage` to report login state; never written | `Engine.swift`, `CLI.swift` |
| `~/.strata/data/native-instances/*.json` | read: host, port, api key, model id, engine log path | `Discovery.swift` |
| `~/.lmstudio/.internal/http-server-config.json`, `lms` | read config, run `lms server start/stop/status` | `Discovery.swift` |
| `~/.claude/projects/*/*.jsonl` | read the tail for the newest `usage` block | `Watch.swift` |
| The engine log named in the Strata instance JSON | read the tail for residency lines | `Policy.swift` |

No network server is opened. Outbound requests go only to the endpoints this app
detects or you declared, on `GET /v1/models` and `POST /v1/messages`.

## Secret handling

| Rule | Implementation |
| --- | --- |
| An endpoint key is written only where Claude Code needs it to work: the `env` block of `~/.claude/settings.json` and the session profile | `envSet` in `Engine.swift` |
| A key never enters the app's own config, log or menu text in plaintext. `logEvent` masks any field whose key contains `token` or `key`; the menu and `status` print `maskSecret` output (`first4…last4`, `****` for 8 characters or fewer) | `Core.swift` |
| The session profile carries a key, so the mode is set on the temp file before the rename: `0600` from the first byte, never briefly world readable | `jsonWrite(_::_:fileMode:)` in `Core.swift` |
| `ANTHROPIC_API_KEY` is removed on every switch to a local endpoint, so a leftover key cannot win the precedence fight against `ANTHROPIC_AUTH_TOKEN` | `switchTo` in `Engine.swift` |

## Trust model

The app runs as your user, with your user's permissions, and it edits a file your
user owns. It does not escalate, install kernel extensions, or run a daemon: the
login item is the same `.app` bundle, registered through `SMAppService`.

Releases are **ad-hoc signed** (`codesign -s -`). There is no Developer ID
signature and no notarization, so Gatekeeper blocks a downloaded bundle until you
clear the quarantine flag. `install.sh` does that, and it is why building from
source (`swift build -c release`) is the recommended path if you would rather not
trust a downloaded binary.

## Things this app will not do

- It will not modify a `settings.json` that fails to parse. It refuses and leaves
  the file untouched (verified: exit code 1, unchanged file checksum).
- It will not touch any key outside `env`. A write that changes top-level keys
  such as `hooks`, `model` or `permissions` is a bug: report it.
- It will not run a status line that can kill your session: `statuslineMain`
  always returns 0 (`Watch.swift`).
