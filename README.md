# InFocus Drive

A self-hosted web file browser for a Ugreen NAS. It replaces the stock UGOS file manager with a fast, Google-sign-in file browser for a student media program. Students and staff sign in with their school Google account and land directly in the shared drive as their own NAS user, with the same file permissions they'd have over SMB.

It was built for InFocus, a student news program. It runs in production on the program's NAS, serving footage, packages and shows to students on and off campus.

**Stack:** FastAPI (Python 3.12) · vanilla ES modules (no framework, no bundler) · nginx · Docker Compose · Cloudflare Tunnel

## Features

- **Google sign-in → NAS user.** Allowed Workspace domains map `local-part@domain` to the NAS username (with optional explicit overrides). Every file operation runs as that Linux user (`setuid`), so NAS ACLs stay the source of truth.
- **File manager:** list/grid views, a nested resizable sidebar tree, drag-and-drop move, rename, mkdir, delete to `#recycle`, zip-streamed folder downloads, and search.
- **Big uploads:** resumable chunked uploads through Cloudflare Tunnel. Uploading a folder that already exists offers Replace or Merge, and Merge skips unchanged files by content fingerprint.
- **Previews:** images, video/audio (range requests), PDF, text, and Markdown (sanitized preview / raw). Video thumbnails come from ffmpeg.
- **Expiring share links:** signed public links for single files, with inline preview.
- **Personal folders:** UGOS encrypted home folders, unlocked in the browser.
- **LAN fast path:** on campus, the UI hands the session off to the NAS's LAN address to skip the tunnel hop.
- **UGOS single sign-on:** Google sign-in carried into the UGOS admin portal through a narrowly scoped PAM bridge (one-use, 30-second, browser-bound credentials; see [docs/UGOS-GOOGLE-LOGIN.md](docs/UGOS-GOOGLE-LOGIN.md)).
- **Roster sync (optional):** provisions and removes NAS accounts from an external roster through a localhost-only helper, with protected-account lists.
- Alternative sign-in: email codes (Resend) and NAS username + password with UGOS 2FA.

## Architecture

```
browser ──► Cloudflare Tunnel ──► nginx gateway :8790 ──► FastAPI app :8787 ──► /volume*/ (as the signed-in NAS user)
                                        │                         │
                                        └── /admin/ → UGOS        └── infocus-userd (127.0.0.1:8791, useradd on the host)
```

The full design is in [docs/SYSTEM.md](docs/SYSTEM.md).

## Self-hosting

You need a Ugreen NAS (UGOS Pro) with Docker, a Google OAuth client, and ideally a Cloudflare Tunnel.

1. **Google OAuth.** Create an OAuth 2.0 Web client in Google Cloud Console with redirect URI `https://<your-host>/auth/callback`.
2. **Config.** On the NAS, in the compose directory:
   ```bash
   cp .env.example .env                           # then fill it in
   cp nginx.conf.example nginx.conf               # set your NAS LAN IP
   cp config/user_map.example.json config/user_map.json   # optional overrides
   openssl rand -hex 32                           # use as SESSION_SECRET
   ```
   `docker-compose.yml` refuses to start if required values (public URL, allowed domains, protected accounts, …) are missing, so nothing silently falls back to a default.
3. **Run.** `sudo docker compose up -d --build`
4. **Optional:** UGOS SSO bridge (`scripts/install_ugos_sso.py`, run as root on the NAS), SMB remote access over Cloudflare WARP ([docs/REMOTE-SMB-WARP.md](docs/REMOTE-SMB-WARP.md)), Finder/Explorer setup ([docs/FINDER-NETWORK-DRIVE.md](docs/FINDER-NETWORK-DRIVE.md)).

Deployment details are in [docs/DEPLOY.md](docs/DEPLOY.md). The UI is branded for InFocus (`app/static/index.html`, `app/static/app.css`), so re-brand it for your own deployment.

## Development

```bash
python3 -m venv .venv && .venv/bin/pip install -r app/requirements.txt pytest
.venv/bin/python -m pytest -q          # backend tests
node --test tests/*.cjs                # frontend module tests
```

Contributor and coding-agent conventions are in [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md).

## Security

The app runs as root inside its container so it can `setuid` to each NAS user, and the `infocus-userd` helper is privileged. Treat the deployment as security-sensitive:

- Use a long random `SESSION_SECRET`; the app refuses weak ones.
- Keep ports 8787/8791 off the internet; expose only the gateway through the tunnel.
- The LAN fast path uses plain HTTP on the local network. Disable it (`LAN_ORIGIN=`) if you don't trust that network.
- Public share links last until they expire (up to 30 days) and can't be revoked early yet.

Please report vulnerabilities privately through GitHub Security Advisories on this repo rather than in public issues.

## License

[MIT](LICENSE)
