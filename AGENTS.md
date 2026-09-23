# AGENTS.md — InFocus Drive

**Read this first** when starting work on this repo. For deep system detail see [`docs/SYSTEM.md`](docs/SYSTEM.md). For deploy steps see [`docs/DEPLOY.md`](docs/DEPLOY.md).

> **⚠️ This is a public, open-source repo (MIT).** Everything you commit or push is world-readable and permanent. It serves a school, and its users are minors. Never commit secrets, `.env`, secret-manager ids, internal IPs or hostnames, or real student/staff names, usernames or emails (use fictional values like `student1` or `admin@example.org`, including in tests and commit messages). Review `git diff --cached` and run `gitleaks git .` before every commit. Keep private operator notes in gitignored `ops-private/` and never push them. Don't weaken the security hardening. Full rules: [`CLAUDE.md`](CLAUDE.md) → "Public repository".

## What this is

Custom web file browser for the **InFocus** share on a Ugreen NAS:

| | |
|--|--|
| **Public URL** | e.g. `https://drive.example.com` (original deployment: drive.infocuspaly.com) |
| **UGOS admin** | e.g. `https://ugos.example.com/` (`UGOS_ADMIN_PATH`; linked from sidebar) |
| **Local repo** | your clone of this repo |
| **NAS deploy path** | `/volume1/docker/infocus-drive` |
| **Data share** | `/volume2/InFocus Drive` → container `/data/InFocus Drive` |
| **NAS IP** | your NAS LAN IP, e.g. `192.168.1.50` (often unreachable off-site) |

Stack: **FastAPI + Docker (host network) + nginx gateway + Cloudflare Tunnel**. Frontend is vanilla ES modules (no bundler).

## Non-negotiables

1. **Never overwrite NAS `.env`** — OAuth secrets live only on the NAS. Deploy tar excludes `.env`.
2. **UI is baked into the image** (`COPY app/ /app/`). Static changes require `docker compose up -d --build`.
3. **Cache-bust static assets** on every UI deploy: bump `?v=…` on `index.html` script/link tags **and** matching `import` query strings in `app.js` (Cloudflare caches `/assets/*` for hours).
4. **SSH via Cloudflare Access**, not Tailscale, for host ports:
   - Host: `$NAS_SSH_USER@$NAS_SSH_HOST` (e.g. `admin@ssh.example.com`)
   - `PubkeyAuthentication=no` (agent keys fail first otherwise)
   - `ProxyCommand=cloudflared access ssh --hostname %h`
   - Read the NAS password from your secret manager into `SSHPASS`
5. **No macOS rsync** — use `tar` with `COPYFILE_DISABLE=1`.
6. **File ops run as the NAS user** (`seteuid` / ACLs). Container runs as root with `SETUID`/`SETGID`.

## Secrets

- Read the NAS password from your secret manager into `SSHPASS` only for the deploy session. `scripts/deploy-rebuild.sh` reads `NAS_SSH_HOST`, `NAS_SSH_USER`, `NAS_DEPLOY_PATH` and `SSHPASS` from the environment.
- Never print `SSHPASS` or store secret values in files, logs, chat, or memory.
- Private operator notes (if present locally): `ops-private/` — gitignored, never commit.

## Auth model

- Google OAuth; domains **`pausd.org`** and **`pausd.us`**
- NAS username = email local-part (`student1@pausd.org` → `student1`)
- Overrides: `config/user_map.json` (untracked; copy `config/user_map.example.json`) → mounted at `/config/user_map.json`
- Denied users get a friendly “ask an adviser” login state

## Finder / network drive (SMB)

- Native **UGOS Samba**, not the web app. Auth = **NAS username + password**.
- On LAN: `smb://<NAS LAN IP>` (share picker). WARP not required.
- **Remote:** Cloudflare WARP team `your-team`, tunnel private network = NAS LAN IP `/32`, enrollment allowlist (exact emails only). Guide: [`docs/REMOTE-SMB-WARP.md`](docs/REMOTE-SMB-WARP.md).
- UI: sidebar **Connect in Finder**. LAN: [`docs/FINDER-NETWORK-DRIVE.md`](docs/FINDER-NETWORK-DRIVE.md).
- Env on NAS: `WARP_TEAM_NAME`, `WARP_ENROLL_URL`, `SMB_HOST` (see `.env.example`).
- **The web hostname (e.g. `drive.example.com`) is not a valid Connect to Server host** (HTTPS browser only).
- WARP client install (macOS): https://developers.cloudflare.com/warp-client/get-started/macos/

## UX rules (user-requested)

| Interaction | Behavior |
|-------------|----------|
| Click **folder** | Open / navigate (not select) |
| Click **checkbox** | Select |
| Click **previewable file** | Open lightbox (image/video/audio/pdf/text) |
| Click other files | Select |
| Drag items onto folders / crumbs / sidebar | Move via `/api/move` |
| OS file drop | Upload into current folder |
| Theme toggle | Main chrome **and** sidebar (CSS `--sb-*` tokens) |
| Open folder | Don’t flash skeleton if load &lt; ~200ms (keep stale list) |

## Key paths

```
app/main.py          FastAPI routes, OAuth, speedtest, streaming upload
app/fsops.py         Path-safe FS under drive root; as_user(uid,gid)
app/users.py         Email → NAS user
app/config.py        Settings from env
app/file_links.py    Signed public file-share tokens
app/static/app.js    UI state, tree, DnD, preview, speed test
app/static/api.js    Fetch/XHR client
app/static/format.js Sizes, kinds, previewKind()
app/static/share.js  Public `/s/{token}` page (no Drive chrome)
app/static/app.css   Design tokens + components
app/static/index.html Shell + SVG sprite
app/static/share.html Public share page shell
nginx.conf.example   Gateway template (:8790, stream large bodies); copy to untracked nginx.conf, set NAS IP
docker-compose.yml   infocus-drive :8787 + gateway host network (requires .env keys, see docs/DEPLOY.md)
```

## API surface (authenticated unless noted)

| Method | Path | Notes |
|--------|------|--------|
| GET | `/api/health` | Unauthenticated |
| GET | `/api/me` | Session user |
| GET | `/api/usage` | Disk meter |
| GET | `/api/files?path=` | List dir |
| GET | `/api/search?q=&path=&limit=` | Recursive smart search (name/path/kind) |
| POST | `/api/mkdir` `/rename` `/move` `/delete` | Form fields |
| POST | `/api/upload` | Multipart; **streamed** to disk (small files) |
| POST | `/api/upload/init` | Start chunked multi-stream upload session |
| PUT | `/api/upload/chunk?upload_id=&index=` | Raw body ≤32 MiB piece |
| GET | `/api/upload/status` | Resume: which chunks received |
| POST | `/api/upload/complete` `/api/upload/abort` | Assemble or discard session |
| POST | `/api/file-link` | Mint public file URL (`path`, `days` 1–30, default 7). Not `POST /api/share` (NAS switcher). |
| GET | `/s/{token}` | Public share page (no login) |
| GET | `/api/s/{token}` | Public file metadata |
| GET | `/api/s/{token}/file?inline=` | Public download / preview stream |
| GET | `/api/download?path=&inline=` | `inline=1` for preview |
| GET | `/api/download/zip?path=&path=` | STORE zip stream (files + folders; folders expanded) |
| GET | `/api/speedtest/download?size=` | Synthetic zeros, max 512MiB |
| POST | `/api/speedtest/upload` | Piece max 32MiB; client multi-streams |
| GET/POST | `/auth/login` `/auth/callback` `/auth/logout` | OAuth |

## Frontend modules

Cache-busted imports (example — always bump together):

```js
import * as api from "./api.js?v=YYYYMMDD-tag";
import { … } from "./format.js?v=YYYYMMDD-tag";
```

`index.html`:

```html
<link rel="stylesheet" href="/assets/app.css?v=YYYYMMDD-tag" />
<script src="/assets/app.js?v=YYYYMMDD-tag" type="module"></script>
```

## When debugging

| Symptom | Likely cause |
|---------|----------------|
| Blank / old UI after deploy | CF cache; bump `?v=` or purge |
| SSH “Permission denied” with agent | Forgot `PubkeyAuthentication=no` |
| rsync invalid path | Use tar, not openrsync |
| Large upload dies near end | Fixed with streaming + multi-stream speedtest + nginx `proxy_request_buffering off` |
| Skeleton flicker | `SKELETON_DELAY_MS` / `showSkeleton` logic in `loadFolder` |
| Video looks letterboxed in double frame | Use `viewer--video` cinema CSS (already implemented) |

## What not to do

- Don’t commit real `.env` or OAuth secrets
- Don’t use WebFetch/`curl` for authenticated private Google/secret-manager resources from agent sandbox if blocked by local rules
- Don’t force-push or rewrite published deploy history on the NAS
- Don’t “fix” `config/user_map.json` without checking live NAS copy

## Related hostnames

| Host | Role |
|------|------|
| `drive.example.com` | This app (tunnel → nginx 8790 → 8787; check live tunnel) |
| `ugos.example.com` | UGOS control panel |
| `ssh.example.com` | SSH Access to NAS |
| `packages.example.com` | infocus-packages (Vercel); may upload to Drive via service API |

Tunnel config lives in Cloudflare; local nginx is the compose gateway in front of uvicorn.

## Packages NAS storage (related repo)

| | |
|--|--|
| Packages repo | infocus-packages (separate repo) |
| Docs | `docs/NAS-STORAGE.md` in that repo |
| Drive service | `/api/service/*` + `PACKAGES_SERVICE_*` env |
| Layout | `Package Cycles/{cycle}/{folder}/{file}.mp4` (+ optional `.poster.jpg`) |
| Compose | Must inject `PACKAGES_SERVICE_TOKEN/USER/ROOT` into container |
| CORS | Required for browser uploads from packages origin |

New package uploads with `MEDIA_STORAGE_PROVIDER=NAS` do **not** use Bunny processing.
