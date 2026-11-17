# Team editing for FilmCraft over InFocus Drive: design

Date: 2026-11-15. Status: draft for owner review.

## Why

InFocus members cut packages and features in small teams (2 to 3 people), often from home on their own Macs. Today the project lives on one person's computer. The goal is one shared project that every teammate can open and edit on their own Mac, synced through InFocus Drive, open only to InFocus members, with editing as fast as with local media.

## Goals

- A public fork of `storytold/filmcraft` (Rust, Apache-2.0/MIT) with team projects added.
- Team projects live on InFocus Drive. Signing in uses the existing Drive accounts, so only InFocus members get in, and the NAS ACLs decide who can open which project folder.
- **One editor per sequence.** Opening a sequence to edit takes its lock. Teammates can open it read-only and see the editor's changes within a few seconds.
- Each Mac edits from **proxies it makes itself** from originals downloaded off the Drive. Editing never streams from the NAS.
- **Export runs on the editor's Mac** from the originals.
- **Seamless, fast and light on the Drive (owner, 2026-11-15):** editing must run at local speed, never playing footage from the Drive. Opening a project, getting footage and cleaning up happen on their own without members managing files. The Drive should not be overloaded or filled up: each Mac fetches each original once, downloads are rate-limited, and old footage is cleaned up automatically (section 6a).

## Non-goals

- Live co-editing of the same sequence (Google Docs style), offline edit-then-merge, and presence cursors.
- Windows, Linux and the browser build. The fork keeps them compiling where it is free to, but only the Mac app is built and tested.
- NAS-side transcoding or rendering.

## Anti-goals (a failure even if it works)

- Two people editing the same sequence at once and one losing work.
- A lost lock (a Mac asleep or offline) leaving a sequence stuck.
- Editing that feels slower than plain FilmCraft with local files.
- Anyone without an InFocus Drive account reading a project or its media.

## Approaches considered

| | Approach | Trade-off | Picked |
|---|---|---|---|
| A | A project service inside infocus-drive (FastAPI): locks, sequence revisions and a change feed behind Drive auth | Server-enforced locks can't race, updates arrive in seconds. More work in infocus-drive. | **Yes (owner)** |
| B | Plain project and lock files on the Drive, synced by the `infocus` CLI or WebDAV | No server changes, but lock files race and updates arrive slowly. | No |
| C | Live operation-level co-editing (CRDT or OT on engine commands) | The most "seamless", but much harder on a 360k-line editor. The owner chose per-sequence locks instead. | No |

Media: the owner chose **each Mac makes its own proxies** over NAS-made proxies, and **export on the editor's Mac** over the studio Mac.

## What exists today (relevant)

- **FilmCraft:** a `Project` is plain serde data (bins, a flat `items` map keyed by `u64` ids, sequences with tracks and clips), saved as `.fcproj` compact JSON (`crates/format`, schema v17). Media is referenced by path, and items carry media identity fingerprints (schema 6). Every edit goes through the engine's named command layer (`crates/engine`, for example `media.relink`, `file.*`) with copy-on-write `Arc<Project>` snapshots for undo. Link Media (`media.relink`, `media.autoRelink`) already exists. The app UI is egui (`crates/ui-egui`, `apps/filmcraft`). **Proxies already exist** (`crates/engine/src/proxies.rs`): background create (ProRes 422 Proxy/LT or H.264 at ¼ or ½ size), attach, Toggle Proxies, Reconnect Full Resolution; export always uses full resolution. The proxy path is stored in the project (`MediaClip::proxy: Option<MediaRef>`, `crates/project/src/item.rs`). Undo restores whole-project snapshots. Sequences are items in the same `items` map as media, not separate records.
- **InFocus Drive:** FastAPI + nginx on the UGOS NAS behind a Cloudflare tunnel, with a LAN fast path on campus. Google sign-in maps members to NAS users, and file operations run as that user's uid. `app/cli_tokens.py` already issues revocable `ifd_` bearer tokens through PKCE for the `infocus` CLI and the Mac app. Resumable chunked uploads and range downloads exist.

## Design

### 1. The fork

- Repo `neelsatyavolu/filmcraft-infocus` (public), forked from `storytold/filmcraft`, with an `upstream` remote and regular merges from upstream. *(Builder's call: the repo and app name. Suggested app name: "InFocus Cut".)*
- Team code goes in **new crates** (`crates/team`, `crates/drive-client`) plus thin hooks in the engine and UI, so upstream merges stay easy. Keep the hooks small and listed in `docs/team-editing.md`.
- InFocus specifics (Drive URL, LAN address, OAuth client) go in a config file or build-time env, not in source, because the repo is public.

### 2. Sign-in

- The app signs in with the same PKCE flow as the `infocus` CLI: it opens the browser to Drive `/cli/authorize`, receives an `ifd_` token, and stores it in the macOS Keychain.
- Every project API call and media download sends that token. The server runs file access as the member's uid, so the NAS ACLs on the project folder decide who can open what.

### 3. Team project layout on the Drive

A team project is a folder on the Drive, for example `Packages/2026-11 Robotics/`:

```
Robotics.fcteam/
  project.json        # shared part: settings, bins, media items, source graphics, transcripts
  sequences/<id>.json # one file per sequence
  meta.json           # revision counters, member id slots
Media/                # originals, uploaded by whoever imports them (existing Drive uploads)
```

- The server is the only writer of `.fcteam/`. Clients go through the API, never WebDAV.
- **Ids:** FilmCraft gives out `u64` ids from one `next_id` counter, so two Macs would collide. Each member gets a slot in `meta.json` when they first open the project, and the fork makes the engine's id allocator use `slot << 48 | local_counter`. Old single-user projects import with their ids unchanged into slot 0.
- **Media paths:** a team media item stores a Drive path (`drive:/Packages/2026-11 Robotics/Media/A001.mov`) plus the fingerprint, never a local path. A per-Mac resolver maps it to the local proxy (for playback) or the local original (for export).

### 4. Project service (infocus-drive)

New FastAPI router `app/team_projects.py`, with state in SQLite next to the existing token DB (or in `meta.json`; builder's call):

- `POST /team/projects` creates a team project in a Drive folder (from an empty project or an uploaded `.fcproj`).
- `GET /team/projects/{id}` returns the shared part, every sequence, revisions, and current locks.
- `POST /team/projects/{id}/sequences/{seq}/lock` takes the lock. It succeeds only if the sequence is free or the lock has expired. Response: lock token, expiry.
- `POST …/lock/heartbeat` every 20 s; a lock expires 2 min after the last heartbeat. `DELETE …/lock` releases it.
- `PUT …/sequences/{seq}` takes the lock token, base revision and the full sequence JSON, and bumps the revision. A put without the current lock, or on a stale base revision, is rejected.
- `POST /team/projects/{id}/shared` makes additive changes to the shared part: add media items, bins, source graphics. Merge by id, so two people importing at once both win. Renames and deletes of shared items are last-writer-wins, and an item still used by any sequence can't be deleted.
- `GET /team/projects/{id}/events` is a server-sent event stream (`sequence_updated`, `lock_changed`, `shared_updated`), so viewers refresh within a second or two. Fallback: poll every 5 s.
- Every write is checked against the member's access to the project folder by running as their uid, the same as file operations. `fsops.as_user` switches the whole process's uid under a global lock (`fsops.py`), so only the file read/write itself runs inside it; locks, SSE and the service's SQLite state run outside it.
- **Schema version:** `meta.json` records the FilmCraft schema version and minimum app version. The server rejects pushes from older apps, and the app tells the member to update. *(My call: stops an older app from dropping newer fields.)*
- **Where projects live:** all team projects sit under one Drive root, `Team Projects/`, so listing is a folder read. The project id is stored in `meta.json`, so it survives a rename. The Drive web UI shows a `.fcteam` folder as one item and blocks editing inside it; SMB/WebDAV changes are not blocked, but the server checks file hashes against its own revisions and refuses to serve a project whose files changed underneath it. *(My call.)*
- Admins can force-release a lock (needed when someone's Mac dies mid-edit).

### 5. App behaviour

- **Open a team project** from a "Team Projects" browser in the app (lists `.fcteam` folders the member can read).
- **Sequence tabs** show the state: *Editing* (yours), *Read-only: Maya is editing*, or *Free: Edit*. Opening a free sequence asks for the lock. Read-only sequences render and play normally but block every edit command at the engine's command entry point.
- **What the lock covers:** everything inside that sequence (tracks, clips, effects, keyframes, captions, sequence markers and settings). Edits that change shared items from inside a sequence (a media clip's marks, markers or Interpret Footage settings, transcripts, narrations, new source graphics or a new nested sequence) go through `/shared` as per-item last-writer-wins updates and need no lock. The builder makes a table mapping each engine command to "sequence", "shared" or "both", and read-only blocking uses that table. *(My call.)*
- **Undo:** your undo history covers only your own edits. Undo restores the locked sequence from its snapshot and leaves teammates' sequences and the shared part as they are now. Shared-part changes are not undoable in v1. *(My call.)*
- **Pushing:** while you hold the lock, each completed edit (one undo step) schedules a debounced push (about 1 s) of that sequence's JSON. Undo stays local to the editor. A failed push retries, and a sequence with unpushed edits shows a "not synced" badge.
- **Receiving:** a `sequence_updated` event for a read-only sequence fetches it and swaps it into the local `Project` (copy-on-write, so the open view just redraws).
- **Losing the lock** (heartbeat failed, Mac slept past expiry): the sequence turns read-only, local unpushed edits are saved as a separate "Recovered – <name>" sequence so nothing is lost, and the editor is told what happened.
- The crash-recovery journal and autosave stay local, as in upstream.

### 6. Media: download, proxy, export

- **Download (owner's choice: only what you open):** the app downloads originals only for the sequences you open, plus any clip you load into the Source monitor or drag onto a timeline. Opening a project downloads nothing. Clips not downloaded yet show FilmCraft's offline slate with a progress bar until their proxy is ready. Downloads go through Drive range downloads with resume. It uses the LAN fast path on campus and the tunnel off campus. A media panel shows progress per clip.
- **Proxy:** after a download finishes, the Mac runs FilmCraft's existing proxy job (`proxies.rs`, ProRes 422 Proxy at ½ size by default) and attaches the result. No new transcoder. Proxies stay on by default in team projects.
- **Local-only fields:** `MediaClip::proxy` and the resolved local file path are per-Mac. The sync layer strips them before pushing and fills them in from the local cache after pulling, so one Mac's paths never reach another.
- **Cache:** `~/Library/Caches/<app>/media/<fingerprint>/{original,proxy}`. Originals are kept for export by default, and a size limit (setting, default 200 GB) evicts originals first, oldest first, never proxies in use. An evicted original downloads again at export.
- **Playback** uses the proxy when it exists, otherwise the original. A Program monitor toggle switches to originals for color checks.
- **Importing:** a member importing new footage uploads it to the project's `Media/` folder (existing chunked upload), then adds the media item through `/shared`. Their own copy of the file becomes their original, so they don't download it again.
- **Export:** before export, the app makes sure every original in the cut is local (downloading what was evicted), then exports with FilmCraft's existing export path, reading originals only.

### 6a. Load and cleanup (owner: 30 days, Mac and Drive)

- **Drive load:** playback and scrubbing never read from the Drive. Each Mac downloads an original once and keeps it until cleanup. At most 2 downloads run at once per Mac, and they pause while an export is reading originals. *(My call on the numbers.)*
- **Cleanup on each Mac:** when this Mac hasn't opened a team project for **30 days**, the app deletes that project's downloaded originals and proxies from the Mac. Reopening downloads them again. The 200 GB size limit still applies between cleanups.
- **Cleanup on the Drive:** when **nobody** has opened a team project for **30 days** (the service records the last open per project), the server moves the whole project (its `.fcteam` folder and its `Media/` folder) to the Drive's `#recycle`, where it can be restored like any other deleted file. Safeguards *(my calls)*:
  - 7 days before, every member who opened the project gets a notice (in the app, plus an email through the Drive's existing Resend setup) with a **Keep** button that resets the clock.
  - The project's creator or a Drive admin can mark a project **Keep forever** (for example a finished package worth archiving).
  - A project with a held lock or an export in progress is never moved.
  - Only the `.fcteam` folder and its own `Media/` folder are moved, never other Drive folders.
  - Every move is logged with the project name, date and members.
- The cleanup runs once a day inside the infocus-drive container.

### 7. Testing

- Rust unit tests for the id allocator, the media resolver, read-only command blocking, and lock-loss recovery. Integration tests run two engine sessions against a fake project service.
- pytest for the FastAPI router: lock races (two takes at once, exactly one wins), expiry, stale-revision puts, additive shared merges, ACL denial for a member without folder access.
- A manual two-Mac test on campus and off campus before release.

## Left to the builder

App and repo naming, the proxy codec, where the service keeps its state, SSE vs polling details, UI layout of the Team Projects browser and lock badges, and how to package and sign the Mac app (follow `mac/sign-release.sh` patterns in infocus-drive).
