# Meetings Scribe

The Scribe turns Portal producer meetings into notes **on the NAS**. It joins a meeting as a silent listener, records each speaker separately, transcribes with faster-whisper, summarizes with Cloudflare Workers AI (`gpt-oss-120b`) when it's configured or a local Ollama model otherwise, and writes the notes to the Drive. The Portal shows the summary and links to the transcript.

Design: `docs/superpowers/specs/2026-10-03-meetings-design.md` in the infocus-packages repo.

## Pieces

| Piece | Where | Network | Role |
|---|---|---|---|
| Drive routes | `app/meetings_service.py` | host (`infocus-drive`) | Portal-facing service API; relays Scribe notes status to the Portal; serves transcripts |
| `infocus-scribe` | `scribe/` (own image) | `scribe` bridge, published on host `127.0.0.1:8792` only | Headless Chromium, recording, processing queue, on-demand Ollama |

## Nothing heavy while idle

When no meeting is live and nothing is queued, the Scribe is just its small FastAPI process (tens of MB). Everything heavy runs on demand and exits:

| Piece | Runs | Ends |
|---|---|---|
| Headless Chromium | Only while a meeting is being recorded | Closed when the recording ends |
| faster-whisper | In a child process, one per processing job | The child exits, so its memory goes back to the system |
| Ollama | `ollama serve` (pinned binary in the image) is started by the job on `127.0.0.1` inside the container | Killed in a `finally` block after the summary, even on errors |

There is no separate Ollama container. Its models are in the `scribe-models` volume (`/models/ollama`). **The first summary downloads the model** (`qwen2.5:1.5b`, about 1 GB). The Scribe logs "Summary model … is not downloaded yet: pulling it now" and then "downloaded". That first meeting's notes take a few minutes longer.

## Isolation (Chromium handles untrusted web content)

- **Non-root.** The Scribe runs as the Playwright image's `pwuser`, renumbered to uid 1000 in `scribe/Dockerfile` (`SCRIBE_UID`), with `cap_drop: ALL` and `no-new-privileges`. The image ships `pwuser` as 1001, which on the NAS is a real person's account, and the notes folder belongs to uid 1000. If you ever change `SCRIBE_UID`, also `chown` the `scribe-tmp`/`scribe-models` volumes and the notes folder to match.
- **Chromium sandbox on.** Chromium launches with `chromium_sandbox=True`. Its namespace sandbox needs unprivileged user namespaces, which Docker's default seccomp profile blocks.
  - Compose therefore sets `security_opt: seccomp=unconfined`. The container is still unprivileged; seccomp is the only thing relaxed.
  - If you keep Chrome's published seccomp profile (`chrome.json`) on the NAS, use `seccomp=/path/to/chrome.json` instead. It is tighter.
  - Never run this container `privileged`.
  - The host kernel must allow unprivileged user namespaces. If Chromium fails to launch with a sandbox error, check `sysctl kernel.unprivileged_userns_clone`.
- **Own bridge network.** The Scribe is not on host networking, so Chromium can't reach UGOS or other services that listen on the NAS loopback.
  - It reaches the Drive app through `host.docker.internal` (the Docker host gateway) on port 8787.
  - Ollama listens only on the container's own loopback, so it is never reachable from outside the Scribe.
- **Only the notes folder is mounted.** The Scribe can write `<Drive>/<IFD_MEETINGS_ROOT>` and nothing else on the Drive. Raw audio and the whisper model live in named volumes.
- **No Portal token.** The Scribe holds only `SCRIBE_INTERNAL_TOKEN`, a separate random secret.
  - It reports notes status to the Drive at `POST /api/internal/scribe/notes/{meetingId}`.
  - The Drive relays the status to the Portal with `PACKAGES_SERVICE_TOKEN`.
- **The internal endpoint is local only.** It answers only direct callers from loopback or private addresses that carry no proxy headers (`X-Forwarded-For`, `X-Real-IP`, `CF-Connecting-IP`, `Forwarded`), and only with the Scribe token.
  - The nginx gateway also returns 404 for `/api/internal/`.
  - Copy that block from `nginx.conf.example` into the live `nginx.conf`.
- **Pinned origins.** Start requests are refused unless `portalBaseUrl` matches `PORTAL_BASE_URL` and `roomUrl` matches `MEETING_ROOM_URL`. The Drive and the Scribe both check this.
- **Keep Chromium and Ollama current.** Rebuild the Scribe image when Playwright or Ollama ships an update (Ollama: the `OLLAMA_VERSION` build arg), which includes a newer Chromium with security fixes. Bump the `FROM` tag in `scribe/Dockerfile` and `playwright` in `scribe/requirements.txt` together, then `docker compose build --pull infocus-scribe`.

## Flow

1. The Portal calls `POST /api/service/meetings/scribe/start` when a meeting with notes on goes live.
   - **Preflight:** the Scribe first checks that the notes folder (`/meetings`) and the recordings volume (`/scribe-tmp`) are writable, with a real write test. If either isn't, it posts `FAILED` with reason "notes folder not writable" and answers 503, instead of recording for an hour and failing at the end. The same check runs at startup (logged loudly) and on every `/health` call, which returns 503 so Docker marks the container unhealthy.
   - Each start creates a job folder in `/scribe-tmp` with a `job.json` marker: the meeting id, title, startsAt, recording start, part number, state, attempts, and later the speakers map.
2. The Scribe opens `${PORTAL_BASE_URL}/meet-scribe#mid=…&room=…&token=…&key=…&epoch=…` in headless Chromium and waits until the page exposes `window.__scribe`. The room token and meeting key are only in the URL fragment, which browsers never send to a server. They are never logged.
3. It posts `RECORDING`. The page sends each remote speaker's audio as 10-second WebM/Opus chunks, which are written to the job folder.
   - **Rekeys and new tickets** (`/scribe/rekey`) are stored on the session. If Chromium is still loading, they are applied as soon as the page is ready (the answer is `"pending"`, not a 404). New tickets go to `window.__scribe.setTicket(token)` when the page has it; either way the latest key and ticket are used for any relaunch.
   - **Chromium crashes** (page crash or browser disconnect) are relaunched up to 2 times within the same part, with the current key and ticket.
4. The recording ends on `stop`, when the page signals `ended` or `removed`, after relaunches run out, or after 4 hours.
   - Before closing, the Scribe calls `window.__scribe.leave()` (5-second limit), so each speaker's last chunk is flushed.
   - The marker becomes `queued` with the speakers map, the Scribe posts `PROCESSING`, and the job is queued. Meetings are processed one at a time.
5. Processing joins each speaker's chunks and ffmpeg cuts them into **20-minute 16 kHz mono pieces**. A spawned child process transcribes the pieces one after another with faster-whisper (VAD filter), each with its time offset. The speakers are then merged by time into lines like `[hh:mm:ss] Name: text`. Ollama writes the notes (see "Notes format").
   - The parent watches the child. Each piece has a timeout of 3× its length + 10 minutes (+15 minutes for the first piece, which loads or downloads the model). The child is killed above `SCRIBE_WHISPER_MAX_MB` resident memory.
   - A piece that errors, times out, runs out of memory or crashes the child becomes a **gap**. The next piece gets a fresh child, and the notes are still written. `transcript.md` starts with a "missing" list (speaker and time range, with the reason), `transcript.json` has `gaps` and `complete: false`, and the summary ends with a note.
6. Notes are written to `<IFD_MEETINGS_ROOT>/<YYYY-MM-DD HHmm> <title> (<last 6 of id>) rec <HHmm>[ part N]/` as `transcript.md`, `transcript.json` and `summary.md`. Times are in `SCRIBE_TIMEZONE`.
   - `rec` is the recording's start time.
   - `part N` (N ≥ 2) marks a later recording of the same meeting: after the 4-hour cap, after a Scribe restart, or a reopened meeting or notes turned off and on. A later part never overwrites part 1.
   - The Portal gets each part's own `drivePath`, and the transcript endpoint returns all parts in order.
7. The Scribe posts `READY` with `{summaryMarkdown, drivePath}`.

If the summary fails entirely (Ollama can't start, the pull fails, or the model errors), the notes are still `READY`, with "Summary unavailable" in place of the summary. The transcript is the part that matters most.

### What happens to the raw audio

Raw audio is never deleted because something after the recording failed.

| Outcome | Job state | Raw audio |
|---|---|---|
| Complete notes, Portal acknowledged `READY` | (folder deleted) | deleted |
| Notes with gaps, `READY` acknowledged | `partial` | kept for a manual retry until the 7-day cleanup |
| Notes written, `READY` not acknowledged | `written` | kept. The hourly pass re-sends `READY` from `summary.md` (no re-transcription) |
| Transcription crash, write error, anything else | `failed` (reason in `last_error`) | kept. `FAILED` with a reason is posted. Retried at the next start and hourly, up to 3 attempts |
| Notes folder not writable when processing starts | `failed` | kept. Not counted as an attempt, so it is retried hourly until fixed |
| Chromium never joined and nothing was recorded | (folder deleted) | none. `FAILED` "could not join the meeting" |

- **Restart safety:** at startup every job folder with a marker that isn't finished is queued again: `recording` (interrupted by a deploy or reboot), `queued`, `processing`, `written`, and `failed` with attempts left.
- **Graceful shutdown:** compose gives the container `stop_grace_period: 60s`. Live pages are asked to leave and their jobs are marked `queued` before it exits.
- **The rest of a live meeting:** a Scribe restart ends the current part. The Portal must call `start` again for the rest of the meeting, which records it as a new part.
- **Manual retry of a `partial` job:** set `"state": "queued"` in its `job.json` and restart the container. It rewrites the same notes folder.

## Notes format (same as Redrule)

The prompt, JSON shape, parser and markdown are ported from Redrule's `MinutesCore` (`Summary.swift`, `Summarizer.swift`, `Models.swift`), in `scribe/app/summarize.py`. The only change to the prompt is the speaker sentence: labels are the participants' InFocus names, from their own audio tracks.

- **User line:** `InFocus producer meeting "<title>", started <date, time Pacific>.` followed by the transcript.
- **Workers AI** (when configured): the whole transcript goes in one call, up to about 300,000 characters (the 4-hour recording cap). If the call fails (network, Cloudflare error), the local model writes the notes instead.
- **Long transcripts (local model):** transcripts over 12,000 characters (sized for a small model, `num_ctx` 8192) are first digested chunk by chunk into plain bullets. The note is then written from the digests.
- **Bullets:** list markers the model puts in front of bullets, decisions and tasks ("- ", "* ", "1. ") are removed, so the markdown never shows "- - ".
- **JSON:** the model returns `{title, tldr, sections[{heading, bullets}], decisions, action_items[{owner, task}]}`, enforced with Ollama's `format` JSON schema (Workers AI gets the same shape from the prompt; the parser checks it).
  - The parser tolerates code fences or prose around the JSON.
  - If the reply isn't valid JSON, it retries once. If that fails too, it keeps the model's raw text as the tl;dr.
- **Markdown** (`summary.md`, also sent to the Portal as `summaryMarkdown`):

```markdown
# <title>

<tldr>

## <heading>
- <bullet>

## Decisions
- <decision>

## Action items
- [ ] **<Owner>** — <task>
- [ ] <task without an owner>
```

Every hour the worker deletes recordings older than 7 days (by the marker's recording start), retries `failed` jobs, and re-sends `READY` calls that didn't get through. Live and queued recordings are never removed.

### Long meetings

- **Whisper memory:** whisper decodes a whole file, copies its speech for VAD and computes features for all of it, roughly 0.8 GB per stream-hour plus 1.2 GB per speech-hour. A 2–4 hour stream therefore used to be OOM-killed under the 3 GB limit. The 20-minute pieces keep the child at about 1 GB whatever the meeting length.
- **Disk:** the WAV pieces of one speaker (about 115 MB per hour) sit in `scribe-tmp` while that speaker is transcribed.
- **Summary:** each transcript chunk (about 12,000 characters) becomes a digest of at most about 300 tokens (`num_predict`). If all the digests together exceed about 16,000 characters (for example 20 digests from a 4-hour meeting), they are digested again, up to 4 rounds, before the final call, so the final prompt fits `num_ctx` 8192.

## Drive API

Portal → Drive (Bearer `PACKAGES_SERVICE_TOKEN`):

| Method | Path | Body / result |
|---|---|---|
| POST | `/api/service/meetings/scribe/start` | `{meetingId, title, startsAt, roomUrl, roomToken, key, epoch, portalBaseUrl}` → `{ok, state: "starting" \| "already-recording", part}`. A healthy recording answers `already-recording`. After the 4-hour cap, a Chromium failure, a restart or a stop, the same meeting starts a **new part**. 503 "notes folder not writable" when the preflight fails |
| POST | `/api/service/meetings/scribe/rekey` | `{meetingId, key, epoch, roomToken?, roomUrl?, ticketExpiresAt?}` → `{ok, state: "applied" \| "pending"}`, or 404 when not recording. `roomToken` (optional, additive) is the re-ticket, sent about every 2 hours and on every rekey. `roomUrl` must match `MEETING_ROOM_URL`. Only `roomToken` is passed on to the Scribe |
| POST | `/api/service/meetings/scribe/stop` | `{meetingId}` → `{ok, state: "stopping" \| "not-recording"}` |
| GET | `/api/service/meetings/{meetingId}/transcript` | `text/markdown` transcript, or 404 |

Scribe → Drive (Bearer `SCRIBE_INTERNAL_TOKEN`, local callers only):

| Method | Path | Body / result |
|---|---|---|
| POST | `/api/internal/scribe/notes/{meetingId}` | `{status: RECORDING\|PROCESSING\|READY\|FAILED, summaryMarkdown?, drivePath?, reason?}` (`reason` ≤ 200 characters, for example "notes folder not writable"; the Portal may ignore it), relayed to Portal `POST /api/service/meetings/{id}/notes`. Returns `{ok}`; 502 if the Portal is unreachable (the Scribe retries) |

Validation:
- `meetingId` must match `^[a-z0-9]{10,40}$`.
- `key` is base64url.
- `epoch` is 0–1,000,000.
- URLs must be https and pinned (see Isolation).
- `drivePath` must be a single folder under `IFD_MEETINGS_ROOT`.

A 422 never echoes the submitted values. If `SCRIBE_INTERNAL_TOKEN` is unset, the scribe routes return 503. If the Scribe is down, they return 502.

## Scribe page contract (Portal `/meet-scribe`)

The Scribe exposes two functions to the page:

- `window.scribeChunk(uid, name, startMs, seq, base64)` sends one MediaRecorder chunk for a remote audio track.
  - `seq` starts at 0 for every new recorder. Chunk 0 carries the WebM header.
  - `startMs` of chunk 0 is the stream's wall-clock start (`Date.now()`).
  - A speaker who reconnects starts a new recorder (`seq` 0 again).
  - Chunks that arrive before a speaker's chunk 0 are dropped.
- `window.scribeEvent(kind)`: `"ended"` or `"removed"` stops the recording.

The page provides `window.__scribe = { setKey(key, epoch), setTicket?(token), leave() }`:
- `setKey` for rekeys.
- `setTicket` (optional) for a fresh room ticket.
- `leave()` stops the recorders and resolves after their last chunks are handed over. The Scribe calls it before closing.

The Scribe treats the page as joined once `window.__scribe` exists.

## Privacy

- Audio never leaves the NAS, and transcription runs locally.
- **Summaries:** with `SCRIBE_WORKERS_AI_ACCOUNT_ID` and `SCRIBE_WORKERS_AI_TOKEN` set, the finished transcript text is sent to Cloudflare Workers AI for one summary request. Cloudflare keeps no prompts or outputs and doesn't train on them ([Your Data and Workers AI](https://developers.cloudflare.com/workers-ai/platform/data-usage/)), but it does read the text in plain form while summarizing. Leave both empty to keep summaries on the NAS (local Ollama model).
- Raw audio is deleted once the Portal has complete notes. If something failed, it is kept so the notes can be retried (see "What happens to the raw audio"). Anything older than 7 days is removed hourly.
- The notes folder is on the InFocus Drive share, so **anyone with access to that share can read it**, not only producers. To keep notes private, set `IFD_MEETINGS_ROOT` to a folder whose NAS permissions are limited to producers and admins, while still letting uid 1000 write to it.
- Files are owned by uid 1000 (the container's renumbered `pwuser`; the NAS service owner). Check `getent passwd 1000` on a new NAS and pick a non-person uid for `SCRIBE_UID` if needed.

## Environment (NAS `.env`)

| Name | Default | Used by | Purpose |
|---|---|---|---|
| `SCRIBE_INTERNAL_TOKEN` | **required** | Drive + Scribe | Drive ↔ Scribe bearer, both directions. Use its own random value (`openssl rand -hex 32`), not the packages token. Compose refuses to start without it. |
| `PORTAL_BASE_URL` | (required for notes) | Drive + Scribe | Portal origin: the scribe page, the start-request pin and the notes relay |
| `MEETING_ROOM_URL` | (required for notes) | Drive + Scribe | Meeting room Worker origin; start requests' `roomUrl` must match |
| `PACKAGES_SERVICE_TOKEN` | (existing) | Drive only | Portal ↔ Drive bearer (the Portal's `DRIVE_SERVICE_TOKEN`) |
| `SCRIBE_URL` | `http://127.0.0.1:8792` | Drive | Where the Drive finds the Scribe |
| `IFD_MEETINGS_ROOT` | `.ifd-meetings` | Drive + Scribe | Notes folder, relative to the Drive root; the only folder mounted into the Scribe |
| `SCRIBE_WHISPER_MODEL` | `small.en` | Scribe | faster-whisper model (`base.en` is faster, `medium.en` is slower) |
| `SCRIBE_WHISPER_THREADS` | `2` | Scribe | CPU threads for transcription |
| `SCRIBE_WHISPER_MAX_MB` | `2000` | Scribe | Resident-memory cap for the whisper child; a 20-minute piece above it becomes a gap |
| `SCRIBE_OLLAMA_MODEL` | `qwen2.5:1.5b` | Scribe | Local summary model (any Ollama tag; pulled on first use). The fallback when Workers AI is set |
| `SCRIBE_WORKERS_AI_ACCOUNT_ID` | empty | Scribe | Cloudflare account id. With the token, Workers AI writes the summary |
| `SCRIBE_WORKERS_AI_TOKEN` | empty | Scribe | Cloudflare API token with only the **Workers AI** permission (secret; NAS `.env` only) |
| `SCRIBE_WORKERS_AI_MODEL` | `@cf/openai/gpt-oss-120b` | Scribe | Workers AI model (128k-token context: a whole meeting in one call) |
| `SCRIBE_TIMEZONE` | `America/Los_Angeles` | Scribe | Folder names and transcript date |

Compose sets the in-container values `SCRIBE_DRIVE_URL`, `SCRIBE_MEETINGS_DIR`, and `IFD_SCRIBE_TMP`. The image sets `OLLAMA_MODELS=/models/ollama`.

## Resources

- **CPU:** compose caps the Scribe at 2 CPUs, so the Drive stays responsive.
  - On NAS-class CPUs, expect a 45-minute meeting to take roughly **20–35 minutes** to transcribe with `small.en`, plus a few minutes for the summary.
  - Benchmark on your NAS with a real recording before relying on this. If it is too slow, try `base.en`.
- **RAM:** idle, only the FastAPI process (tens of MB). While working: Chromium needs about 300–500 MB per live meeting, the whisper `small.en` int8 child about 1 GB per 20-minute piece whatever the meeting length (killed above `SCRIBE_WHISPER_MAX_MB`), and `qwen2.5:1.5b` about 1.5 GB while it summarizes. Whisper and Ollama run one after the other, never together. The container limit is 3 GB.
- **Disk:**
  - The Playwright base image is about 2 GB, plus the CPU-only Ollama binary.
  - The whisper model is about 500 MB, in the `scribe-models` volume.
  - `qwen2.5:1.5b` is about 1 GB, in the same `scribe-models` volume (`/models/ollama`).
  - Raw audio is about 15–20 MB per speaker-hour, in the `scribe-tmp` volume.

## First-time setup

```bash
# On the NAS, in the compose project directory
# 1. .env: add SCRIBE_INTERNAL_TOKEN (new random value), PORTAL_BASE_URL, MEETING_ROOM_URL
# 2. Create the notes folder and let the Scribe's uid 1000 write to it
#    (an ACL keeps the folder's existing owner and group permissions)
sudo mkdir -p "/volume2/InFocus Drive/.ifd-meetings"
sudo setfacl -m u:1000:rwx -m d:u:1000:rwx "/volume2/InFocus Drive/.ifd-meetings"
# 3. nginx: copy the `location /api/internal/` block from nginx.conf.example into nginx.conf
# 4. Build and start (recreate the gateway for the nginx change)
sudo docker compose up -d --build infocus-scribe infocus-drive
sudo docker compose up -d --force-recreate gateway
# 5. Check (the summary model downloads itself on the first summary)
sudo docker exec infocus-scribe python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8792/health').read())"
```

If an earlier deploy created an `infocus-ollama` container, remove it with `sudo docker compose up -d --remove-orphans`, or `sudo docker rm -f infocus-ollama`.

The whisper model downloads on the first meeting that is processed. To fetch it ahead of time, run `sudo docker exec infocus-scribe python -c "from faster_whisper import WhisperModel; WhisperModel('small.en', device='cpu', compute_type='int8')"`.

If a NAS firewall blocks Docker bridge → host traffic, allow the `scribe` network's subnet to reach port 8787.

## Troubleshooting

| Symptom | Check |
|---|---|
| Portal never leaves RECORDING/PROCESSING | `docker logs infocus-scribe` for "notes … rejected" or connection errors; can the container reach `host.docker.internal:8787`? |
| Start returns 422 | `PORTAL_BASE_URL` / `MEETING_ROOM_URL` set and equal to the origins the Portal sends? |
| Start returns 503 | `SCRIBE_INTERNAL_TOKEN` missing in the Drive's `.env` |
| Drive returns 502 for scribe routes | Scribe container down |
| FAILED right after start, `/health` 503 | Preflight: `/meetings` or `/scribe-tmp` not writable by uid 1000 ("PREFLIGHT FAILED" in the logs) |
| FAILED "could not join the meeting" | Chromium could not launch or join: sandbox/seccomp (see Isolation), or `/meet-scribe` unreachable |
| Notes FAILED at the end | `docker logs infocus-scribe` and `last_error` in the job's `job.json`; the audio is kept and retried hourly (up to 3 attempts) |
| "missing" list in a transcript | A piece timed out, ran out of memory (`SCRIBE_WHISPER_MAX_MB`) or crashed; the job is `partial` and its audio kept for 7 days |
| Notes READY but "Summary unavailable" | `docker logs infocus-scribe`: did `ollama serve` start, and did the first-run model pull finish (network, disk)? |
| Transcript empty | The scribe page sent no chunks (check the Portal `/meet-scribe` page and E2EE key) |
