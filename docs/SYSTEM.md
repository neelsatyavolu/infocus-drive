# InFocus Drive — system context

Architecture and behavior reference for a production deployment. Prefer this + `AGENTS.md` over chat history. Hostnames below use `example.com` placeholders.

---

## 1. Purpose

Replace / augment UGOS file browsing for the **InFocus Drive** share with a custom UI branded for InFocus (PAUSD video / production program). Teachers and students sign in with PAUSD Google accounts and get the same POSIX permissions as their matching NAS username.

---

## 2. Infrastructure map

```
Browser
  │ HTTPS
  ▼
Cloudflare (CDN + Tunnel public hostname)
  │
  ├─ drive.example.com  ──tunnel──► NAS host network
  │                                       │
  │                                       ├─ nginx :8790  (container infocus-drive-gateway)
  │                                       │     proxy_pass → 127.0.0.1:8787
  │                                       │
  │                                       └─ uvicorn FastAPI :8787  (container infocus-drive)
  │                                             │
  │                                             └─ bind mount: /volume2/InFocus Drive
  │
  ├─ ugos.example.com ──► UGOS :9999 (or via /admin on drive historically)
  └─ ssh.example.com  ──Access SSH──► NAS :22
```

### Docker (`docker-compose.yml`)

| Service | Image | Network | Role |
|---------|-------|---------|------|
| `infocus-drive` | build `Dockerfile` | **host** | FastAPI on 8787 |
| `infocus-drive-gateway` | nginx:1.27-alpine | **host** | nginx on 8790 → app |

**Why host network:** Tunnel and UGOS expect fixed host ports; simplifies reaching local services.

**Capabilities:** `SETUID`/`SETGID`, `user: "0:0"` so the app can `seteuid` to the NAS user for ACL-respecting IO.

**Volumes:**

- `"/volume2/InFocus Drive:/data/InFocus Drive"`
- `/etc/passwd`, `/etc/group` (ro) for uid/gid resolution
- `./config:/config` (`user_map.json` — untracked; copy from `config/user_map.example.json`)

**Env (on NAS only, never in git):** `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `SESSION_SECRET`, `PUBLIC_BASE_URL`, `ALLOWED_EMAIL_DOMAINS`, etc. See `.env.example`. Compose fails fast unless `PUBLIC_BASE_URL`, `ALLOWED_EMAIL_DOMAINS`, `GOOGLE_HOSTED_DOMAIN`, `USER_SYNC_PROTECTED_USERNAMES`, `USER_SYNC_PROTECTED_EMAILS`, `UGOS_ADMIN_PATH`, `PACKAGES_ROSTER_URL` and `UGOS_ADMIN_USER` are set.

### Cloudflare Tunnel notes

- Public hostname `drive.example.com` routes to the app (and historically path `/admin*` → UGOS).
- UGOS is fragile under path prefixes → full portal also at **`https://ugos.example.com/`**.
- Edge caches static assets aggressively (`max-age` ~4h unless headers/query strings fight it). App sets short `Cache-Control` / `CDN-Cache-Control`; **still bump `?v=` on every UI ship**.

### NAS access from laptops

- **LAN IP** (e.g. `192.168.1.50`) — ping/SSH often fail off campus/VPN.
- **SSH:** `cloudflared access ssh` via an Access hostname (e.g. `ssh.example.com`).
- **Finder / network drive (SMB):** `smb://192.168.1.50` (your NAS LAN IP) with **NAS username + password** (not Google). Connect to the bare server to pick among all shares your ACL allows. LAN: [FINDER-NETWORK-DRIVE.md](./FINDER-NETWORK-DRIVE.md). **Remote:** Cloudflare WARP team `your-team`, tunnel private network = NAS LAN IP `/32`, enrollment allowlist (exact emails) — [REMOTE-SMB-WARP.md](./REMOTE-SMB-WARP.md). UI: sidebar **Connect in Finder**.
- **Web multi-share (NAS admins only):** Users in Linux group `admin` see a breadcrumb dropdown to switch among volume2 shares (InFocus Drive, Photos, Admin, AI Documentary, …) plus InFocus Editing. Non-admins stay on InFocus Drive. Packages service always uses InFocus Drive.
- **Do not** put the web hostname (e.g. `drive.example.com`) in Connect to Server — that hostname is HTTPS web only.
- Keep the NAS password and Google OAuth client secrets in your secret manager; they belong only in the NAS `.env`.

---

## 3. Backend architecture

### `app/main.py`

- FastAPI app, session middleware (`itsdangerous` / Starlette sessions), cookie `infocus_drive_session`.
- Session cookie `max_age` is 5 days (`session_max_age`; override with `SESSION_MAX_AGE`).
- `https_only=False` on cookie because TLS terminates at Cloudflare; backend is plain HTTP.
- Static files: `app.mount("/assets", StaticFiles(...))`.
- Middleware short-caches `/assets/*` and HTML shell.

### Auth flow

**Sign-in:** the sign-in screen offers **Continue with Google** and **Sign in with email**. For email sign-in, enter the registered email, then the six-digit code sent to that inbox in the same browser/page. Codes expire in 10 minutes, work once, and stop after five wrong guesses. Resend after one minute, up to five sends per email per hour. Manual NAS password/2FA sign-in remains available.

`POST /auth/email/request` and `/auth/email/verify` use the existing roster/protected-account/user-map policy and `ensure_for_login`; no NAS accounts are provisioned before email verification. Codes and browser challenges are HMAC-hashed in SQLite at `EMAIL_SIGN_IN_DB_PATH` (default `/config/email_sign_in.sqlite3`, on the existing persistent config mount). SQLite transactions serialize resends/guesses/redemptions across workers and restarts. Sessions retain the existing Drive user/uid/gid/share format and LAN handoff support.

**Rollout:** set `RESEND_API_KEY` and `RESEND_FROM_EMAIL` to a verified sender in the NAS environment, keeping all existing secrets intact. `SESSION_SECRET` must be configured. Compose passes these through; rebuild the Drive image for the new backend/UI. SQLite creates its own table; no Portal database migration is needed for Drive. Verify email delivery and sign-in at your `PUBLIC_BASE_URL` after deployment. Google sign-in is available alongside email codes; both preserve the destination folder.

Original Google flow:

1. `/auth/login` → Google OAuth (`hd` prefers Workspace domain). OAuth `state` is a **signed** token (`itsdangerous`, salt `oauth-state`) so callback does not depend on the session cookie host. This matters because `redirect_uri` is always `PUBLIC_BASE_URL`, while campus LAN prefer may open the app on `LAN_ORIGIN`.
2. `/auth/callback` → verify signed state → token + userinfo → domain check → map email → NAS user (`users.resolve_nas_user`). If login started on LAN (`state.lan`), mint a LAN handoff and redirect to `/auth/lan-handoff` on the LAN origin.
3. Session stores `email`, `name`, `picture`, `username`, `uid`, `gid`.
4. Unmapped / unauthorized → redirect to login with `error=not_authorized`.
5. Client `maybePreferLan` only switches **after** sign-in (handoff token); unsigned users stay on the public host for OAuth.

### `app/fsops.py`

- `resolve_rel(path)` — blocks `..`, stays under `DRIVE_ROOT`.
- `as_user(uid, gid)` — temporary euid/egid for ops.
- `list_dir`, `mkdir`, `rename`, `move_item`, `delete`, `write_upload_stream`, `open_for_download`, `disk_usage`.
- **Hidden junk:** filters incomplete downloads / temp markers (e.g. `.ug-tmp`, `.tmp`, `.partial`, `.crdownload`). **`#recycle` is NOT hidden** — shown as recycle bin.
- Move: `shutil.move` into destination **directory** (`dest_dir / src.name`).
- **Storage meter** (`/api/usage`): `shutil.disk_usage(drive_root)` = **whole volume** behind the mount (same as `df` on `/volume2`), not a per-share quota. UI label: “NAS volume”; tooltip explains free/used.

### Uploads

- **Streamed** simple path: async reader → bounded queue → `write_upload_stream` under `as_user`.
- Writes `.<name>.partial` then `os.replace`. Cap **2 GiB**.
- **Chunked multi-stream** (files ≥ 8 MiB): `POST /api/upload/init` → parallel `PUT /api/upload/chunk` (≤32 MiB) → `POST /api/upload/complete`. Staging under `/tmp/ifd-chunk-uploads/`. Client keeps `upload_id` in `localStorage` for **resume** after drop.
- Client runs **3 files in parallel**; each large file uses up to **6 chunk streams**.
- nginx: `proxy_request_buffering off`, `proxy_buffering off`, long timeouts — critical for large files through tunnel.

### Downloads / preview

- `GET /api/download?path=&inline=0|1`
- `GET /api/download/zip?path=&path=` — streaming **STORE** zip for multi-select and **folders** (folders expanded recursively; max 10k files / 8 GiB after expansion). Skips symlinks, `#recycle`, and temp/junk files.
- MIME via `mimetypes`; `content_disposition_type` attachment vs inline.
- Previewable kinds (browser): images (png/jpg/webp/…), video (mp4/webm/mov/…), audio, pdf, text-ish.

### Speed test

| | |
|--|--|
| Download | `GET /api/speedtest/download?size=` streams zeros (2 MiB chunks), max **512 MiB** |
| Upload piece | `POST /api/speedtest/upload` max **32 MiB** per request |
| Client | **6 parallel streams**; upload split into ≤32 MiB pieces + retry |
| Sizes UI | 32 / 64 / 128 / 256 / 512 MB |

Measures **browser → CF Tunnel → NAS**, not raw LAN iPerf.

---

## 4. Frontend architecture

No React/build step. ES modules:

| File | Responsibility |
|------|----------------|
| `index.html` | Layout shells, icon sprite (`#i-*`), modal scrim, upload tray |
| `app.js` | State, routing (hash), list/grid, sidebar tree, DnD, modals, preview, speed test |
| `api.js` | HTTP client, speedtest multi-stream, XHR uploads |
| `format.js` | `formatSize`, `describeKind`, `previewKind`, `displayName` |
| `app.css` | Tokens (`--brand-green`, light `.light`, sidebar `--sb-*`) |

### Routing

- Hash path: `#/` or `#/Shows/Subfolder`
- `pathFromHash` / `navigate` / `hashchange` → `loadFolder`

### Loading UX

- `loadFolder` sets `loading=true` but **delays skeleton** (`SKELETON_DELAY_MS ≈ 200`).
- If previous `items` exist, keep them dimmed (`.content.is-refreshing`) until data returns.
- Skeleton only if slow **or** no items yet.
- `loadRequestId` ignores stale responses.

### Sidebar

- Resizable width (`--sidebar-width`, localStorage `ifd-sidebar-w`, 180–480px).
- Nested folder **tree**: lazy `listFiles`, expand on navigate, chevron toggle.
- `#recycle` display name: **🗑️ Recycle** (`displayName` in `format.js`).
- Light theme: full `--sb-*` light tokens (not permanent dark rail).

### Selection & open

- Folders: **click opens**; checkbox selects.
- Previewable files: **click opens lightbox**.
- Other files: click selects; download via bar/menu/double-click path.
- Multi-select: checkboxes, shift/meta on non-folder rows where applicable.

### Drag-and-drop moves

- MIME `application/x-infocus-paths` + `state.dndPaths`.
- Drop targets: folder rows/tiles, tree rows, breadcrumbs, Up button, “Drive root” label.
- Rejects drop into self/descendant; skips no-ops (already in dest).
- OS `Files` drag still triggers **upload** overlay (ignored for internal DnD).

### Media viewer

- Modal on `#scrim` with `scrim--viewer`.
- **Video mode** (`.viewer--video`): near-full viewport, black stage, `object-fit: contain`, floating prev/next, space play/pause, `f` fullscreen.
- Images/PDF/text use standard framed stage.

### Theme / prefs (localStorage)

| Key | Meaning |
|-----|---------|
| `ifd-theme` | `light` / dark default |
| `ifd-view` | `list` / `grid` |
| `ifd-density` | `comfortable` / `compact` |
| `ifd-sidebar-w` | sidebar px |

---

## 5. nginx gateway highlights

File: `nginx.conf` (untracked; copy from `nginx.conf.example` and set your NAS LAN IP; mounted into gateway container).

- Listen **8790**
- `client_max_body_size 10g`
- App location: stream bodies (`proxy_request_buffering off`, `proxy_buffering off`), `proxy_read/send_timeout 3600s`
- `/admin/` reverse-proxy to UGOS with redirect rewrites (legacy path access)

---

## 6. Feature history (session summary)

Built / fixed across the conversation chain:

1. Cloudflare Tunnel + drive browser scaffold  
2. PAUSD OAuth + NAS user mapping  
3. Claude/design-system UI (Geist / Barlow / brand green `#00c72c`)  
4. Deploy pipeline via tar + docker compose  
5. Hide `*.ug-tmp` style junk; show `#recycle` as 🗑️ Recycle  
6. Folder click-to-open; checkbox-only select for selection  
7. Resizable sidebar + nested folder tree  
8. Drag-and-drop moves  
9. Light-mode sidebar tokens  
10. Skeleton flicker fix (delayed skeleton)  
11. Media/document preview lightbox  
12. Drive speed test (multi-stream)  
13. Large upload reliability (stream write + nginx unbuffer + chunked speedtest)  
14. Cinema video viewer layout  

---

## 7. Security notes

- Auth required for all file APIs.
- Path traversal blocked in `resolve_rel`.
- Effective permissions = mapped NAS user (not superuser file bypass for content).
- Sessions are cookie-based; treat `SESSION_SECRET` as critical.
- Speed test discards data (not written to share).
- Do not log tokens or `.env` contents into git or agent docs.

---

## 8. Local vs production paths

| Context | Path |
|---------|------|
| Dev machine | your clone of this repo |
| NAS compose project | `/volume1/docker/infocus-drive` |
| Share data | `/volume2/InFocus Drive` |
| Container data | `/data/InFocus Drive` |

---

## 9. Testing checklist (manual)

After deploy:

1. Hard-refresh or confirm `index.html` references new `?v=`  
2. Login with `@pausd.org` / `@pausd.us`  
3. Navigate folders (single click), expand sidebar tree  
4. Preview an mp4 / image / pdf  
5. Upload a small file; optionally large file  
6. Drag a file onto another folder  
7. Speed test 32 MB then optionally 256 MB  
8. Toggle light/dark — sidebar should follow  
9. `/admin` or UGOS link still works  

---

## 10. Packages ↔ NAS storage (Package Cycles)

infocus-packages can store cycle media on the NAS via a **service API** (not end-user OAuth).

### Drive env / compose

| Env (drive `.env`) | Purpose | Prod note |
|--------------------|---------|-----------|
| `PACKAGES_SERVICE_TOKEN` | Shared secret (= packages `DRIVE_SERVICE_TOKEN`) | Set on NAS |
| `PACKAGES_SERVICE_USER` | NAS user for writes | e.g. `admin` |
| `PACKAGES_ROOT` | Extra allowed path prefix (Cycles + Storage are always allowed) | `Package Cycles` |

`docker-compose.yml` must pass these into the container (`env_file: .env` **and** explicit `environment:` entries). A host-only `.env` without compose wiring left the API unconfigured until fixed.

### Service API

| Endpoint | Role |
|----------|------|
| `POST /api/service/ensure-dir` | mkdir -p under Package Cycles or Package Storage |
| `POST /api/service/mint-token` | Short-lived path-scoped token |
| `POST /api/service/upload` | Multipart (service bearer **or** form token) |
| `GET /api/service/file` | Download/stream (Range); query token or bearer |
| `DELETE /api/service/file` | Delete |

**CORS** (required for browser upload from packages): allow the packages app origin(s) (e.g. `https://packages.example.com`), `*.vercel.app`, localhost:3000. Without CORS, curl works but the browser fails silently / “upload failed”.

### Layout (flat — video only)

```
Package Cycles/{Project name}/{Folder name}/{filename}.mp4
Package Cycles/{Project name}/{Folder name}/{filename}.poster.jpg
```

Example: `Package Cycles/Package Cycle 1/Final Cut/20260114_A741379.MP4`

**Do not** nest `/{media title}/v1/` — that was an earlier path builder; NAS was flattened and DB `nasPath` updated.

### Packages side

| | |
|--|--|
| Flag | `MEDIA_STORAGE_PROVIDER=NAS` |
| Client | Direct XHR to Drive (not Vercel body) |
| READY | Immediate after upload — **Bunny does not process NAS files** |
| Thumbnails | Browser frame capture → `*.poster.jpg` beside video |
| Legacy Bunny | Rows with `storageProvider=BUNNY` still play from Bunny |

Full ops + troubleshooting: `docs/NAS-STORAGE.md` in the infocus-packages repo.

## 11. Open improvements (not done)

- Custom video controls (still native browser controls)
- Chunked resumable real-file upload — **shipped** (init/chunk/complete + localStorage resume)
- Parallel multi-file upload + zip multi-download — **shipped**
- Office doc preview (docx/pptx need conversion)
- CF cache purge automation on deploy
- Automated tests / CI
- Automated Bunny → NAS media migration script
- Backfill posters for NAS videos uploaded before poster support
- Remote SMB via WARP: **shipped** (tunnel CIDR, allowlist enrollment, Include split tunnel, Gateway Allow NAS SMB). Ops: [REMOTE-SMB-WARP.md](./REMOTE-SMB-WARP.md). Optional later: Google Workspace IdP instead of OTP
