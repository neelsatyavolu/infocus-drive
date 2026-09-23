# CLAUDE.md / coding-agent notes

Project-specific rules for InFocus Drive. Merge with user global preferences.

## Product

Custom NAS file browser (web UI at `PUBLIC_BASE_URL`, e.g. `drive.example.com`) for `/volume2/InFocus Drive`. PAUSD Google OAuth → NAS username = local-part. Full detail: `AGENTS.md`, `docs/SYSTEM.md`.

## Code style

- **Surgical changes** — only touch what the task needs.
- Frontend: vanilla JS modules, no new framework unless asked.
- Match existing patterns in `app.js` / `api.js` / `format.js`.
- Backend: FastAPI; keep `fsops` path-safe and `as_user` for mutations.
- Prefer small pure helpers in `format.js` over bloating `app.js` when pure.

## UI conventions

- Brand green `#00c72c`; Geist + Barlow Condensed.
- Dark default; `.light` on `<html>` for light mode — include sidebar `--sb-*` tokens.
- Folder click = open; checkbox = select; media click = preview.
- After UI deploy: bump cache-bust `?v=` on `index.html` **and** `app.js` imports.

## Deploy

See `docs/DEPLOY.md`. Never ship NAS `.env`. Always `--build` after static changes.

## Safety

- No secrets, secret-manager item ids, internal IPs, or personal identifiers in commits or agent docs. Private operator notes belong in gitignored `ops-private/`.
- Don’t delete user data or run recursive deletes on the share without explicit ask.
