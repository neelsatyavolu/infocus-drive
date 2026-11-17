# Deploy InFocus Drive

## Prerequisites

- Your clone of this repo on the deploy machine
- SSH access to the NAS as an admin account with `sudo` (e.g. `admin`). If you reach the NAS through Cloudflare Access, install and log in to `cloudflared`.
- The NAS admin password in your secret manager (read it into `SSHPASS` when needed; never commit it)

Placeholders used below — export them in your shell (the rebuild script reads them too):

```bash
export NAS_SSH_HOST=ssh.example.com          # or your NAS LAN IP, e.g. 192.168.1.50
export NAS_SSH_USER=admin
export NAS_DEPLOY_PATH=/volume1/docker/infocus-drive
```

**Never overwrite NAS `.env`** (OAuth secrets live only there).

## First-time on NAS

```bash
cd "$NAS_DEPLOY_PATH"
cp .env.example .env                                   # fill in secrets — never commit
cp nginx.conf.example nginx.conf                       # set your NAS LAN IP (UGOS upstream)
cp config/user_map.example.json config/user_map.json   # optional email → NAS user overrides
sudo docker compose up -d --build
sudo docker logs -f infocus-drive
```

`nginx.conf` and `config/user_map.json` are untracked; the `*.example` files are the templates.

`docker compose` **fails fast** unless `.env` sets all of:

| Variable | Example |
|----------|---------|
| `PUBLIC_BASE_URL` | `https://drive.example.com` |
| `ALLOWED_EMAIL_DOMAINS` | `example.org` |
| `GOOGLE_HOSTED_DOMAIN` | `example.org` |
| `USER_SYNC_PROTECTED_USERNAMES` | `admin,teacher1` |
| `USER_SYNC_PROTECTED_EMAILS` | `admin@example.org` |
| `UGOS_ADMIN_PATH` | `https://ugos.example.com/` (sidebar admin link / SSO target) |
| `PACKAGES_ROSTER_URL` | `https://packages.example.com/api/service/drive-roster` |
| `UGOS_ADMIN_USER` | `admin` |

Plus the usual `GOOGLE_*` and `SESSION_SECRET` (see `.env.example`).

## Redeploy from your machine (standard)

### 0. Pre-flight

If you SSH through Cloudflare Access, TLS to the Access hostname must verify:

```bash
echo | openssl s_client -connect "$NAS_SSH_HOST:443" -servername "$NAS_SSH_HOST" 2>&1 \
  | rg -i 'Verify return code|issuer='
# Expect: Verify return code: 0 (ok). Issuer should be a public CA, not a firewall vendor.
```

If the issuer is an SSL-inspection appliance (e.g. Fortinet), `cloudflared` will refuse to connect — switch networks or install the org CA.
The NAS LAN IP is usually unreachable off-site; use the Access hostname there.

```bash
# Read the NAS password from your secret manager into SSHPASS. Never echo it.
export SSHPASS="…"
test "${#SSHPASS}" -ge 8 || { echo "SSHPASS not set"; exit 1; }

SSH_OPTS=(-o PubkeyAuthentication=no -o PreferredAuthentications=password
          -o "ProxyCommand=cloudflared access ssh --hostname %h"   # omit on LAN
          -o ConnectTimeout=60 -o ServerAliveInterval=15
          -o ServerAliveCountMax=20 -o NumberOfPasswordPrompts=1)

# Smoke one hop before copying
sshpass -e ssh "${SSH_OPTS[@]}" "$NAS_SSH_USER@$NAS_SSH_HOST" \
  "hostname; test -d '$NAS_DEPLOY_PATH' && echo drive_ok"
```

### 1. Bump static cache busters

Use **one** new tag everywhere (e.g. `20260729-rootcrumb`):

| File | What to bump |
|------|----------------|
| `app/static/index.html` | `app.css?v=` and `app.js?v=` |
| `app/static/app.js` | every `import … from "./…js?v="` |
| `app/static/viewer.js` | its imports (`dom`, `format`, `player`) |
| `app/static/player.js` | its `dom` import |
| `app/static/editing.html` | `editing.css?v=` and `editing.js?v=` |
| `app/static/editing*.js` | every `import … from "./…js?v="` |

Without this, Cloudflare may keep serving old JS/CSS for hours. Grep to confirm one tag:

```bash
rg -n '\?v=' app/static --glob '*.{html,js}'
```

### 2. Copy tree to the NAS (preserve NAS `.env`)

From your clone of this repo:

```bash
COPYFILE_DISABLE=1 tar czf - \
  --exclude '.env' --exclude '.git' --exclude 'ops-private' \
  --exclude 'nginx.conf' --exclude 'config/user_map.json' \
  --exclude '__pycache__' --exclude '.DS_Store' \
  --exclude '.agmux' --exclude '.grok' --exclude '.claude' \
  . \
  | sshpass -e ssh "${SSH_OPTS[@]}" "$NAS_SSH_USER@$NAS_SSH_HOST" \
      "tar xzf - -C '$NAS_DEPLOY_PATH'"
```

Harmless on extract: `tar: Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.*'` (macOS metadata). Still always use `COPYFILE_DISABLE=1` so `._*` AppleDouble files are not created.

### 3. Rebuild containers

Static UI is **baked into the image** (`COPY app/ /app/`). Copying alone is not enough — always rebuild. On the NAS:

```bash
cd "$NAS_DEPLOY_PATH"
sudo docker compose up -d --build
# If nginx.conf changed, also recreate the gateway:
sudo docker compose up -d --build --force-recreate
```

Or run the helper from your machine, which retries with backoff (Access + password SSH can be intermittent):

```bash
# Requires NAS_SSH_HOST, NAS_SSH_USER, NAS_DEPLOY_PATH and SSHPASS in the environment
bash scripts/deploy-rebuild.sh YOURTAG
```

Notes:

- `SSHPASS` exists only on your machine. Never expand it inside a single-quoted remote command — it will be empty on the NAS.
- UGOS does not configure passwordless sudo, so `sudo -n` fails; the helper feeds `sudo -S` from the local side.
- Don't multiplex SSH (`ControlMaster`) through the Access proxy — the master tends to drop. One connection per attempt.
- Compose may warn `Docker Compose requires buildx plugin` — the classic builder still works.

If the copy succeeded but the rebuild failed, re-run only the rebuild.

### 4. Verify

```bash
# HTML points at new version
curl -sS https://drive.example.com/ | rg -o 'app\.(js|css)\?v=[^"]+'

# New JS is actually the new build (spot-check a string you just shipped)
curl -sS "https://drive.example.com/assets/app.js?v=YOURTAG" | rg -n 'YOUR_UNIQUE_STRING' | head
curl -sS https://drive.example.com/api/health
# → {"status":"ok"}
```

Hard-refresh the browser after deploy (CF + browser cache).

## Gotchas

| Problem | Cause / fix |
|---------|-------------|
| `Permission denied` with agent keys | Use `PubkeyAuthentication=no` + password via `sshpass -e` |
| Immediate `Permission denied` | Check `SSHPASS` was read correctly (`test "${#SSHPASS}" -ge 8`). Do not print the password |
| Intermittent `Permission denied (publickey,password)` | Access/password race; **retry with backoff** (`scripts/deploy-rebuild.sh`). Wait ~10–30s after a burst of failures |
| `tls: … certificate is not trusted` | **SSL inspection** MITM on your network. Leave network / install CA. cloudflared will not connect until TLS verifies |
| NAS LAN IP timeout / refused | Normal off-site; use the Access hostname |
| `ControlMaster` / mux “Connection reset” | Do not multiplex SSH over Access; one-shot per attempt |
| `openrsync` / invalid path | Use `tar`, never macOS rsync |
| `._*` AppleDouble on NAS | Always `COPYFILE_DISABLE=1` |
| `LIBARCHIVE.xattr.com.apple.*` on extract | Harmless macOS tar metadata noise |
| `sudo: a password is required` / `sudo -n` fails | No passwordless sudo on NAS. Use `sudo -S` fed from your machine (the helper script does this) |
| `Sorry, try again` for sudo with empty password | `$SSHPASS` is not on the remote — don't expand it inside remote single quotes |
| Access “authorization timeout” | Retry; `cloudflared access login https://$NAS_SSH_HOST` if needed |
| `docker compose` errors about unset variables | A required `.env` key is missing (see table above) |
| UI unchanged after rebuild | Bump `?v=` on **html + all module imports**; hard-refresh; purge CF if stuck |
| Overwrote `.env` | Restore from your secret manager; **never** include `.env` in the copy |
| Copy OK, old UI in container | Forgot `docker compose up -d --build` — static is image-baked |
| `MISSING_ENV` after copy | NAS `.env` was deleted — restore it before rebuilding |
| Compose `requires buildx plugin` warning | Harmless; classic builder still tags `infocus-drive:local` |

## Editing dashboard (editing.infocuspaly.com)

The team-project dashboard runs inside the Drive app (same container, same process); there is nothing new to build or run. It is always at `/editing` on the Drive's own address, so you can try it there first. To give it its own hostname:

1. **Env.** In the NAS `.env`, add `EDITING_HOST=editing.infocuspaly.com` (host only, no scheme). Leave `PUBLIC_BASE_URL` as it is. Rebuild (`docker compose up -d --build`).
2. **Tunnel ingress.** In the Cloudflare dashboard (Zero Trust → Networks → Tunnels → the Drive's tunnel → Public hostnames), add `editing.infocuspaly.com` pointing at the same service as the Drive's hostname (the nginx gateway, `http://localhost:8790`). Keep the same origin settings as the Drive's entry. nginx needs no change: it already forwards `Host`, and `server_name _` answers any hostname.
3. **DNS.** Adding the public hostname creates a proxied `CNAME editing → <tunnel-id>.cfargotunnel.com` in the `infocuspaly.com` zone. If the zone isn't in the tunnel's Cloudflare account, add that CNAME by hand (proxied).
4. **Google OAuth.** In Google Cloud Console → APIs & Services → Credentials → the Drive's OAuth client, add the authorized redirect URI `https://editing.infocuspaly.com/auth/callback`. Keep the Drive's existing one. Sign-in started on the editing host returns there, so its session cookie is set on that host.
5. **Cookies.** The session cookie stays host-only (no `Domain`), so the Drive and the dashboard each have their own sign-in; people sign in once on each. Don't set a cookie domain to share them: that would send the Drive session to every `*.infocuspaly.com` site. Only Google sign-in is offered on the dashboard; the Drive's email-code and NAS-password sign-ins stay on the Drive.
6. **Cloudflare cache.** Nothing to set: `/` on the editing host is the static page (60 s edge cache, no user data), and `/api/*`, `/auth/*` are `no-store` as on the Drive.
7. **Verify.** `curl -sI https://editing.infocuspaly.com/` → 200 with `content-security-policy: default-src 'none'; script-src 'self'…`; open it in a browser, Continue with Google, and check your team projects appear. As a Drive admin, check that "All projects" shows every project and that a project you're not in opens read-only. As someone who isn't in a project, its `?project=<id>` link must say "Project not found".

Rollback: remove `EDITING_HOST` (the page stays at `/editing`) or delete the public hostname.

## Tunnel / ports reminder

| Port | Service |
|------|---------|
| 8787 | uvicorn (container, host network) |
| 8790 | nginx gateway |
| 9999 | UGOS (admin) |
| 22 | SSH (via Access hostname) |

Confirm live Cloudflare Tunnel ingress if routes misbehave — config is in the Cloudflare dashboard / tunnel credentials on the NAS, not in this repo.

**Remote Finder SMB (WARP):** add your NAS LAN IP as a private network (`/32`) on your tunnel and set a WARP enrollment policy. See [REMOTE-SMB-WARP.md](./REMOTE-SMB-WARP.md). Drive `.env` should include `WARP_TEAM_NAME` / `WARP_ENROLL_URL` so the UI matches.

## Packages service env (after adding NAS storage)

Ensure NAS `.env` includes:

```env
PACKAGES_SERVICE_TOKEN=<shared-secret>
PACKAGES_SERVICE_USER=admin
PACKAGES_ROOT=Package Cycles
SHOWS_ROOT=Shows
WORDPRESS_URL=https://infocusnews.tv
```

`SHOWS_ROOT` is the switcher recordings folder that the Portal's automatic show editor reads (never writes). Give `PACKAGES_SERVICE_USER` read access to it in the NAS share permissions, or listing it returns 403.

And `docker-compose.yml` passes them into `infocus-drive` (see `env_file` + `environment` block). Then:

```bash
sudo docker compose -f "$NAS_DEPLOY_PATH/docker-compose.yml" up -d --force-recreate
```

Smoke:

```bash
curl -sS -X POST https://drive.example.com/api/service/ensure-dir \
  -H "Authorization: Bearer $PACKAGES_SERVICE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":"Package Cycles"}'
```

The packages app must use the **same** token as `DRIVE_SERVICE_TOKEN` and `MEDIA_STORAGE_PROVIDER=NAS`.

## Meetings Scribe (first time)

1. In the NAS `.env`, set `SCRIBE_INTERNAL_TOKEN` (a new random value), `PORTAL_BASE_URL` and `MEETING_ROOM_URL`. Compose refuses to start without `SCRIBE_INTERNAL_TOKEN`, so set it before the next deploy.
2. Create `/volume2/InFocus Drive/.ifd-meetings` (or `IFD_MEETINGS_ROOT`; the `.ifd-` prefix hides it from Drive listings) and make it writable by uid 1000.
3. Add the `location /api/internal/` block from `nginx.conf.example` to `nginx.conf`.
4. Run:

```bash
sudo docker compose -f "$NAS_DEPLOY_PATH/docker-compose.yml" up -d --build --remove-orphans infocus-scribe infocus-drive
sudo docker compose -f "$NAS_DEPLOY_PATH/docker-compose.yml" up -d --force-recreate gateway
```

No model pull step: the first summary downloads `SCRIBE_OLLAMA_MODEL` (about 1 GB) and logs it.

The Scribe image is large (about 2 GB, Playwright + Chromium + the Ollama binary), so the first build takes a while. Rebuild it when Playwright or Ollama updates. See [MEETINGS-SCRIBE.md](./MEETINGS-SCRIBE.md) for the full steps, isolation details, resources and troubleshooting.

## CLI releases

The `infocus` CLI ([CLI.md](CLI.md)) ships as a GitHub Release, not in the Docker image. The Drive only serves the installers at `/cli/install.sh` (macOS) and `/cli/install.ps1` (Windows) (it fills in `PUBLIC_BASE_URL`, which must be an `https://` origin).

1. Make sure `cd cli && go test -race ./...` passes.
2. Tag and push: `git tag cli-v0.1.0 && git push origin cli-v0.1.0`.
3. `.github/workflows/cli-release.yml` tests on macOS and Windows (including an install-then-update run of `install.ps1`), builds the universal macOS binary, Windows x64/ARM64 binaries and the Mac app, and publishes `infocus-darwin-universal.tar.gz`, `infocus-windows-amd64.zip`, `infocus-windows-arm64.zip`, `InFocus-Drive-mac.zip` + `SHA256SUMS` as a **pre-release**. Then run `mac/sign-release.sh cli-vX.Y.Z` to notarize the Mac app ([MAC-APP.md](MAC-APP.md)); it replaces the zip and makes the release Latest. Until then installed apps, CLIs and the install scripts stay on the previous release (installed Mac apps refuse an update that isn't notarized).
4. Check it: `curl -fsSL https://drive.example.com/cli/install.sh | sh`, then `infocus login`; and `curl -fsSL https://drive.example.com/mac/install.sh | sh` for the Mac app ([MAC-APP.md](MAC-APP.md)).

Both installers (`/cli/install.sh`, `/mac/install.sh`) download from `releases/latest`, so keep CLI releases as the repo's latest release (or users pin with `INFOCUS_VERSION`). Terminal sign-ins live in `CLI_TOKENS_DB_PATH` (default `/config/cli_tokens.sqlite3`) on the persistent config mount; no migration is needed.
