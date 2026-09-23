# UGOS Google sign-in

Drive can sign a Google-authenticated user into their mapped UGOS account without
asking for a NAS password or changing that password. The public UGOS landing page
offers **Continue with Google** and the original NAS login. Drive's **NAS control
panel** link starts Google handoff directly.

UGOS two-factor authentication remains required when enabled. Native account
lockouts, disabled accounts, and required account updates remain authoritative.
Existing Drive sessions created before this feature, or through NAS/email login,
must sign in with Google once to establish the browser-bound Google identity.

## How it works

1. UGOS sets a secure, host-only browser nonce and redirects to Drive.
2. Drive checks a browser-bound Google session and re-resolves email to NAS UID.
3. The authenticated local provisioner issues a random 30-second credential for
   that username and UID. Only its hash is stored under `/run/infocus-ugos-sso`.
4. The dedicated `ugreen-login` PAM stack accepts this credential once, then runs
   UGOS account/lockout checks. The native login API issues the real session and
   handles any required OTP. Shared PAM, SSH, and SMB are not modified.
5. A separate one-use code and the original browser nonce protect transfer of
   the native session to the UGOS origin. Session credentials never appear in
   redirect URLs. The browser initializes UGOS's native storage and reloads it.

The application keeps pending handoffs in memory; a restart expires them. Expired
or failed handoffs require starting again. The helper refuses issuance when a
firmware update removes its active PAM reference.

## Install

Run tests, copy the changed application files without overwriting `.env`, and
rebuild `infocus-drive` and `infocus-userd`. Compose enables `UGOS_SSO_ENABLED` by
default; set it false to disable the app endpoints and direct Drive link.

Install the host integration as root after the rebuilt app is healthy:

```sh
python3 /volume1/docker/infocus-drive/scripts/install_ugos_sso.py
```

The installer backs up every replaced file under root-only
`/var/lib/infocus-ugos-sso`, installs the root-owned helper in
`/usr/local/libexec/infocus-ugos-sso-pam`, and adds the `/infocus-sso/` nginx route.
Only the public UGOS hostname's (e.g. `ugos.example.com`) root redirect changes; native LAN landing
pages retain their original behavior. Nginx syntax is checked before reloading.
Errors during installation restore the previous files.

## Verify after installation or a UGOS firmware update

- Open `https://ugos.example.com/`: both login options should be available.
- Use Google with the mapped school account, complete UGOS OTP if enabled, and
  verify the desktop shows the correct NAS identity and permissions.
- Verify ordinary NAS password login remains available at `/desktop/`.
- Check that the helper is still referenced in `/etc/pam.d/ugreen-login`, and
  review the current native `common-auth-faillock` policy before reinstalling.
- Recheck the browser bootstrap against the current UGOS frontend. The initial
  implementation targets frontend `1.19.0.78471`; it does not patch vendor JS.

## Rollback

```sh
python3 /volume1/docker/infocus-drive/scripts/install_ugos_sso.py --rollback
```

The rollback restores the backed-up native files and removes only installed bridge
files. It refuses to overwrite files changed since installation; inspect firmware
or administrator changes first. Then set `UGOS_SSO_ENABLED=false` and recreate
the Drive container to restore the original sidebar destination.

Do not run `probe_ugos_sso.py` after installation: it deliberately requires the
unmodified native PAM stack.

## Expected behavior

The native login accepts the one-use credential and preserves the account's OTP
challenge, exactly as normal password login does. The complete browser flow opens
the native desktop as the mapped NAS user, preserving its existing UGOS role,
without any NAS password entry.

Form pages use `Referrer-Policy: strict-origin`: `no-referrer` makes browsers send
`Origin: null` on navigation POSTs and would break the strict CSRF checks. Paths,
state values, and session credentials are never sent as referrers.
