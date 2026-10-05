"""Live sessions with a fake Chromium: pending rekeys, re-ticketing, graceful leave, crash
relaunch, start-again parts, preflight and restart recovery."""

import asyncio
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from urllib.parse import unquote

import pytest
from fastapi.testclient import TestClient

from scribe_fakes import KEY, MEETING, TOKEN, make_cfg

from app import jobs, preflight, session  # noqa: E402
from app import main as scribe_main  # noqa: E402

NEW_KEY = "C" * 43


class FakePage:
    def __init__(self, browser, gate=None):
        self.browser = browser
        self.gate = gate
        self.exposed = {}
        self.handlers = {}
        self.url = None
        self.evaluated = []

    async def expose_function(self, name, fn):
        self.exposed[name] = fn

    def on(self, event, fn):
        self.handlers[event] = fn

    async def goto(self, url, timeout=None):
        self.url = unquote(url)
        if self.browser.fail_goto:
            raise RuntimeError("net::ERR_NAME_NOT_RESOLVED")
        if self.gate is not None:
            await self.gate.wait()

    async def wait_for_function(self, script, timeout=None):
        return True

    async def evaluate(self, script, arg=None):
        self.evaluated.append((script, arg, self.browser.closed))
        return True

    def crash(self):
        self.handlers["crash"](self)


class FakeBrowser:
    def __init__(self, gate=None, fail_goto=False):
        self.gate = gate
        self.fail_goto = fail_goto
        self.closed = False
        self.handlers = {}
        self.page = None

    def on(self, event, fn):
        self.handlers[event] = fn

    async def new_context(self):
        return self

    async def new_page(self):
        self.page = FakePage(self, self.gate)
        return self.page


class Launcher:
    def __init__(self, **kw):
        self.kw = kw
        self.browsers = []

    @asynccontextmanager
    async def __call__(self):
        browser = FakeBrowser(**self.kw)
        self.browsers.append(browser)
        try:
            yield browser
        finally:
            browser.closed = True


def _req(key=KEY, token="ticket.one"):
    return session.StartRequest(meeting_id=MEETING, title="Producer meeting",
                                starts_at=datetime(2026, 10, 5, 4, 15, tzinfo=timezone.utc),
                                room_url="https://rooms.example.com", room_token=token, key=key, epoch=0,
                                portal_base_url="https://portal.example.com")


@pytest.fixture
def harness(tmp_path, monkeypatch):
    monkeypatch.setattr(session, "RELAUNCH_DELAY_SECONDS", 0)
    monkeypatch.setattr(session, "FLUSH_GRACE_SECONDS", 0)
    cfg = make_cfg(tmp_path)
    cfg.meetings_dir.mkdir()
    cfg.tmp_dir.mkdir()
    posted = []

    def post(cfg_, mid, status, **kw):
        posted.append((status, kw))
        return True

    def build(**launcher_kw):
        launcher = Launcher(**launcher_kw)
        manager = session.SessionManager(cfg, launcher=launcher, process=lambda c, d: "done", post=post)
        return manager, launcher

    return cfg, posted, build


async def _until(check, timeout=3.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not check():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError("condition not reached")
        await asyncio.sleep(0.01)


def test_a_rekey_while_chromium_loads_is_kept_and_applied_when_ready(harness):
    cfg, posted, build = harness

    async def scenario():
        gate = asyncio.Event()
        manager, launcher = build(gate=gate)
        assert manager.start(_req()) == ("starting", 1)
        await _until(lambda: launcher.browsers and launcher.browsers[0].page and launcher.browsers[0].page.url)
        assert await manager.rekey(MEETING, NEW_KEY, 1, "ticket.two") == "pending"  # used to be a 404
        gate.set()
        page = launcher.browsers[0].page
        await _until(lambda: len(page.evaluated) >= 2)
        assert f"key={KEY}" in page.url  # the page loaded with the old key …
        assert page.evaluated[0][:2] == (session.SET_KEY_JS, [NEW_KEY, 1])  # … and got the new one when ready
        assert page.evaluated[1][:2] == (session.SET_TICKET_JS, "ticket.two")
        assert await manager.rekey(MEETING, KEY, 2) == "applied"
        assert page.evaluated[-1][:2] == (session.SET_KEY_JS, [KEY, 2])
        manager.stop(MEETING)
        await _until(lambda: MEETING not in manager.sessions)

    asyncio.run(scenario())
    assert [s for s, _ in posted] == ["RECORDING", "PROCESSING"]


def test_stop_asks_the_page_to_leave_before_closing_and_queues_the_job(harness):
    cfg, posted, build = harness

    async def scenario():
        manager, launcher = build()
        manager.start(_req())
        await _until(lambda: launcher.browsers and launcher.browsers[0].page and launcher.browsers[0].page.exposed)
        page = launcher.browsers[0].page
        await _until(lambda: manager.sessions[MEETING].page is not None)
        page.exposed["scribeChunk"]("u1", "Abby", 1_000, 0, "aGVhZGVy")
        page.exposed["scribeEvent"]("ended")  # the room ended the meeting
        await _until(lambda: not manager.queue.empty())
        leave = [e for e in page.evaluated if e[0] == session.LEAVE_JS]
        assert leave and leave[0][2] is False  # left while the browser was still open
        job_dir = manager.queue.get_nowait()
        marker = jobs.read_marker(job_dir)
        assert marker.state == "queued" and marker.speakers == {"u1": "Abby"}

    asyncio.run(scenario())


def test_a_crashed_chromium_is_relaunched_with_the_current_key_and_ticket(harness):
    cfg, posted, build = harness

    async def scenario():
        manager, launcher = build()
        manager.start(_req())
        await _until(lambda: MEETING in manager.sessions and manager.sessions[MEETING].page is not None)
        first = launcher.browsers[0].page
        await manager.rekey(MEETING, NEW_KEY, 3, "ticket.two")
        first.crash()
        await _until(lambda: len(launcher.browsers) == 2 and manager.sessions[MEETING].page is not None)
        second = launcher.browsers[1].page
        assert f"key={NEW_KEY}" in second.url and "epoch=3" in second.url and "token=ticket.two" in second.url
        s = manager.sessions[MEETING]
        assert s.relaunches == 1 and s.part == 1
        manager.stop(MEETING)
        await _until(lambda: MEETING not in manager.sessions)

    asyncio.run(scenario())
    assert [s for s, _ in posted].count("RECORDING") == 1


def test_start_again_for_the_same_meeting_is_a_new_part_once_the_old_one_ends(harness):
    cfg, posted, build = harness

    async def scenario():
        manager, launcher = build()
        assert manager.start(_req()) == ("starting", 1)
        await _until(lambda: MEETING in manager.sessions and manager.sessions[MEETING].page is not None)
        assert manager.start(_req()) == ("already-recording", 1)
        manager.sessions[MEETING].started_ms -= (cfg.max_session_seconds + 1) * 1000  # past the 4-hour cap
        assert manager.start(_req()) == ("starting", 2)
        await _until(lambda: len(launcher.browsers) == 2)
        manager.stop(MEETING)
        await _until(lambda: MEETING not in manager.sessions)
        await _until(lambda: manager.queue.qsize() == 2)

    asyncio.run(scenario())
    parts = sorted(m.part for _, m in jobs.job_dirs(cfg.tmp_dir))
    assert parts == [1, 2]


def test_a_meeting_that_can_never_be_joined_fails_with_a_reason(harness):
    cfg, posted, build = harness

    async def scenario():
        manager, launcher = build(fail_goto=True)
        manager.start(_req())
        await _until(lambda: MEETING not in manager.sessions)
        assert len(launcher.browsers) == 1 + session.MAX_RELAUNCHES

    asyncio.run(scenario())
    assert posted == [("FAILED", {"reason": session.COULD_NOT_JOIN})]
    assert list(cfg.tmp_dir.iterdir()) == []


def test_preflight_refuses_to_record_when_nothing_can_be_saved(harness):
    cfg, posted, build = harness
    cfg.meetings_dir.rmdir()

    async def scenario():
        manager, _ = build()
        with pytest.raises(preflight.PreflightFailed):
            manager.start(_req())

    asyncio.run(scenario())
    assert list(cfg.tmp_dir.iterdir()) == []


def test_restart_requeues_interrupted_and_failed_jobs(harness):
    cfg, posted, build = harness
    for name, state in [("a-1", "recording"), ("b-2", "failed"), ("c-3", "written"), ("d-4", "partial")]:
        job_dir = cfg.tmp_dir / name
        job_dir.mkdir()
        jobs.write_marker(job_dir, jobs.JobMarker(MEETING, "T", "2026-10-05T04:15:00+00:00", 1, state=state))

    async def scenario():
        manager, _ = build()
        assert manager.recover() == 3
        assert manager.recover() == 0  # no duplicates
        return sorted(manager.queue.get_nowait().name for _ in range(3))

    assert asyncio.run(scenario()) == ["a-1", "b-2", "c-3"]
    assert jobs.read_marker(cfg.tmp_dir / "a-1").state == "queued"


# --- API ----------------------------------------------------------------------------

START = {"meetingId": MEETING, "title": "T", "startsAt": "2026-10-04T04:15:00Z",
         "roomUrl": "https://rooms.example.com", "roomToken": "a.b.c", "key": KEY, "epoch": 0,
         "portalBaseUrl": "https://portal.example.com"}
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class RecordingManager:
    def __init__(self, fail=False):
        self.fail = fail
        self.rekeys = []

    def start(self, req):
        if self.fail:
            raise preflight.PreflightFailed(["notes folder /meetings is missing or not writable"])
        return "starting", 2

    async def rekey(self, meeting_id, key, epoch, room_token=None):
        self.rekeys.append((meeting_id, epoch, room_token))
        return "pending"


@pytest.fixture
def api(tmp_path, monkeypatch):
    cfg = make_cfg(tmp_path)
    monkeypatch.setattr(scribe_main, "get_config", lambda: cfg)
    posted = []
    monkeypatch.setattr(scribe_main.portal_client, "post_notes", lambda c, mid, status, **kw: posted.append((status, kw)))
    return cfg, posted


def test_start_reports_the_part_and_rekey_passes_the_new_ticket(api):
    scribe_main.app.state.manager = manager = RecordingManager()
    client = TestClient(scribe_main.app)
    assert client.post("/sessions/start", json=START, headers=AUTH).json() == {"ok": True, "state": "starting", "part": 2}
    res = client.post("/sessions/rekey", json={"meetingId": MEETING, "key": KEY, "epoch": 4, "roomToken": "t.u.v"},
                      headers=AUTH)
    assert res.json() == {"ok": True, "state": "pending"}
    assert manager.rekeys == [(MEETING, 4, "t.u.v")]
    bad = client.post("/sessions/rekey", json={"meetingId": MEETING, "key": KEY, "epoch": 4, "roomToken": "has space"},
                      headers=AUTH)
    assert bad.status_code == 422


def test_start_when_nothing_can_be_saved_is_503_and_reports_failed(api):
    cfg, posted = api
    scribe_main.app.state.manager = RecordingManager(fail=True)
    res = TestClient(scribe_main.app).post("/sessions/start", json=START, headers=AUTH)
    assert res.status_code == 503 and res.json()["detail"] == preflight.NOT_WRITABLE
    assert posted == [("FAILED", {"reason": preflight.NOT_WRITABLE})]


def test_health_is_unhealthy_until_the_folders_are_writable(api):
    cfg, _ = api
    client = TestClient(scribe_main.app)
    res = client.get("/health")
    assert res.status_code == 503 and res.json()["ok"] is False
    cfg.meetings_dir.mkdir()
    cfg.tmp_dir.mkdir()
    assert client.get("/health").json() == {"ok": True}
