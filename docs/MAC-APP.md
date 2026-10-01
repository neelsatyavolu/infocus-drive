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
app. Run it again to update. The **Download .zip** link works too: the app is
Developer ID-signed and notarized, so macOS just asks once whether to open a
downloaded app. Needs macOS 13 or later.

## Use it

1. Open **InFocus Drive** (Applications, Spotlight or Launchpad) — its window opens. If the address isn't filled in, enter it (e.g. `https://drive.example.com`) and click **Continue**.
2. Click **Sign in with Google**, approve in the browser, and the volume mounts.
3. It remounts by itself on launch, after wake and when the network comes back.
   **Eject** in Finder (or **Disconnect**) stops it until you click **Connect** again.
4. **Start at login** keeps it there after a restart: a LaunchAgent in the bundle
   starts the app with `--background` (drive mounted, no window).
5. **Updates are automatic.** Every hour the app checks the latest `cli-v*`
   release (the `/releases/latest` redirect, not the rate-limited API). A new version
   shows a green **Update** button next to **Account** (menu) and in the window
   header; it downloads `InFocus-Drive-mac.zip`, checks its SHA-256, requires a
   Developer ID signature from the same team as the running app plus notarization
   (`spctl`), swaps the app bundle, quits (unmounting cleanly) and relaunches the
   same way it was running, which remounts the drive. It never restarts while Finder
   is copying: the helper reports open writes (`{"event":"writing","open":N}`) and
   uploads, and the install waits until both are zero. Turn it off in
   **Settings → Update automatically** (the button still appears). Development and
   ad-hoc builds don't update.
6. **Show in menu bar** (on by default) adds a menu-bar icon with the same status.
   With it off the app has no menu bar or Dock icon and just keeps the drive
   mounted; opening the app again shows its window (and a Dock icon while it's open).

The menu shows everything at a glance: what to do next (Open in Finder,
Connect, Sign in), live **Uploads** with progress, speed and errors, a **Status**
grid (account, Drive reachability and latency, Finder volume, helper, network,
start at login) and your **Shares** (click one to open it in Finder). **Help**
opens a window with a guide, troubleshooting, privacy notes and **Copy
diagnostics** (no tokens or passwords) for support.

**Encrypted personal folders** work like on the website: a locked one shows a
lock under **Shares**; clicking it opens **Unlock** (UGOS encryption password or
key file, and, when UGOS asks, a NAS sign-in as the owner plus authenticator
code). It then stays unlocked everywhere for 24 hours. While locked, Finder still shows
the folder, with a single read-only note inside saying how to unlock it; nothing
else can be read or written there. Secrets go to the bundled CLI (`infocus unlock`) on stdin,
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

### Speed

Measured on school Wi-Fi 6E (2026-10-01), through the macOS mount: the network tops
out around 150–170 MB/s both on the LAN and through the tunnel. What the helper does
about it:

- **Reads fetch exactly what macOS asks for.** macOS downloads a whole file with one
  GET and, alongside, asks for 4 MB ranges where an app is reading. A range of up to
  4 MiB is one bounded request; anything larger is fetched as 4 MiB ranges, 6 at a
  time from the first byte (the first range is 1 MiB, so the first bytes arrive
  quickly), handed to Finder in order (`davfs/readahead.go`, at most 48 MiB buffered
  per read). Reads never ask the Drive for bytes past the requested range, and never
  abandon an open-ended download (on the LAN's plain HTTP that kills the connection).
  Every chunk must carry the same version (ETag, Last-Modified, size) as the bytes
  already read, so a file saved by someone else mid-copy fails the copy instead of
  mixing versions. 256 MB reads: ~70 → ~125 MB/s, LAN and internet alike.
- **Writes over 8 MiB** upload in at least 4 chunks (whole MiB, up to 32 MiB each), 4 at
  a time (the CLI's chunked upload), so a 20 MB file uses every stream, not one.
- **Small files** cost one upload each. macOS creates every new file with an empty
  PUT, then LOCK/UNLOCK, then the real PUT: the empty PUT (or a LOCK) of a new name
  is a local placeholder, not an upload. A placeholder that never gets its content
  still becomes an empty file on the Drive, 2 s after its empty PUT or UNLOCK, when
  its lock expires (swept on the next lock activity), when it's renamed, or when the
  helper shuts down. Uploads/mkdirs/deletes update the cached folder listing in place;
  failed deletes/moves re-list instead of hiding files. ~10 → ~65 files/s on the LAN;
  over the internet each file still waits for one upload round trip.
- **Nothing waits on the share list.** `/api/me` asks UGOS about personal folders and
  can take seconds; once the helper has a share list it serves it and refreshes it in
  the background (the startup sign-in check fills it, so mounting asks once). Folder
  listings are fresh for 10 s, then served for up to 2 min while one background fetch
  per folder refreshes them; a listing fetched before a local change never overwrites it.
- **Warm connections.** 16 idle connections per host, kept 5 min; HTTP/2 pings keep the
  tunnel connection alive and drop a dead one within ~25 s. A request Finder cancels
  never counts as the LAN failing (that used to switch to the internet until the next
  30 s check).
- The **Drive** tile shows the round trip of the helper's 30 s check on the route in use
  (`{"event":"latency","ms":…,"via":"lan|internet"}`), i.e. what each Finder request waits.

`INFOCUS_DAV_TRACE=1` in the helper's environment logs every WebDAV request and every
Drive request with its timing to the helper log, to see what Finder asks for and where
the time goes.

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
- Changes made elsewhere show up within a few seconds of Finder next looking (listing cache).

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

### Signing and notarization

CI builds an ad-hoc-signed zip for each `cli-v*` release. The maintainer then runs,
on their Mac:

```sh
mac/sign-release.sh cli-v0.5.0
```

It loads the Developer ID certificate and App Store Connect API key from 1Password
through the shared loader (see `APPLE_SIGNING.md` next to the repos; override with
`INFOCUS_APPLE_CREDS_LOADER` / `OP_ACCOUNT`), signs the bundled `infocus` and the app
with hardened runtime and a timestamp, notarizes with `notarytool`, staples, checks
`spctl` reports *Notarized Developer ID*, and replaces `InFocus-Drive-mac.zip` and its
`SHA256SUMS` line on the release. No signing material is stored in the repo or in
GitHub. The app icon is generated from `Resources/brand-mark.png` by
`swift scripts/make-icon.swift`.
