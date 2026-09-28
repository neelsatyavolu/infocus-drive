# InFocus CLI (`infocus`)

Use InFocus Drive from the terminal — and let AI coding agents on your Mac use it too — with exactly the permissions of your Drive account.

## Install (macOS)

```sh
curl -fsSL https://drive.example.com/cli/install.sh | sh
```

The installer downloads the latest universal binary (Apple Silicon + Intel) from this repo's GitHub Releases, checks its SHA-256, installs it to `~/.local/bin/infocus` (no sudo), adds that folder to `PATH` in `~/.zshrc`, and saves the Drive's address in `~/.config/infocus/config.json`. Pin a version with `INFOCUS_VERSION=0.1.0`, or choose the folder with `INFOCUS_BIN_DIR`.

The Drive sidebar → **Mac app & CLI** shows the exact command for your deployment.

## Sign in

```sh
infocus login
```

Your browser opens the Drive. Sign in the usual way (Google, email code, or NAS password), check that the page shows the same **confirmation code** as your terminal, and click **Allow**. The browser hands a one-time code back to the terminal over `127.0.0.1`; the terminal trades it for a token using a secret only it knows (PKCE), so a forwarded approval link is useless to anyone else.

- The token is stored in the macOS **Keychain** — never in files, logs or command arguments.
- It expires after **30 days without use** and **90 days** at most.
- See and revoke sign-ins in the Drive sidebar → **Mac app & CLI**, or run `infocus logout`.
- `infocus login --no-browser` prints the approval link instead of opening it.

## Commands

| Command | What it does |
|---------|--------------|
| `infocus whoami` | Signed-in account and active share |
| `infocus shares` / `infocus share use NAME` | List shares / set the default share |
| `infocus ls [PATH]` | List a folder |
| `infocus tree [PATH] [--depth N]` | Recursive listing (default depth 3) |
| `infocus search QUERY [--path P] [--limit N]` | Name search |
| `infocus cat PATH` | Print a file |
| `infocus get PATH [LOCAL\|-] [--force]` | Download (folders as `.zip`) |
| `infocus put [-r] [--force] SRC... DEST` | Upload files, whole folders (`-r`) or stdin (`-`). Existing files are skipped unless `--force`; single files also take `--expect-mtime-ns N` |
| `infocus sync LOCAL_DIR REMOTE_DIR [--dry-run]` | Upload only new or changed files from a folder. Never deletes anything on the Drive |
| `infocus edit PATH` | Edit in `$VISUAL`/`$EDITOR`; saves back only if nobody changed the file meanwhile |
| `infocus mkdir PATH [-p]` | Create a folder |
| `infocus mv SRC... DEST_FOLDER` | Move into a folder |
| `infocus rename PATH NEW_NAME` | Rename in place |
| `infocus rm PATH... [-y]` | Move to the Recycle bin (asks first in an interactive terminal) |
| `infocus unlock [--key-file PATH]` / `infocus unlock --nas-sign-in` | Unlock your encrypted personal folder for 24 hours (encryption password prompt, key file or stdin). If it exits 6, UGOS first wants the NAS owner sign-in (`--nas-sign-in`: NAS password, then authenticator code) |
| `infocus webdav [--addr 127.0.0.1:PORT] [--name NAME]` | Serve your shares to Finder over a local WebDAV server (password on stdin). Used by the Mac app — see [MAC-APP.md](MAC-APP.md) |
| `infocus update` | Update to the latest release now |
| `infocus config [auto-update on\|off]` | Show settings / turn auto-update off or on |

Paths are relative to the share root: `infocus ls "Shows/Episode 1"`. Global flags: `--json`, `--share NAME`, `--server URL`.

## Uploading lots of files

- `infocus put a.mov b.mov *.jpg "Shows/Ep1/"` uploads several files into a folder (created if missing). `infocus put -r ./Footage "Shows/Ep1/"` uploads a whole folder as `Shows/Ep1/Footage/…`, recreating subfolders.
- System files (`.DS_Store`, `._*`, `Thumbs.db`, temp/partial downloads) and symlinks are left out.
- 3 files upload at once; files ≥ 8 MiB go in 32 MiB pieces over 4 streams, like the web app. A progress line shows files, bytes, speed and time left.
- If a file already exists it's skipped (exit `4` at the end) unless you pass `--force`; other files still upload.
- **Resume:** if a large upload is interrupted (Ctrl-C, network drop, laptop sleep), run the same command again within 24 hours and only the missing pieces are sent. State lives in `~/.config/infocus/uploads/`.
- **Sync:** `infocus sync ./Footage "Shows/Ep1"` uploads files that are new or different (same-size files are compared by content fingerprint). Re-running it after a finished sync uploads nothing. It never deletes or silently overwrites: if the Drive copy changed since sync looked, that file is reported as a conflict. Use `--dry-run` to see the plan first.

## Updates

infocus updates itself: at most once an hour, after a command you ran in a terminal, it checks this repo's latest `cli-v*` release, verifies the download's SHA-256, and replaces the binary in place. It never updates during `--json` output or when run by scripts or agents (stdin not a terminal). Run `infocus update` to update right away. Turn it off with `infocus config auto-update off` or `INFOCUS_NO_UPDATE=1`.

## AI agents

Run `infocus help agents` for the agent guide. In short: every command takes `--json`; nothing prompts when stdin isn't a terminal; exit codes are `0` ok · `1` error · `2` bad usage · `3` not signed in · `4` conflict / already exists · `5` not found or no permission. For a safe edit, read `mtime_ns` from `infocus --json ls`, then `infocus put --expect-mtime-ns <value> …` — exit `4` means someone changed the file first.

Agents act as you. Only sign in on your own computer, and revoke the sign-in when you're done with a machine.

## How it works (for maintainers)

- `app/cli_tokens.py` — SQLite store at `CLI_TOKENS_DB_PATH` (default `/config/cli_tokens.sqlite3`). Only SHA-256 hashes of codes/tokens are stored; codes are single-use and live 60 s; uid/gid are re-read from `/etc/passwd` on every request.
- `app/main.py` — `GET /cli/authorize` (consent page, not frameable), `POST /api/cli/authorize` (plain form POST, web session + same-origin; answers with a 303 to `http://127.0.0.1:<port>/callback`, so page script never sees the one-time code), `POST /api/cli/token` (limits failed attempts per IP), `GET/DELETE /api/cli/sessions`, `POST /api/cli/logout`, `GET /cli/install.sh`.
- `Authorization: Bearer ifd_…` is accepted by `_require_user`, so every file endpoint enforces the same `as_user` permissions. A bad bearer is a 401 even alongside a valid cookie. Bearer requests never write the session cookie, can't mint more tokens or LAN handoffs, and choose shares per request via `X-Drive-Share`. They can unlock only their own encrypted personal folder (`/api/personal/unlock`, `/api/personal/auth`), with the same owner check, HTTPS rule and attempt limit as the web app; the OTP step returns an encrypted `pending` token bound to that sign-in (5 minutes, at most 5 codes, single use; `410` = start over with the password) instead of using the cookie session. Wrong NAS passwords count toward the same 5-failure / 15-minute account lockout as the NAS sign-in, and 422 errors never echo submitted values. Tokens are bound to the uid they were issued to, and the token DB is only touched under `fsops.as_root()`.
- Removing a user (`revoke_user`) revokes all of their terminal sign-ins.
- `/api/upload` and `/api/upload/complete` accept `expect_mtime_ns` (`-1` = must not exist) and return 409 when the target changed.
- `cli/` — Go; standard library plus `golang.org/x/net/webdav` for `infocus webdav` (`cli/internal/davfs`). Releases: see [DEPLOY.md](DEPLOY.md#cli-releases).

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `not signed in` / exit 3 | `infocus login` (the token expired, was revoked, or the account was removed) |
| `no Drive server configured` | `infocus login --server https://drive.example.com` |
| `command not found: infocus` | Open a new terminal, or add `~/.local/bin` to `PATH` |
| Browser says the link is broken | Run `infocus login` again; links are single-use and expire with the terminal's 5-minute wait |
| `edit` says the file changed | Someone saved first. Your version is kept at the path printed; merge and `put` again |
