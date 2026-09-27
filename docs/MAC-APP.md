# InFocus Drive for Mac (Finder volume)

A menu-bar app that puts your Drive shares in Finder as a normal volume
(`/Volumes/InFocus Drive`, listed under **Locations**) and keeps it mounted.
It uses the same Google sign-in as the web app, so **no NAS password** is
involved, and it needs no NAS port, NAS WebDAV or extra Cloudflare hostname.

## Install

On the Drive website open **Mac app & CLI** in the sidebar, or paste in Terminal:

```sh
curl -fsSL https://drive.example.com/mac/install.sh | sh
```

The installer (`app/static/mac/install.sh`, served at `/mac/install.sh` with the
Drive address filled in) downloads `InFocus-Drive-mac.zip` from the latest GitHub
release, checks it against `SHA256SUMS`, installs to `/Applications` (or
`~/Applications` without admin rights), pre-fills the Drive address and opens the
app. Because curl doesn't quarantine downloads, there is no Gatekeeper prompt. Run
it again to update. The **Download .zip** link works too, but macOS then asks once
(System Settings → Privacy & Security → **Open Anyway**). Needs macOS 13 or later.

## Use it

1. Open **InFocus Drive** from the menu bar. If the address isn't filled in, enter it (e.g. `https://drive.example.com`) and click **Continue**.
2. Click **Sign in with Google**, approve in the browser, and the volume mounts.
3. It remounts by itself on launch, after wake and when the network comes back.
   **Eject** in Finder (or **Disconnect**) stops it until you click **Connect** again.
4. **Start at login** keeps it there after a restart.

The menu shows everything at a glance: what to do next (Open in Finder,
Connect, Sign in), live **Uploads** with progress, speed and errors, a **Status**
grid (account, Drive reachability and latency, Finder volume, helper, network,
start at login) and your **Shares** (click one to open it in Finder). **Help**
opens a window with a guide, troubleshooting, privacy notes and **Copy
diagnostics** (no tokens or passwords) for support.

**Encrypted personal folders** work like on the website: a locked one shows a
lock under **Shares**; clicking it opens **Unlock** (UGOS encryption password or
key file, and, when UGOS asks, a NAS sign-in as the owner plus authenticator
code). It then stays unlocked everywhere for 24 hours. Until then Finder shows the
folder but can't open it. Secrets go to the bundled CLI (`infocus unlock`) on stdin,
never in argv, and aren't stored.

The volume's top level has one folder per share you can open. Everything below
is your Drive, with the same permissions as the web app (read-only shares stay
read-only; deletes go to the share's Recycle bin).

## How it works

```
Finder ──WebDAV (NetFS)──► 127.0.0.1:PORT  infocus webdav  ──HTTPS + bearer──► Drive API
```

- The app bundles the `infocus` CLI. **Sign in** runs `infocus login` (browser
  PKCE flow, token in the login Keychain — shared with the terminal CLI).
- **Connect** starts `infocus webdav` on loopback and mounts its URL with Apple's
  WebDAV client via `NetFSMountURLAsync` (soft mount, no UI). No FUSE, no File Provider.
- The helper maps WebDAV onto the existing API: listings (`/api/files`, cached 5 s),
  ranged downloads (`/api/download` + `Range`), uploads (`/api/upload`, chunked for
  large files so no request exceeds the tunnel's body limit), mkdir, rename, move, delete.
- The loopback server needs that random password (HTTP Basic), passed on the
  helper's stdin and to NetFS — never in argv. It also rejects non-loopback `Host`
  headers (DNS rebinding). When the app quits, the helper's stdin closes and it exits.
- Every helper start gets a fresh port and password. If the helper crashes, the app
  unmounts at once (so nothing keeps talking to a port another account could take
  over), starts a new helper and remounts. If the Drive rejects the token (401), the
  helper exits with code 3 and the app unmounts and asks you to sign in again.
- Safety rules in the helper: a `LOCK` only ever creates a missing file (never
  empties an existing one); a PUT or COPY whose data didn't arrive completely uploads
  nothing; an app's safe save (temp file renamed over the document) replaces the
  document only after the upload succeeded; names containing `\` are refused.
- The helper reports uploads as JSON lines on stdout
  (`{"event":"upload","id":…,"path":…,"size":…,"sent":…,"state":"active|done|failed"}`),
  which the menu shows under **Uploads**.
- Files the Drive hides (`._*` AppleDouble, `.DS_Store`, `*.tmp`, …) stay on the Mac
  for the session instead of being uploaded, so web users don't see Finder junk and
  apps that save through a temp file still work.

Helper errors go to `~/Library/Logs/InFocus Drive/helper.log` (**Account → Show helper log**).

## Limits

- A file you save or copy is written to a local temp file first, then uploaded when
  Finder closes it. Copying a very large file needs that much free disk space, and
  the copy only finishes in Finder once the upload is done.
- Moving items **between shares** isn't supported by the Drive; copy then delete.
- File names containing a backslash (`\`) can't be saved to the Drive.
- If the app itself crashes, the volume stays mounted but dead until the app runs
  again (it cleans it up on launch).
- Finder labels/tags on Drive files last only while the app runs (they live in `._` files).
- Changes made elsewhere show up within a few seconds (listing cache).

## Build

Needs Xcode (Swift 5.9+) and Go.

```sh
VERSION=0.1.0 mac/build.sh   # → mac/build/InFocus Drive.app (universal, ad-hoc signed)
```

`build.sh` also writes `mac/build/InFocus-Drive-mac.zip`. Releases build it in CI
and attach it to each `cli-v*` release (see [DEPLOY.md](DEPLOY.md#cli-releases)).
`CONFIGURATION=debug mac/build.sh` builds a debug app whose
`Contents/MacOS/InFocusDrive --render-previews DIR` draws every screen (light and
dark) to PNGs for design review.

The app is ad-hoc signed (no Developer ID), which is why the curl installer is the
recommended path. Distributing a browser download without prompts needs a
Developer ID signature and notarization.
