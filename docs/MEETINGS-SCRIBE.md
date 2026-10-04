# Meetings Scribe

The Scribe turns Portal producer meetings into notes **on the NAS**. It joins a meeting as a silent listener, records each speaker separately, transcribes with faster-whisper, summarizes with a local Ollama model, and writes the notes to the Drive. The Portal shows the summary and links to the transcript.

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

- **Non-root.** The Scribe runs as the Playwright image's `pwuser` (uid 1000), with `cap_drop: ALL` and `no-new-privileges`.
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
2. The Scribe opens `${PORTAL_BASE_URL}/meet-scribe#mid=…&room=…&token=…&key=…&epoch=…` in headless Chromium. The room token and meeting key are only in the URL fragment, which browsers never send to a server. They are never logged.
3. It posts `RECORDING`. The page sends each remote speaker's audio as 10-second WebM/Opus chunks, which are written to the `scribe-tmp` volume.
4. The recording ends on `stop`, when the page signals `ended` or `removed`, when the page closes or crashes, or after 4 hours. The Scribe then posts `PROCESSING` and queues the recording. Meetings are processed one at a time.
5. Processing joins each speaker's chunks, then ffmpeg converts them to 16 kHz mono. faster-whisper transcribes with the VAD filter, and the speakers are merged by time into lines like `[hh:mm:ss] Name: text`. Ollama then writes the notes (see "Notes format").
6. Notes are written to `<IFD_MEETINGS_ROOT>/<YYYY-MM-DD HHmm> <title> (<last 6 of id>)/` as `transcript.md`, `transcript.json` and `summary.md`. The folder time is in `SCRIBE_TIMEZONE`.
7. The raw audio is deleted, and the Scribe posts `READY` with `{summaryMarkdown, drivePath}`.
   - On any failure it posts `FAILED` and **also deletes the raw audio**, since nothing retries.
   - If Chromium never joined the meeting, the status is `FAILED`.

If the summary fails entirely (Ollama can't start, the pull fails, or the model errors), the notes are still `READY`, with "Summary unavailable" in place of the summary. The transcript is the part that matters most.

## Notes format (same as Redrule)

The prompt, JSON shape, parser and markdown are ported from Redrule's `MinutesCore` (`Summary.swift`, `Summarizer.swift`, `Models.swift`), in `scribe/app/summarize.py`. The only change to the prompt is the speaker sentence: labels are the participants' InFocus names, from their own audio tracks.

- **User line:** `InFocus producer meeting "<title>", started <date, time Pacific>.` followed by the transcript.
- **Long transcripts:** transcripts over 12,000 characters (sized for a small model, `num_ctx` 8192) are first digested chunk by chunk into plain bullets. The note is then written from the digests.
- **JSON:** the model returns `{title, tldr, sections[{heading, bullets}], decisions, action_items[{owner, task}]}`, enforced with Ollama's `format` JSON schema.
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

Raw audio older than 7 days is removed every hour by the worker. This catches leftovers from a container stop during a meeting. Live recordings are never removed.

## Drive API

Portal → Drive (Bearer `PACKAGES_SERVICE_TOKEN`):

| Method | Path | Body / result |
|---|---|---|
| POST | `/api/service/meetings/scribe/start` | `{meetingId, title, startsAt, roomUrl, roomToken, key, epoch, portalBaseUrl}` → `{ok, state: "starting" \| "already-recording"}` |
| POST | `/api/service/meetings/scribe/rekey` | `{meetingId, key, epoch}` → `{ok}`, or 404 when not recording |
| POST | `/api/service/meetings/scribe/stop` | `{meetingId}` → `{ok, state: "stopping" \| "not-recording"}` |
| GET | `/api/service/meetings/{meetingId}/transcript` | `text/markdown` transcript, or 404 |

Scribe → Drive (Bearer `SCRIBE_INTERNAL_TOKEN`, local callers only):

| Method | Path | Body / result |
|---|---|---|
| POST | `/api/internal/scribe/notes/{meetingId}` | `{status: RECORDING\|PROCESSING\|READY\|FAILED, summaryMarkdown?, drivePath?}`, relayed to Portal `POST /api/service/meetings/{id}/notes`. Returns `{ok}`; 502 if the Portal is unreachable (the Scribe retries) |

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

The page must provide `window.__scribe.setKey(key, epoch)` for rekeys.

## Privacy

- Audio never leaves the NAS. Transcription and summaries run locally, and no cloud speech or LLM service is used.
- Raw audio is deleted as soon as notes are written or processing fails. Any leftovers older than 7 days are removed hourly.
- The notes folder is on the InFocus Drive share, so **anyone with access to that share can read it**, not only producers. To keep notes private, set `IFD_MEETINGS_ROOT` to a folder whose NAS permissions are limited to producers and admins, while still letting uid 1000 write to it.
- Files are owned by uid 1000 (the container's `pwuser`). On the NAS that uid may belong to a real account, so check `getent passwd 1000`.

## Environment (NAS `.env`)

| Name | Default | Used by | Purpose |
|---|---|---|---|
| `SCRIBE_INTERNAL_TOKEN` | **required** | Drive + Scribe | Drive ↔ Scribe bearer, both directions. Use its own random value (`openssl rand -hex 32`), not the packages token. Compose refuses to start without it. |
| `PORTAL_BASE_URL` | (required for notes) | Drive + Scribe | Portal origin: the scribe page, the start-request pin and the notes relay |
| `MEETING_ROOM_URL` | (required for notes) | Drive + Scribe | Meeting room Worker origin; start requests' `roomUrl` must match |
| `PACKAGES_SERVICE_TOKEN` | (existing) | Drive only | Portal ↔ Drive bearer (the Portal's `DRIVE_SERVICE_TOKEN`) |
| `SCRIBE_URL` | `http://127.0.0.1:8792` | Drive | Where the Drive finds the Scribe |
| `IFD_MEETINGS_ROOT` | `Meetings` | Drive + Scribe | Notes folder, relative to the Drive root; the only folder mounted into the Scribe |
| `SCRIBE_WHISPER_MODEL` | `small.en` | Scribe | faster-whisper model (`base.en` is faster, `medium.en` is slower) |
| `SCRIBE_WHISPER_THREADS` | `2` | Scribe | CPU threads for transcription |
| `SCRIBE_OLLAMA_MODEL` | `qwen2.5:1.5b` | Scribe | Summary model (any Ollama tag; pulled on first use) |
| `SCRIBE_TIMEZONE` | `America/Los_Angeles` | Scribe | Folder names and transcript date |

Compose sets the in-container values `SCRIBE_DRIVE_URL`, `SCRIBE_MEETINGS_DIR`, and `IFD_SCRIBE_TMP`. The image sets `OLLAMA_MODELS=/models/ollama`.

## Resources

- **CPU:** compose caps the Scribe at 2 CPUs, so the Drive stays responsive.
  - On NAS-class CPUs, expect a 45-minute meeting to take roughly **20–35 minutes** to transcribe with `small.en`, plus a few minutes for the summary.
  - Benchmark on your NAS with a real recording before relying on this. If it is too slow, try `base.en`.
- **RAM:** idle, only the FastAPI process (tens of MB). While working: Chromium needs about 300–500 MB per live meeting, the whisper `small.en` int8 child about 1 GB, and `qwen2.5:1.5b` about 1.5 GB while it summarizes. Whisper and Ollama run one after the other, never together. The container limit is 3 GB.
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
sudo mkdir -p "/volume2/InFocus Drive/Meetings"
sudo setfacl -m u:1000:rwx -m d:u:1000:rwx "/volume2/InFocus Drive/Meetings"
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
| FAILED right after start | Chromium could not launch or join: sandbox/seccomp (see Isolation), or `/meet-scribe` unreachable |
| Notes FAILED at the end | Meetings folder not writable by uid 1000 (`Permission denied` in the logs) |
| Notes READY but "Summary unavailable" | `docker logs infocus-scribe`: did `ollama serve` start, and did the first-run model pull finish (network, disk)? |
| Transcript empty | The scribe page sent no chunks (check the Portal `/meet-scribe` page and E2EE key) |
