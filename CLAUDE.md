# CLAUDE.md / coding-agent notes

Project-specific rules for InFocus Drive. Merge with user global preferences.

## Product

Custom NAS file browser (web UI at `PUBLIC_BASE_URL`, e.g. `drive.example.com`) for `/volume2/InFocus Drive`. PAUSD Google OAuth → NAS username = local-part. Full detail: `AGENTS.md`, `docs/SYSTEM.md`.

## ⚠️ Public repository — be careful

This repo is **open source (MIT) and public**: https://github.com/neelsatyavolu/infocus-drive. Every commit, commit message, branch, issue and PR is world-readable and effectively permanent (force-pushing does not un-publish it). It runs in production for a school, and its users are minors.

- **Never commit:** secrets/tokens, `.env`, 1Password/secret-manager item or account ids, the NAS LAN IP or internal hostnames, SSH hosts, real student/staff names, usernames or emails, screenshots or exports of real data, `config/user_map.json`, `nginx.conf`, `config/*.sqlite3`, logs, Playwright/browser artifacts.
- Tests, docs and examples use fictional values (`student1`, `admin@example.org`, `192.168.1.50`, `drive.example.com`).
- Commit messages must not name real people or accounts.
- Before every commit: review `git diff --cached` line by line, `git status` for stray files, and run `gitleaks git .`. If something sensitive was committed, stop and tell the user **before** pushing.
- Security-sensitive code (runs as root, `setuid`, a PAM bridge): don't weaken the existing hardening (session-secret check, inline-file allowlist + CSP sandbox, sign-in lockouts, userd group allowlist). Vulnerabilities are reported privately via GitHub Security Advisories, never in public issues.
- Private operator notes and the old pre-open-source history live only in gitignored `ops-private/`. Never add it as a remote, copy from it into tracked files, or push it.

## Code style

- **Surgical changes** — only touch what the task needs.
- Frontend: vanilla JS modules, no new framework unless asked.
- Match existing patterns in `app.js` / `api.js` / `format.js`.
- Backend: FastAPI; keep `fsops` path-safe and `as_user` for mutations.
- Prefer small pure helpers in `format.js` over bloating `app.js` when pure.

## UI conventions

- Colors come from the logo (green `#2bb36e`, red `#ee3a2a`); see `DESIGN.md`. Geist + Barlow Condensed.
- Wordmark on light-theme pages is an `.wm-dark` / `.wm-light` image pair (`DESIGN.md`).
- Dark default; `.light` on `<html>` for light mode — include sidebar `--sb-*` tokens.
- Folder click = open; checkbox = select; media click = preview.
- After UI deploy: bump cache-bust `?v=` on `index.html` **and** `app.js` imports.

## Deploy

See `docs/DEPLOY.md`. Never ship NAS `.env`. Always `--build` after static changes.

## Safety

- No secrets, secret-manager item ids, internal IPs, or personal identifiers in commits or agent docs. Private operator notes belong in gitignored `ops-private/`.
- Don’t delete user data or run recursive deletes on the share without explicit ask.
