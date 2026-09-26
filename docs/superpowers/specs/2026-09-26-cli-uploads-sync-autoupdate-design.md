# InFocus CLI — bulk uploads, resume, sync, auto-update

Status: implemented · 2026-09-26 · builds on [2026-09-24-infocus-cli-design.md](2026-09-24-infocus-cli-design.md)

## Goal

Make `infocus` good at getting lots of footage onto the Drive: many files or whole folders in one command, visible progress, uploads that survive interruptions, a cheap re-runnable `sync`, and a CLI that keeps itself up to date.

Client-only change. The server already has everything needed: chunked upload with `/api/upload/status` (sessions live 24 h), `/api/upload/fingerprint`, and the `expect_mtime_ns` overwrite guard.

### Success criteria

1. `infocus put a.mp4 b.mp4 *.jpg "Shows/Ep1/"` and `infocus put -r ./Footage "Shows/Ep1/"` upload everything, recreating subfolders.
2. A conflict or failure on one file doesn't stop the others; the exit code reports the worst outcome.
3. Killing a large upload and re-running the same command sends only the missing pieces.
4. Re-running `infocus sync ./Footage "Shows/Ep1"` after a completed sync uploads nothing and never deletes or silently overwrites anything on the Drive.
5. An interactive user on an old version ends up on the latest release without doing anything; agents and `--json` output are never affected mid-run.

### Non-goals

Two-way sync or deleting remote files, download-side sync, watching folders, Linux/Windows, release signing beyond the existing SHA-256 check.

## 1. `put` with many files and folders

`infocus put [-r] [--force] SRC... DEST`

| Invocation | Meaning |
|------------|---------|
| one file, `DEST` is an existing folder or ends in `/` | upload into it, keep the name (unchanged) |
| one file, other `DEST` | upload as that file path (unchanged) |
| `-` (stdin) | as today; `DEST` must be a file path |
| several files, or any folder with `-r` | `DEST` is a folder, created (`mkdir -p`) if missing |
| a folder without `-r` | usage error: "`Footage` is a folder; use -r" |

- `-r` walks folders, recreating relative subfolders under `DEST/<folder name>/` (like `cp -r src dest/`). Skips symlinks (noted once) and junk files using the same list as the server's hidden-junk filter (`.DS_Store`, `._*`, `Thumbs.db`, `desktop.ini`, `.Spotlight-V100`, `.Trashes`, `*.partial`, `*.crdownload`, `*.ug-tmp`, …).
- Up to **3 files in parallel** (as in the web app); files ≥ 8 MiB still use 4 chunk streams each.
- Existing target without `--force`: that file is reported as `exists` and skipped; the rest continue. Destination folders are listed once up front so existing files are skipped before any bytes are sent (the server's create-only check still catches races).
- Result per file: `uploaded`, `exists`, `failed` (with reason). Exit code: `0` all uploaded · `4` if any `exists` and none failed · `1` if any failed · plus existing `3`/`5` for auth / permission on the whole run.
- `--json`: one object `{uploaded:[…], exists:[…], failed:[{path, error}]}`.

## 2. Progress and resume

**Progress.** When stderr is a terminal and `--json` is off, a single redrawn line on stderr: `3/12 files · 1.4 GB / 6.0 GB · 48 MB/s · 1m35s left · current: interview-02.mov`. Otherwise silent until the summary.

**Resume.** For chunked uploads (≥ 8 MiB) the CLI stores `~/.config/infocus/uploads/<key>.json` (`0600`) holding `upload_id`, chunk size and total. `key = sha256(server | share | remote path | local absolute path | size | mtime_ns)`, so a changed local file never resumes into an old session.

- On start: if a state file exists, `GET /api/upload/status`; if the session is alive, send only chunks not in `received`, and print `Resuming interview-02.mov (61% already on the Drive)`. If the server says it's gone (404/expired), delete the state and start fresh.
- On success or a definite failure (4xx other than 404 on the session): delete state. On interrupt (Ctrl-C, network loss, crash): keep it.
- Stale state files older than 24 h are removed on the next `put`/`sync`.

## 3. `infocus sync LOCAL_DIR REMOTE_DIR [--dry-run]`

One-way, Mac → Drive. Walks `LOCAL_DIR` with the same skip rules as `put -r`; lists `REMOTE_DIR` recursively (creating it and missing subfolders as needed).

| Local vs Drive | Action |
|----------------|--------|
| missing on Drive | upload (create-only, `expect_mtime_ns=-1`) |
| different size | upload, only if the Drive copy is unchanged since listing (`expect_mtime_ns=<listed>`) |
| same size | compare fingerprints (server `/api/upload/fingerprint`; CLI computes the same: SHA-256 over the concatenated SHA-256 digests of each 8 MiB piece). Equal → `unchanged`; different → upload as above |
| only on Drive | left alone; counted as `drive_only` |
| folder vs file clash | `conflict`, skipped |

- A 409 on upload is reported as `conflict` (someone changed it meanwhile), never retried with force.
- **Never deletes** anything on the Drive.
- `--dry-run` prints the plan (`upload` / `unchanged` / `conflict` / `drive_only`) and uploads nothing.
- Uses the same parallelism, progress and resume as `put`.
- Summary + exit codes as in `put` (`4` if any conflict).

## 4. Auto-update

**Where versions come from.** `HEAD https://github.com/neelsatyavolu/infocus-drive/releases/latest` without following redirects → `Location: …/releases/tag/cli-vX.Y.Z`. This is the web redirect, not the REST API, so a whole campus behind one IP doesn't hit the API's 60 requests/hour limit. A latest release whose tag isn't `cli-v*` is ignored.

**Automatic install (default on).**
- Checked at most once per 24 h (`~/.config/infocus/update-check.json`: `checked_at`, `latest`), **after** a successful command, only when stdin and stderr are terminals, `--json` is off, and the running build isn't `dev`.
- If newer: print `Updating infocus 0.1.1 → 0.2.0…`, download `infocus-darwin-universal.tar.gz` + `SHA256SUMS` from that tag, verify the checksum, extract to a temp file **in the same folder as the running binary** (`os.Executable()` with symlinks resolved), `chmod 0755`, and `rename` over it (atomic; the running process is unaffected). Print `Updated.`
- Any failure (offline, checksum mismatch, folder not writable, e.g. a Homebrew install) prints one line (`infocus 0.2.0 is available — run infocus update`) and doesn't retry until the next day. A checksum mismatch never installs anything.
- Time limits: 3 s for the check, 60 s for the download.
- Opt out: `infocus config auto-update off` (stored as `"auto_update": false` in `config.json`) or `INFOCUS_NO_UPDATE=1`.

**`infocus update`.** Checks now and installs if newer, regardless of TTY or the daily limit; `--json` reports `{from, to, updated}`. Exit `0` when up to date or updated, `1` on failure.

**Trust note.** The checksum comes from the same GitHub release, so auto-update trusts the repo's GitHub account exactly as much as the installer already does. Signing releases with a key held outside GitHub would close that gap later.

## Code layout (`cli/`)

- `internal/api/upload.go` — add resumable chunked upload (state callbacks), `UploadStatus`, `Fingerprint`.
- `internal/transfer/` (new) — local walk + junk filter, fingerprint, resume state store, parallel batch runner, progress renderer. Pure logic, unit-tested without a server.
- `internal/update/` (new) — version compare, latest-version lookup, download + verify + atomic replace, daily-check state. Base URL and executable path injectable for tests.
- `internal/app/` — `put` (extended), `sync`, `update`, `config` commands; post-command auto-update hook in `Run`.

## Testing

- Unit: junk filter, walk (subfolders, symlinks skipped), fingerprint matches the server's algorithm on 0 B / small / multi-chunk inputs, resume key changes when size/mtime change, semver compare, tag parsing, checksum mismatch refusal, atomic replace leaves the old binary intact on failure.
- Command tests against the fake Drive: multi-file and `-r` puts (conflict continues, exit codes, JSON summary), resume after a forced failure sends only missing chunks, sync plan (new/changed/unchanged/drive_only/conflict, dry-run uploads nothing, never deletes), auto-update against a fake release server (updates when newer, skips in `--json`/non-TTY, respects opt-out and the daily limit).
- Manual: real upload of a folder with a ~1 GB file, interrupted and resumed, against production; `infocus update` from 0.1.1.

## Docs

`docs/CLI.md` (new commands, resume, sync semantics, auto-update + opt-out), `infocus help agents` (multi-file `put`, `sync --dry-run`, exit codes).
