# InFocus CLI — design

Status: approved and implemented · 2026-09-24

## Goal

A command-line tool that Drive users install on their Macs with one command. `infocus login` opens the Drive in the browser, the user signs in the normal way (Google, email code, or NAS password), approves the terminal, and the CLI can then list, read, upload, and edit files in every share and folder that account can reach on the web — no more, no less. AI coding agents running on the same Mac (Claude Code, Codex, …) use the same commands with `--json`.

### Success criteria

1. A user with no developer tools runs one `curl … | sh` line and gets a working `infocus` on PATH (Apple Silicon and Intel).
2. `infocus login` → browser consent → terminal signed in, without copy-pasting anything.
3. Every CLI request is authorized as exactly the signed-in NAS user (same uid/gid, same `as_user` file ops, same share list).
4. A stolen approval link cannot be turned into a token for someone else's machine.
5. Tokens expire (30 days idle, 90 days hard cap), are listed in the web UI, and can be revoked from the web UI or with `infocus logout`.
6. `infocus edit` never silently overwrites a file someone else changed meanwhile.
7. An agent can drive every command non-interactively with parseable JSON and meaningful exit codes.

### Non-goals

MCP server, mounting / sync (SMB via Finder already covers mounting), Linux/Windows builds, Apple notarization, device-code (headless) login, per-token scopes (read-only tokens).

## Architecture

```
infocus (Go binary, macOS)                    Drive (FastAPI)
─────────────────────────                     ───────────────
login ─ start 127.0.0.1:<port> listener
      ─ open browser ───────────────────────► GET /cli/authorize?port&state&challenge&device
                                               (requires web session → normal sign-in if absent)
                                               consent page: Allow / Deny
      ◄─ browser redirect 127.0.0.1:<port>/callback?code&state ── POST /api/cli/authorize
      ─ POST /api/cli/token {code, verifier} ► verify PKCE, issue ifd_… token
      ─ store token in macOS Keychain

ls/cat/put/… ─ Authorization: Bearer ifd_… ► _require_user → cli_tokens.lookup
             ─ X-Drive-Share: <share>          existing /api/* endpoints, unchanged file logic
```

## Server changes

### `app/cli_tokens.py` (new)

SQLite at `CLI_TOKENS_DB_PATH` (default `/config/cli_tokens.sqlite3`, the persistent config mount), same connection/transaction pattern as `email_auth.py`.

Tables:

- `cli_codes(code_hash PK, username, device, challenge, expires_at, used)` — auth codes.
- `cli_tokens(id PK, token_hash UNIQUE, username, device, created_at, last_used_at, revoked_at)`.

Rules:

- Token format `ifd_` + 32 random bytes (base64url). Only the SHA-256 hash is stored.
- Auth code: 32 random bytes, single use, expires 60 s after issue, bound to the PKCE S256 `challenge` and the approving username.
- Lookup succeeds only if: not revoked, `now - last_used_at < 30 days`, `now - created_at < 90 days`, and `pwd.getpwnam(username)` exists with `uid >= 1000`. uid/gid are read fresh from `pwd` on each lookup (never trusted from the DB), so deleted users lose access immediately.
- `last_used_at` is updated at most once per minute per token (avoid a write per request).
- `device` is user-supplied display text: trimmed, control characters stripped, max 64 chars, HTML-escaped when rendered.
- Public API: `issue_code(username, device, challenge) -> code`, `redeem_code(code, verifier) -> (token, id)`, `lookup(token) -> user dict | None`, `list_for(username)`, `revoke(id, username)`, `revoke_token(token)`, `revoke_all(username)`.

### Routes (`app/main.py`)

| Method | Path | Auth | Behavior |
|--------|------|------|----------|
| GET | `/cli/authorize` | web session | Validates `port` (1024–65535), `state` (16–128 url-safe chars), `challenge` (43-char base64url), `device`. No session → redirect to sign-in with `next=` back here. Renders consent page (static HTML + small JS, same CSP as the app): "Allow **InFocus CLI on {device}** to access your Drive as **{username}**?" |
| POST | `/api/cli/authorize` | web session + same-origin (`Origin` check) | Plain form POST `{port, state, challenge, device, allow}`. Issues code and answers **303** to `http://127.0.0.1:{port}/callback?code=…&state=…` (or `error=access_denied` on Deny), so page script can never read the code. Redirect host is always the literal `127.0.0.1`. The page and terminal both show a confirmation code derived from `state`. |
| POST | `/api/cli/token` | none (code + verifier) | Redeems code → `{token, token_id, username, expires_idle_days: 30}`. Rate-limited per IP with the existing `_nas_login_allowed` helper. |
| GET | `/api/cli/sessions` | web session or bearer | List caller's tokens: id, device, created, last used, `current` flag. |
| DELETE | `/api/cli/sessions/{id}` | web session or bearer | Revoke one of the caller's own tokens. |
| POST | `/api/cli/logout` | bearer | Revoke the presenting token. |
| GET | `/cli/install.sh` | none | Serves the installer script with `PUBLIC_BASE_URL` filled in (`text/x-shellscript`). |

### `_require_user` and share handling

- If `Authorization: Bearer ifd_…` is present, authenticate via `cli_tokens.lookup` and **ignore the cookie**. An invalid/expired bearer is a 401 (no fallback to the cookie).
- Otherwise the existing session path is unchanged.
- Bearer requests must not write `request.session` (no stray Set-Cookie). `_active_share` gets a bearer branch: share comes from `?share=` or `X-Drive-Share`, normalized by the existing `normalize_share_for_user`, not persisted.
- `/api/me` accepts bearer too so `infocus whoami` / `infocus shares` reuse it.

### User removal

`service_revoke_user` (and user-sync revoke) also call `cli_tokens.revoke_all(username)`. The fresh `pwd` check already blocks deleted users; this makes the DB state match.

### Upload conflict guard

`/api/upload` (and `/api/upload/complete` for chunked) accept an optional `expect_mtime_ns` form field. `-1` means "must not exist". Inside the writer, just before `os.replace`, compare against the target's current `st_mtime_ns`; mismatch → `FSError(409, "File changed on the Drive since you opened it")`. No field → current overwrite behavior (web UI unaffected). `list_dir` entries gain `mtime_ns` so the CLI can read it.

### Web UI

Account menu → **Terminal sign-ins**: modal listing device, "last used", "created", Revoke button; empty state explains `infocus login`. Uses `/api/cli/sessions`. Follows existing modal patterns in `app.js`; bump `?v=` per deploy rules.

## CLI (`cli/`, Go)

Module in `cli/` with its own `go.mod`, **standard library only** (no third-party modules to audit or pin). The Keychain is reached through `/usr/bin/security`, passing the token on stdin (`security -i`) so it never appears in argv. No server URL is baked into the binary (one release works for any deployment). The installer writes the serving Drive's `PUBLIC_BASE_URL` to `~/.config/infocus/config.json`; `--server` / `INFOCUS_SERVER` override it, and `login --server URL` saves it. With no server configured, commands exit 2 with a message to pass `--server`.

### Commands

| Command | Behavior |
|---------|----------|
| `login [--server URL] [--device NAME] [--no-browser]` | PKCE loopback flow (below). Default device = macOS computer name. `--no-browser` prints the link instead of opening it. |
| `logout` | `POST /api/cli/logout`, delete Keychain item. |
| `whoami` | username, email, active share, admin flag. |
| `shares` / `share use NAME` | list shares; set default share in config (sent as `X-Drive-Share`). |
| `ls [PATH]` | list folder (name, kind, size, modified). |
| `tree [PATH] [--depth N]` | recursive listing (client-side walk, default depth 3). |
| `search QUERY [--path P] [--limit N]` | `/api/search`. |
| `cat PATH` | stream file to stdout (`/api/download`). |
| `get PATH [LOCAL]` | download file; folders → zip via `/api/download/zip`. |
| `put LOCAL|- REMOTE_PATH [--force \| --expect-mtime-ns N]` | upload file or stdin. Refuses if the target exists unless `--force` (sends `expect_mtime_ns=-1` without force). `--expect-mtime-ns` gives agents the same no-clobber save as `edit`. Files ≥ 8 MiB use chunked init/chunk/complete with 4 parallel streams; a failed chunk is retried up to 3 times within the run (no cross-run resume). |
| `edit PATH` | download to a temp file, open `$VISUAL`/`$EDITOR` (fallback `nano`), on exit upload only if changed, with `expect_mtime_ns` from the download. On 409: keep the local copy, print its path, exit 4. |
| `mkdir PATH [-p]`, `mv SRC DEST_DIR`, `rename PATH NEW_NAME` | existing endpoints. |
| `rm PATH...` | `/api/delete` (moves to `#recycle` where the share has one; says so in output). Prompts on a TTY unless `-y`; never prompts when stdin is not a TTY. |
| `help agents` | prints a short guide for AI agents (commands, `--json`, exit codes, conflict handling). |
| `version` | version + commit. |

Global flags: `--json` (one JSON object/array on stdout, errors as `{"error": …, "status": …}` on stderr), `--share NAME`, `--server URL`.

Exit codes: 0 ok · 1 generic error · 2 usage · 3 not signed in / token expired (message: run `infocus login`) · 4 conflict (409) · 5 not found / permission denied.

### Login flow

1. Generate `state` (random 32 bytes) and PKCE `verifier` (random 32 bytes → base64url), `challenge = base64url(sha256(verifier))`.
2. Listen on `127.0.0.1:0`; open `{server}/cli/authorize?port=…&state=…&challenge=…&device=…` with `open`. Also print the URL in case the browser doesn't open.
3. Callback handler accepts only `GET /callback`, checks `state` in constant time, serves a small "You can close this tab" page, shuts down. Timeout 5 min.
4. `POST /api/cli/token {code, verifier}` → store token in Keychain (service `infocus-drive`, account = server host). Print "Signed in as student1".

### Credentials

Keychain only (macOS target). The token never goes in config files, argv, or logs. `--json` output never contains the token.

## Distribution

- GitHub Actions workflow (macOS runner) on tag `cli-v*`: `go test ./...`, build `darwin/arm64` + `darwin/amd64`, `lipo` into a universal binary, upload `infocus-darwin-universal.tar.gz` + `SHA256SUMS` to the GitHub Release.
- `app/static/cli/install.sh` served at `/cli/install.sh`, with the Drive's `PUBLIC_BASE_URL` substituted in when served (validated `https://` URL, shell-quoted): detects macOS, downloads the latest release asset + `SHA256SUMS` from GitHub, verifies the checksum, installs to `~/.local/bin/infocus` (no sudo), adds `~/.local/bin` to PATH in `~/.zshrc` if missing, writes the server URL to `~/.config/infocus/config.json`, runs `infocus version`. The script contains nothing secret.
- Unsigned binary: downloads via `curl` don't get the quarantine attribute, so Gatekeeper doesn't block it. Notarization is out of scope.
- Web UI "Terminal sign-ins" empty state shows the install one-liner.

## Security

- Tokens grant exactly the web user's permissions; all file ops still go through `as_user` and share normalization.
- Phishing a student into approving: the code is only redeemable with the verifier held by the CLI that started the flow, and it's delivered only to `127.0.0.1` on the approving browser's machine.
- CSRF on consent: `POST /api/cli/authorize` requires the web session plus a same-origin check; GET never issues codes.
- Brute force: codes and tokens are 256-bit random; `/api/cli/token` is rate-limited.
- Stored secrets: hashes only on the server; Keychain on the client.
- Existing hardening (session-secret check, inline allowlist + CSP sandbox, sign-in lockouts, userd group allowlist) is untouched.
- Public repo: tests and docs use fictional values (`student1`, `drive.example.com`).

## Error handling

- Server: explicit 400 for bad authorize params, 401 for bad/expired code or token, 403 for another user's token id, 409 for upload conflict, 429 for rate limit. No token or code values in logs.
- CLI: maps HTTP status to exit codes above; human messages say what to do next ("run `infocus login`", "file changed on the Drive — your edits are saved at …").

## Testing

Server (pytest, `tests/test_cli_tokens.py`, `tests/test_cli_api.py`):

- code issue → redeem with right verifier → token; wrong verifier / reused code / expired code → 401.
- token idle expiry, hard cap, revoke, `revoke_all`, deleted NAS user → 401.
- bearer works on `/api/files`, `/api/download`, `/api/upload`, `/api/me`; bearer requests set no cookie; invalid bearer does not fall back to cookie.
- `X-Drive-Share` honored for bearer and normalized for non-admins.
- authorize rejects bad port/state/challenge; POST without same-origin → 403; redirect host always `127.0.0.1`.
- `/api/cli/sessions` lists only own tokens; DELETE on another user's id → 403/404.
- upload with `expect_mtime_ns` match → ok; mismatch → 409; `-1` on existing file → 409.

CLI (Go, `httptest`):

- login flow end-to-end against a fake server (state mismatch rejected, timeout).
- each command's request shape and `--json` output; exit code mapping; `edit` conflict keeps local copy; `put` refuses overwrite without `--force`; chunked upload path for large input.

## Docs

- `docs/CLI.md`: install, login, commands, agent usage, troubleshooting, revoke.
- `AGENTS.md` API table: new `/api/cli/*` and `/cli/*` rows; key paths: `app/cli_tokens.py`, `cli/`.
- `docs/DEPLOY.md`: CLI release steps (tag `cli-vX.Y.Z`), `CLI_TOKENS_DB_PATH` env.
