# InFocus CLI (`infocus`)

Use InFocus Drive from the terminal — and let AI coding agents on your Mac use it too — with exactly the permissions of your Drive account.

## Install (macOS)

```sh
curl -fsSL https://drive.example.com/cli/install.sh | sh
```

The installer downloads the latest universal binary (Apple Silicon + Intel) from this repo's GitHub Releases, checks its SHA-256, installs it to `~/.local/bin/infocus` (no sudo), adds that folder to `PATH` in `~/.zshrc`, and saves the Drive's address in `~/.config/infocus/config.json`. Pin a version with `INFOCUS_VERSION=0.1.0`, or choose the folder with `INFOCUS_BIN_DIR`.

The Drive sidebar → **Install CLI** shows the exact command for your deployment.

## Sign in

```sh
infocus login
```

Your browser opens the Drive. Sign in the usual way (Google, email code, or NAS password), check that the page shows the same **confirmation code** as your terminal, and click **Allow**. The browser hands a one-time code back to the terminal over `127.0.0.1`; the terminal trades it for a token using a secret only it knows (PKCE), so a forwarded approval link is useless to anyone else.

- The token is stored in the macOS **Keychain** — never in files, logs or command arguments.
- It expires after **30 days without use** and **90 days** at most.
- See and revoke sign-ins in the Drive sidebar → **Install CLI**, or run `infocus logout`.
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
| `infocus put LOCAL\|- REMOTE [--force \| --expect-mtime-ns N]` | Upload a file or stdin. Refuses to overwrite unless `--force` |
| `infocus edit PATH` | Edit in `$VISUAL`/`$EDITOR`; saves back only if nobody changed the file meanwhile |
| `infocus mkdir PATH [-p]` | Create a folder |
| `infocus mv SRC... DEST_FOLDER` | Move into a folder |
| `infocus rename PATH NEW_NAME` | Rename in place |
| `infocus rm PATH... [-y]` | Move to the Recycle bin (asks first in an interactive terminal) |

Paths are relative to the share root: `infocus ls "Shows/Episode 1"`. Global flags: `--json`, `--share NAME`, `--server URL`.

Large files (≥ 8 MiB) upload in 32 MiB pieces over 4 parallel streams, like the web app.

## AI agents

Run `infocus help agents` for the agent guide. In short: every command takes `--json`; nothing prompts when stdin isn't a terminal; exit codes are `0` ok · `1` error · `2` bad usage · `3` not signed in · `4` conflict / already exists · `5` not found or no permission. For a safe edit, read `mtime_ns` from `infocus --json ls`, then `infocus put --expect-mtime-ns <value> …` — exit `4` means someone changed the file first.

Agents act as you. Only sign in on your own computer, and revoke the sign-in when you're done with a machine.

## How it works (for maintainers)

- `app/cli_tokens.py` — SQLite store at `CLI_TOKENS_DB_PATH` (default `/config/cli_tokens.sqlite3`). Only SHA-256 hashes of codes/tokens are stored; codes are single-use and live 60 s; uid/gid are re-read from `/etc/passwd` on every request.
- `app/main.py` — `GET /cli/authorize` (consent page, not frameable), `POST /api/cli/authorize` (plain form POST, web session + same-origin; answers with a 303 to `http://127.0.0.1:<port>/callback`, so page script never sees the one-time code), `POST /api/cli/token` (limits failed attempts per IP), `GET/DELETE /api/cli/sessions`, `POST /api/cli/logout`, `GET /cli/install.sh`.
- `Authorization: Bearer ifd_…` is accepted by `_require_user`, so every file endpoint enforces the same `as_user` permissions. A bad bearer is a 401 even alongside a valid cookie. Bearer requests never write the session cookie, can't mint more tokens, LAN handoffs or personal-folder unlocks, and choose shares per request via `X-Drive-Share`. Tokens are bound to the uid they were issued to, and the token DB is only touched under `fsops.as_root()`.
- Removing a user (`revoke_user`) revokes all of their terminal sign-ins.
- `/api/upload` and `/api/upload/complete` accept `expect_mtime_ns` (`-1` = must not exist) and return 409 when the target changed.
- `cli/` — Go, standard library only. Releases: see [DEPLOY.md](DEPLOY.md#cli-releases).

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `not signed in` / exit 3 | `infocus login` (the token expired, was revoked, or the account was removed) |
| `no Drive server configured` | `infocus login --server https://drive.example.com` |
| `command not found: infocus` | Open a new terminal, or add `~/.local/bin` to `PATH` |
| Browser says the link is broken | Run `infocus login` again; links are single-use and expire with the terminal's 5-minute wait |
| `edit` says the file changed | Someone saved first. Your version is kept at the path printed; merge and `put` again |
