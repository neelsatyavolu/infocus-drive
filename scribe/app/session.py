"""Live Scribe sessions: headless Chromium in the meeting as a silent listener.

The meeting key and room token travel only in the URL fragment of the scribe
page (never sent to a server) and are never logged.
"""

from __future__ import annotations

import asyncio
import logging
import shutil
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlencode

from . import pipeline, portal_client
from .config import ScribeConfig
from .recorder import ChunkStore

log = logging.getLogger("scribe.session")

CHROMIUM_ARGS = ["--autoplay-policy=no-user-gesture-required", "--disable-dev-shm-usage", "--mute-audio"]
STOP_EVENTS = ("ended", "removed")
PAGE_LOAD_TIMEOUT_MS = 60_000
CLEANUP_INTERVAL_SECONDS = 60 * 60


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
    stop: asyncio.Event = field(default_factory=asyncio.Event)
    page: Any = None
    joined: bool = False
    task: asyncio.Task | None = None


class SessionManager:
    def __init__(self, cfg: ScribeConfig) -> None:
        self.cfg = cfg
        self.sessions: dict[str, Session] = {}
        self.queue: asyncio.Queue[pipeline.Job] = asyncio.Queue()
        self._worker: asyncio.Task | None = None

    def start_worker(self) -> None:
        self._worker = asyncio.create_task(self._process_queue())

    async def shutdown(self) -> None:
        for session in list(self.sessions.values()):
            session.stop.set()
        tasks = [s.task for s in self.sessions.values() if s.task]
        if tasks:
            await asyncio.wait(tasks, timeout=30)
        if self._worker:
            self._worker.cancel()

    def start(self, req: StartRequest) -> str:
        if req.meeting_id in self.sessions:
            return "already-recording"
        started_ms = int(time.time() * 1000)
        audio_dir = self.cfg.tmp_dir / f"{req.meeting_id}-{started_ms}"
        session = Session(req=req, started_ms=started_ms, audio_dir=audio_dir, store=ChunkStore(audio_dir))
        self.sessions[req.meeting_id] = session
        session.task = asyncio.create_task(self._run(session))
        return "starting"

    async def rekey(self, meeting_id: str, key: str, epoch: int) -> bool:
        session = self.sessions.get(meeting_id)
        if session is None or session.page is None:
            return False
        await session.page.evaluate("([k, e]) => window.__scribe && window.__scribe.setKey(k, e)", [key, epoch])
        return True

    def stop(self, meeting_id: str) -> bool:
        session = self.sessions.get(meeting_id)
        if session is None:
            return False
        session.stop.set()
        return True

    async def _run(self, session: Session) -> None:
        mid = session.req.meeting_id
        try:
            await self._record(session)
        except Exception as e:  # browser failures end the recording; keep what was captured
            log.warning("recording ended with %s", type(e).__name__)
        finally:
            self.sessions.pop(mid, None)
        if not session.joined:  # Chromium never reached the meeting: nothing to process
            shutil.rmtree(session.audio_dir, ignore_errors=True)
            await asyncio.to_thread(portal_client.post_notes, self.cfg, mid, "FAILED")
            return
        await asyncio.to_thread(portal_client.post_notes, self.cfg, mid, "PROCESSING")
        await self.queue.put(pipeline.Job(meeting_id=mid, title=session.req.title, starts_at=session.req.starts_at,
                                          recording_started_ms=session.started_ms, audio_dir=session.audio_dir))

    async def _record(self, session: Session) -> None:
        from playwright.async_api import async_playwright  # only in the container

        async with async_playwright() as pw:
            # Runs as a non-root user with Chromium's own sandbox on (docs/MEETINGS-SCRIBE.md).
            browser = await pw.chromium.launch(headless=True, chromium_sandbox=True, args=CHROMIUM_ARGS)
            try:
                page = await (await browser.new_context()).new_page()
                await page.expose_function("scribeChunk", self._chunk_handler(session))
                await page.expose_function("scribeEvent", self._event_handler(session))
                page.on("close", lambda _page: session.stop.set())
                page.on("crash", lambda _page: session.stop.set())
                await page.goto(scribe_page_url(session.req), timeout=PAGE_LOAD_TIMEOUT_MS)
                session.page = page
                session.joined = True
                await asyncio.to_thread(portal_client.post_notes, self.cfg, session.req.meeting_id, "RECORDING")
                try:
                    await asyncio.wait_for(session.stop.wait(), timeout=self.cfg.max_session_seconds)
                except asyncio.TimeoutError:
                    log.info("4-hour cap reached; ending the recording")
            finally:
                session.page = None
                await browser.close()

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

    async def _process_queue(self) -> None:
        """One job at a time; hourly, delete raw audio older than 7 days."""
        next_cleanup = 0.0
        while True:
            if time.monotonic() >= next_cleanup:
                await asyncio.to_thread(self._cleanup)
                next_cleanup = time.monotonic() + CLEANUP_INTERVAL_SECONDS
            try:
                job = await asyncio.wait_for(self.queue.get(), timeout=CLEANUP_INTERVAL_SECONDS)
            except asyncio.TimeoutError:
                continue
            try:
                await asyncio.to_thread(pipeline.process, self.cfg, job)
            except Exception as e:
                log.warning("processing crashed: %s", type(e).__name__)
            finally:
                self.queue.task_done()

    def _cleanup(self) -> None:
        active = {s.audio_dir.name for s in self.sessions.values()}
        removed = pipeline.cleanup_leftovers(self.cfg.tmp_dir, keep=active)
        if removed:
            log.info("removed %s raw recordings older than 7 days", removed)
