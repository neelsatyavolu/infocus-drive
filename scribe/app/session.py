"""Live Scribe sessions: headless Chromium in the meeting as a silent listener.

The meeting key and room token travel only in the URL fragment of the scribe page
(never sent to a server) and are never logged.

- Every recording is a job folder in IFD_SCRIBE_TMP with a `job.json` marker
  (jobs.py), so it survives failures, deploys and reboots.
- Rekeys and new room tickets that arrive while Chromium is still loading are kept
  and applied once the page is ready; a crashed Chromium is relaunched with the
  current key and ticket.
- On stop the page is asked to leave first (flushes each speaker's last chunk).
"""

from __future__ import annotations

import asyncio
import logging
import shutil
import time
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, AsyncIterator, Callable
from urllib.parse import quote, urlencode

from . import jobs, pipeline, portal_client, preflight
from .config import ScribeConfig
from .recorder import ChunkStore, load_streams

log = logging.getLogger("scribe.session")

CHROMIUM_ARGS = ["--autoplay-policy=no-user-gesture-required", "--disable-dev-shm-usage", "--mute-audio"]
STOP_EVENTS = ("ended", "removed")
PAGE_LOAD_TIMEOUT_MS = 60_000
PAGE_READY_TIMEOUT_MS = 30_000
LEAVE_TIMEOUT_SECONDS = 5
FLUSH_GRACE_SECONDS = 0.5
MAX_RELAUNCHES = 2
RELAUNCH_DELAY_SECONDS = 2
MAINTENANCE_INTERVAL_SECONDS = 60 * 60
FAILED_RETRY_AFTER_MS = 60 * 60 * 1000
SHUTDOWN_WAIT_SECONDS = 45
COULD_NOT_JOIN = "could not join the meeting"

SET_KEY_JS = "([k, e]) => window.__scribe && window.__scribe.setKey(k, e)"
SET_TICKET_JS = ("t => { const s = window.__scribe; "
                 "if (s && typeof s.setTicket === 'function') { s.setTicket(t); return true; } return false; }")
LEAVE_JS = "() => window.__scribe ? window.__scribe.leave() : null"
READY_JS = "() => !!window.__scribe"


@dataclass(frozen=True)
class StartRequest:
    meeting_id: str
    title: str
    starts_at: datetime
    room_url: str
    room_token: str
    key: str
    epoch: int
    portal_base_url: str
    # Names the transcriber should expect (vocabulary.py); kept in the job marker for processing.
    vocabulary: tuple[str, ...] = ()


def scribe_page_url(req: StartRequest) -> str:
    fragment = urlencode({"mid": req.meeting_id, "room": req.room_url, "token": req.room_token,
                          "key": req.key, "epoch": str(req.epoch)}, quote_via=quote)
    return f"{req.portal_base_url.rstrip('/')}/meet-scribe#{fragment}"


@dataclass
class Session:
    req: StartRequest
    started_ms: int
    audio_dir: Path
    store: ChunkStore
    part: int
    key: str
    epoch: int
    room_token: str
    key_version: int = 0
    token_version: int = 0
    page_key_version: int = -1
    page_token_version: int = -1
    stop: asyncio.Event = field(default_factory=asyncio.Event)
    page: Any = None
    joined: bool = False
    relaunches: int = 0
    task: asyncio.Task | None = None

    def current_request(self) -> StartRequest:
        """The start request with the latest key and ticket (for a (re)launch)."""
        r = self.req
        return StartRequest(r.meeting_id, r.title, r.starts_at, r.room_url, self.room_token, self.key,
                            self.epoch, r.portal_base_url)

    def healthy(self, now_ms: int, max_seconds: int) -> bool:
        return not self.stop.is_set() and now_ms - self.started_ms < max_seconds * 1000


@asynccontextmanager
async def playwright_browser() -> AsyncIterator[Any]:
    from playwright.async_api import async_playwright  # only in the container

    async with async_playwright() as pw:
        # Runs as a non-root user with Chromium's own sandbox on (docs/MEETINGS-SCRIBE.md).
        browser = await pw.chromium.launch(headless=True, chromium_sandbox=True, args=CHROMIUM_ARGS)
        try:
            yield browser
        finally:
            with suppress(Exception):
                await browser.close()


class SessionManager:
    def __init__(self, cfg: ScribeConfig, *, launcher: Callable[[], Any] = playwright_browser,
                 process: Callable[[ScribeConfig, Path], str] = pipeline.process,
                 post: Callable[..., bool] = portal_client.post_notes) -> None:
        self.cfg = cfg
        self.sessions: dict[str, Session] = {}
        self.queue: asyncio.Queue[Path] = asyncio.Queue()
        self._queued: set[str] = set()
        self._launcher = launcher
        self._process = process
        self._post = post
        self._worker: asyncio.Task | None = None

    # --- lifecycle -------------------------------------------------------------------

    def start_worker(self) -> None:
        self.recover()
        self._worker = asyncio.create_task(self._process_queue())

    def recover(self) -> int:
        """Queue every unfinished job folder (interrupted recordings included). Returns the count."""
        active = self._active_dirs()
        count = 0
        for job_dir in jobs.recoverable(self.cfg.tmp_dir):
            if job_dir.name in active:
                continue
            marker = jobs.read_marker(job_dir)
            try:
                if marker and marker.state == "recording":
                    streams = load_streams(job_dir)
                    jobs.update_marker(job_dir, state="queued", speakers={s.uid: s.name for s in streams})
                    log.info("re-queued a recording interrupted by a restart (%s, part %s)",
                             marker.meeting_id[-6:], marker.part)
            except OSError as e:  # unwritable tmp: preflight reports it; still try to process
                log.error("could not update a job marker: %s", type(e).__name__)
            count += self.enqueue(job_dir)
        return count

    async def shutdown(self) -> None:
        for session in list(self.sessions.values()):
            session.stop.set()
        tasks = [s.task for s in self.sessions.values() if s.task]
        if tasks:
            await asyncio.wait(tasks, timeout=SHUTDOWN_WAIT_SECONDS)
        if self._worker:
            self._worker.cancel()

    # --- API ---------------------------------------------------------------------------

    def start(self, req: StartRequest) -> tuple[str, int]:
        """("already-recording", part) for a healthy session; else a new part starts.
        Raises preflight.PreflightFailed when nothing could be saved."""
        now = jobs.now_ms()
        current = self.sessions.get(req.meeting_id)
        if current and current.healthy(now, self.cfg.max_session_seconds):
            return "already-recording", current.part
        if current:
            current.stop.set()  # past the cap or stopping: it finishes as its own part
        preflight.require(self.cfg)
        part = jobs.next_part(self.cfg.tmp_dir, self.cfg.meetings_dir, req.meeting_id)
        audio_dir = self.cfg.tmp_dir / f"{req.meeting_id}-{now}"
        audio_dir.mkdir(parents=True, exist_ok=True)
        jobs.write_marker(audio_dir, jobs.JobMarker(
            meeting_id=req.meeting_id, title=req.title, starts_at=req.starts_at.isoformat(),
            recording_started_ms=now, part=part, state="recording", vocabulary=list(req.vocabulary)))
        session = Session(req=req, started_ms=now, audio_dir=audio_dir, store=ChunkStore(audio_dir), part=part,
                          key=req.key, epoch=req.epoch, room_token=req.room_token)
        self.sessions[req.meeting_id] = session
        session.task = asyncio.create_task(self._run(session))
        return "starting", part

    async def rekey(self, meeting_id: str, key: str, epoch: int, room_token: str | None = None) -> str | None:
        """None when not recording; "applied" when the page has it; "pending" while Chromium
        is (re)loading (applied as soon as the page is ready)."""
        session = self.sessions.get(meeting_id)
        if session is None or session.stop.is_set():
            return None
        session.key, session.epoch = key, epoch
        session.key_version += 1
        if room_token:
            session.room_token = room_token
            session.token_version += 1
        if session.page is None:
            return "pending"
        try:
            await self._apply(session)
        except Exception as e:  # the page went away; the next launch uses the current key
            log.warning("rekey kept for later: %s", type(e).__name__)
            return "pending"
        return "applied"

    def stop(self, meeting_id: str) -> bool:
        session = self.sessions.get(meeting_id)
        if session is None:
            return False
        session.stop.set()
        return True

    # --- recording ---------------------------------------------------------------------

    async def _run(self, session: Session) -> None:
        mid = session.req.meeting_id
        try:
            await self._record(session)
        except Exception as e:  # browser failures end the recording; keep what was captured
            log.warning("recording ended with %s", type(e).__name__)
        finally:
            if self.sessions.get(mid) is session:
                self.sessions.pop(mid, None)
        streams = load_streams(session.audio_dir)
        if not session.joined and not streams:
            shutil.rmtree(session.audio_dir, ignore_errors=True)
            await asyncio.to_thread(self._post, self.cfg, mid, "FAILED", reason=COULD_NOT_JOIN)
            return
        try:
            jobs.update_marker(session.audio_dir, state="queued", speakers={s.uid: s.name for s in streams})
        except OSError as e:
            log.error("could not update the job marker: %s", type(e).__name__)
        await asyncio.to_thread(self._post, self.cfg, mid, "PROCESSING")
        self.enqueue(session.audio_dir)

    async def _record(self, session: Session) -> None:
        deadline = time.monotonic() + self.cfg.max_session_seconds - (jobs.now_ms() - session.started_ms) / 1000
        outcome = "crashed"
        while True:
            try:
                outcome = await self._run_browser(session, deadline)
            except Exception as e:
                log.warning("Chromium failed: %s", type(e).__name__)
                outcome = "crashed"
            if outcome != "crashed" or session.stop.is_set() or time.monotonic() >= deadline:
                break
            if session.relaunches >= MAX_RELAUNCHES:
                log.warning("Chromium keeps failing; ending this part")
                break
            session.relaunches += 1
            log.info("relaunching Chromium (%s/%s) with the current key and ticket", session.relaunches, MAX_RELAUNCHES)
            await asyncio.sleep(RELAUNCH_DELAY_SECONDS)
        if outcome == "timeout":
            log.info("%s-hour cap reached; ending this part", self.cfg.max_session_seconds // 3600)

    async def _run_browser(self, session: Session, deadline: float) -> str:
        async with self._launcher() as browser:
            crashed = asyncio.Event()
            browser.on("disconnected", lambda *_: crashed.set())
            page = await (await browser.new_context()).new_page()
            await page.expose_function("scribeChunk", self._chunk_handler(session))
            await page.expose_function("scribeEvent", self._event_handler(session))
            page.on("crash", lambda *_: crashed.set())
            key_version, token_version = session.key_version, session.token_version
            await page.goto(scribe_page_url(session.current_request()), timeout=PAGE_LOAD_TIMEOUT_MS)
            await page.wait_for_function(READY_JS, timeout=PAGE_READY_TIMEOUT_MS)
            session.page_key_version, session.page_token_version = key_version, token_version
            session.page = page
            try:
                if not session.joined:
                    session.joined = True
                    await asyncio.to_thread(self._post, self.cfg, session.req.meeting_id, "RECORDING")
                await self._apply(session)  # rekeys and tickets that arrived while loading
                outcome = await self._wait(session, crashed, deadline)
            finally:
                session.page = None
            if outcome != "crashed":
                await self._leave(page)
            return outcome

    async def _apply(self, session: Session) -> None:
        page = session.page
        if page is None:
            return
        if session.page_key_version < session.key_version:
            version = session.key_version
            await page.evaluate(SET_KEY_JS, [session.key, session.epoch])
            session.page_key_version = max(session.page_key_version, version)
        if session.page_token_version < session.token_version:
            version = session.token_version
            # Without setTicket the page keeps its ticket; the next (re)launch uses the new one.
            await page.evaluate(SET_TICKET_JS, session.room_token)
            session.page_token_version = max(session.page_token_version, version)

    @staticmethod
    async def _wait(session: Session, crashed: asyncio.Event, deadline: float) -> str:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return "timeout"
        stop_task = asyncio.create_task(session.stop.wait())
        crash_task = asyncio.create_task(crashed.wait())
        done, pending = await asyncio.wait({stop_task, crash_task}, timeout=remaining,
                                           return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        if stop_task in done:
            return "stopped"
        return "crashed" if crash_task in done else "timeout"

    @staticmethod
    async def _leave(page: Any) -> None:
        """Ask the page to stop its recorders so each speaker's last chunk arrives."""
        try:
            await asyncio.wait_for(page.evaluate(LEAVE_JS), timeout=LEAVE_TIMEOUT_SECONDS)
            await asyncio.sleep(FLUSH_GRACE_SECONDS)
        except Exception as e:
            log.warning("leave did not finish: %s", type(e).__name__)

    @staticmethod
    def _chunk_handler(session: Session):
        def on_chunk(uid: Any, name: Any, start_ms: Any, seq: Any, b64: Any) -> bool:
            return session.store.append(uid, name, start_ms, seq, b64) is not None
        return on_chunk

    @staticmethod
    def _event_handler(session: Session):
        def on_event(kind: Any) -> None:
            if kind in STOP_EVENTS:
                session.stop.set()
        return on_event

    # --- processing queue --------------------------------------------------------------

    def enqueue(self, job_dir: Path) -> int:
        if job_dir.name in self._queued:
            return 0
        self._queued.add(job_dir.name)
        self.queue.put_nowait(job_dir)
        return 1

    def _active_dirs(self) -> set[str]:
        return {s.audio_dir.name for s in self.sessions.values()}

    async def _process_queue(self) -> None:
        """One job at a time. Hourly: delete recordings older than 7 days, retry failed
        jobs and READY calls that didn't get through."""
        await asyncio.to_thread(self._cleanup)
        next_maintenance = time.monotonic() + MAINTENANCE_INTERVAL_SECONDS
        while True:
            if time.monotonic() >= next_maintenance:
                await asyncio.to_thread(self._cleanup)
                self._requeue()
                next_maintenance = time.monotonic() + MAINTENANCE_INTERVAL_SECONDS
            try:
                job_dir = await asyncio.wait_for(self.queue.get(), timeout=MAINTENANCE_INTERVAL_SECONDS)
            except asyncio.TimeoutError:
                continue
            try:
                await asyncio.to_thread(self._process, self.cfg, job_dir)
            except Exception as e:
                log.warning("processing crashed: %s", type(e).__name__)
            finally:
                self._queued.discard(job_dir.name)
                self.queue.task_done()

    def _requeue(self) -> None:
        active = self._active_dirs()
        for job_dir in jobs.recoverable(self.cfg.tmp_dir, failed_retry_after_ms=FAILED_RETRY_AFTER_MS):
            marker = jobs.read_marker(job_dir)
            if job_dir.name in active or (marker and marker.state == "recording"):
                continue  # live recordings are queued when they end
            self.enqueue(job_dir)

    def _cleanup(self) -> None:
        removed = pipeline.cleanup_leftovers(self.cfg.tmp_dir, keep=self._active_dirs() | set(self._queued))
        if removed:
            log.info("removed %s recordings older than 7 days", removed)
