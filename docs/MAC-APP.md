# InFocus for Mac (Drive in Finder, Mac backup)

A menu-bar app (it used to be called InFocus Drive) that puts your Drive shares in Finder as a normal volume
(`/Volumes/InFocus Drive`, listed under **Locations**) and keeps it mounted.
It uses the same Google sign-in as the web app, so **no NAS password** is
involved, and it needs no NAS port, NAS WebDAV or extra Cloudflare hostname.

## Install

The easy way: in the Portal, **Settings → InFocus for Mac → Download for Mac**
(the latest release's `InFocus-Drive-mac.zip`). Open the download; macOS asks
once whether to open an app from the internet. On that first open from outside
an Applications folder the app offers **Move to Applications**
(`MoveToApplications.swift`): it copies itself to `/Applications/InFocus.app`
(or `~/Applications` when `/Applications` isn't writable, e.g. a non-admin
account), replaces any older InFocus / InFocus Drive copy there, moves the
download to the Trash and relaunches. **Not Now** keeps running where it is
(updates, the rename and start at login need Applications); **Don't ask again**
stops the prompt. Then **Sign in with Google** and approve Drive.

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
   uploads, and the install waits until both are zero (and for a running Mac
   backup). Turn it off in
   **Settings → Update automatically** (the button still appears). Development and
   ad-hoc builds don't update.
6. **Show in menu bar** (on by default) adds a menu-bar icon with the same status.
   With it off the app has no menu bar or Dock icon and just keeps the drive
   mounted; opening the app again shows its window (and a Dock icon while it's open).
7. **Keep Drive connected after Quit** (on by default, `QuitPolicy.swift`): Quit
   (Cmd+Q, InFocus → Quit, or the Dock) closes the app's windows and the Dock
   icon, but the app keeps running in the menu bar with the drive mounted; opening
   InFocus again shows the Drive window. **Quit InFocus Completely** (menu bar,
   Drive window → More, or hold Option in the InFocus menu, Option+Cmd+Q) unmounts
   and exits. Updates, log out, restart, shut down and quit requests from other
   programs (the install script) always quit completely. Turn the setting off and
   Quit unmounts and exits as before.

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

## Mac backup

For the accounts named in the build's `BACKUP_USERS` (see [Build](#build)), the
Drive window has a **Mac backup** section and the menu shows its status. Choose
**From** (a folder on this Mac; your home folder backs up everything) and **To** (a
folder in one of your writable shares, picked in the mounted volume), and it runs:

- **Every hour** while the app runs (checked each minute, so it catches up after
  sleep), plus **Back up now**. It runs `infocus backup` (see [CLI](CLI.md)), which
  remembers what it sent in `~/Library/Application Support/InFocus/backup-state.json`:
  an hour where little changed only walks the local folder, with no Drive listing
  and no re-reading of unchanged files. Uploads use the CLI's parallel, chunked,
  resumable path and go direct to the NAS on the school network.
- **Once a day** it checks the whole Drive folder too, re-uploading anything that
  went missing there.
- **Deletions:** a file deleted on the Mac is moved to the share's Recycle bin once
  it has stayed deleted for a week (bring it back within the week and nothing
  happens). Only files the backup uploaded are removed, never ones someone changed
  on the Drive since, and only on a share with a Recycle bin (on one without, they
  stay and the status says so); folders it can't read (macOS privacy) or that are left out are
  never treated as deleted; an empty source folder never deletes anything.
- Backing up the home folder leaves out `Library`, `.Trash` and a few caches.
  macOS may ask once to let InFocus read Desktop, Documents and Downloads.
- Updates wait for a running backup; Quit Completely stops it (the next run picks up
  where it stopped).

The username list is a feature switch, not access control: a backup only ever uses
the person's own Drive permissions.

**Rename.** Releases still contain `InFocus Drive.app` (the updater in older copies
looks for that name). On its first launch from `/Applications` or `~/Applications`,
the app renames itself to `InFocus.app`, re-registers **Start at login** and
relaunches before mounting anything; if the rename fails it keeps working under
the old name. The installer installs `InFocus.app` directly and removes an old
`InFocus Drive.app` next to it.

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
  per read). Reads never ask the Drive for bytes past the requested range (the type
  comes from the extension, so nothing is read to sniff it), and never abandon an
  open-ended download (on the LAN's plain HTTP that kills the connection).
  Every chunk must carry the same version (ETag, Last-Modified, size) as the bytes
  already read, so a file saved by someone else mid-copy fails the copy instead of
  mixing versions. 256 MB reads: ~70 → ~125 MB/s, LAN and internet alike.
- **Writes over 8 MiB** upload in at least 4 chunks (whole MiB, up to 32 MiB each), 4 at
  a time (the CLI's chunked upload), so a 20 MB file uses every stream, not one.
- **Small files** cost one upload each. macOS creates every new file with an empty
  PUT, then LOCK/UNLOCK, then the real PUT: the empty PUT (or a LOCK) of a new name
  is a local placeholder, not an upload. A placeholder that never gets its content
  still becomes an empty file on the Drive, 2 s after its empty PUT or UNLOCK (or its
  folder's rename), when its lock expires (swept on the next lock activity), when it's
  renamed, or when the helper shuts down; if that fails, the app shows a failed upload. Uploads/mkdirs/deletes update the cached folder listing in place;
  failed deletes/moves re-list instead of hiding files. ~10 → ~65 files/s on the LAN;
  over the internet each file still waits for one upload round trip.
- **Nothing waits on the share list.** `/api/me` asks UGOS about personal folders and
  can take seconds; once the helper has a share list it serves it and refreshes it in
  the background (the startup sign-in check fills it, so mounting asks once). Folder
  listings are fresh for 10 s. Finder's folder views are then served the older listing
  (up to 2 min) while one background fetch per folder refreshes it; looking up a single
  name (open, stat, create) always waits for a fresh one, since its size decides what a
  read serves. Local changes made while a listing loads are replayed onto it, so it
  never undoes an upload. A download whose size differs from the listing's fails the
  read and re-lists instead of serving a cut-off file.
- **Warm connections.** 16 idle connections per host, kept 5 min; HTTP/2 pings keep the
  tunnel connection alive and drop a dead one within ~25 s. A request Finder cancels
  never counts as the LAN failing (that used to switch to the internet until the next
  30 s check); one that times out still does.
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
VERSION=0.1.0 DRIVE_URL=https://drive.example.com BACKUP_USERS="student1" \
  mac/build.sh                # → mac/build/InFocus Drive.app (universal, ad-hoc signed)
(cd mac && swift test)        # unit tests: config, backup, rename, quit, updates
```

`DRIVE_URL` is optional (https only; http just for `localhost`). `BACKUP_USERS`
(space-separated Drive usernames) turns on Mac backup for those accounts; only their
SHA-256 hashes go into `Info.plist`. In CI both come from the repository variables
`DRIVE_URL` and `BACKUP_USERS`; never commit real usernames.

`build.sh` also writes `mac/build/InFocus-Drive-mac.zip`. Releases build it in CI
and attach it to each `cli-v*` release (see [DEPLOY.md](DEPLOY.md#cli-releases)).
`CONFIGURATION=debug mac/build.sh` builds a debug app whose
`Contents/MacOS/InFocusDrive --render-previews DIR` draws every screen (light and
dark) to PNGs for design review.

### Signing and notarization

CI builds an ad-hoc-signed zip for each `cli-v*` release. The maintainer then runs,
on their Mac:

```sh
mac/sign-release.sh cli-v0.5.0   # DRIVE_URL, LEGACY_HOSTS, BACKUP_USERS from the repo variables
```

It loads the Developer ID certificate and App Store Connect API key from 1Password
through the shared loader (see `APPLE_SIGNING.md` next to the repos; override with
`INFOCUS_APPLE_CREDS_LOADER` / `OP_ACCOUNT`), signs the bundled `infocus` and the app
with hardened runtime and a timestamp, notarizes with `notarytool`, staples, checks
`spctl` reports *Notarized Developer ID*, and replaces `InFocus-Drive-mac.zip` and its
`SHA256SUMS` line on the release. No signing material is stored in the repo or in
GitHub. The app icon is generated from `Resources/brand-mark.png` by
`swift scripts/make-icon.swift`.
