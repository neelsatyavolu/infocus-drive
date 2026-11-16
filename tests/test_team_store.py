import sys
import threading
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
from team_store import HEARTBEAT_S, LOCK_TTL_S, TeamStore  # noqa: E402


class Clock:
    def __init__(self, now: float = 1_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def store(tmp_path, clock):
    return TeamStore(tmp_path / "team.sqlite3", clock=clock)


@pytest.fixture
def pid(store):
    return store.create_project("Team Projects/Robotics.fcteam", "Robotics", "student1")


def test_constants():
    assert HEARTBEAT_S == 20 and LOCK_TTL_S == 120


def test_create_project_returns_hex_id(store, pid):
    assert len(pid) == 32 and int(pid, 16) >= 0
    info = store.project(pid)
    assert info["name"] == "Robotics" and info["folder"] == "Team Projects/Robotics.fcteam"
    assert info["creator"] == "student1"


def test_take_lock_free(store, pid, clock):
    got = store.take_lock(pid, 7, "student1")
    assert got.ok and got.token and got.holder == "student1"
    assert got.expires_at == clock.now + LOCK_TTL_S
    assert store.locks(pid) == {7: ("student1", clock.now + LOCK_TTL_S)}


def test_second_taker_refused_with_holder(store, pid):
    store.take_lock(pid, 7, "student1")
    got = store.take_lock(pid, 7, "student2")
    assert not got.ok and got.token is None and got.holder == "student1"


def test_lock_expires_after_ttl(store, pid, clock):
    first = store.take_lock(pid, 7, "student1")
    clock.now += LOCK_TTL_S + 1
    assert store.locks(pid) == {}
    got = store.take_lock(pid, 7, "student2")
    assert got.ok and got.holder == "student2"
    assert not store.check_lock(pid, 7, first.token)
    assert not store.heartbeat(pid, 7, first.token)


def test_heartbeat_extends(store, pid, clock):
    got = store.take_lock(pid, 7, "student1")
    clock.now += 100
    assert store.heartbeat(pid, 7, got.token)
    clock.now += 100
    assert store.check_lock(pid, 7, got.token)
    assert not store.take_lock(pid, 7, "student2").ok


def test_expired_lock_cannot_be_revived(store, pid, clock):
    got = store.take_lock(pid, 7, "student1")
    clock.now += LOCK_TTL_S + 1
    assert not store.heartbeat(pid, 7, got.token)
    assert not store.check_lock(pid, 7, got.token)


def test_release_requires_token(store, pid):
    got = store.take_lock(pid, 7, "student1")
    assert not store.release(pid, 7, "wrong")
    assert store.locks(pid)
    assert store.release(pid, 7, got.token)
    assert store.locks(pid) == {}


def test_force_release(store, pid):
    store.take_lock(pid, 7, "student1")
    store.force_release(pid, 7)
    assert store.take_lock(pid, 7, "student2").ok


def test_concurrent_take_exactly_one_wins(store, pid):
    results = []
    barrier = threading.Barrier(20)

    def take(n):
        barrier.wait()
        results.append(store.take_lock(pid, 9, f"student{n}"))

    threads = [threading.Thread(target=take, args=(n,)) for n in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sum(r.ok for r in results) == 1
    winner = next(r for r in results if r.ok)
    assert all(r.holder == winner.holder for r in results)


def test_stale_base_revision_rejected(store, pid):
    assert store.revision(pid, "seq:7") == 0
    assert store.bump_revision(pid, "seq:7", 0) == 1
    assert store.bump_revision(pid, "seq:7", 0) is None
    assert store.bump_revision(pid, "seq:7", 1) == 2
    assert store.revision(pid, "seq:7") == 2
    assert store.revision(pid, "shared") == 0


def test_bump_without_base_always_succeeds(store, pid):
    assert store.bump_revision(pid, "shared", None) == 1
    assert store.bump_revision(pid, "shared", None) == 2


def test_slot_stable_and_unique(store, pid):
    a = store.slot_for(pid, "student1")
    b = store.slot_for(pid, "student2")
    assert 1 <= a <= 1023 and 1 <= b <= 1023 and a != b
    assert store.slot_for(pid, "student1") == a
    other = store.create_project("Team Projects/Other.fcteam", "Other", "student2")
    assert store.slot_for(other, "student2") == 1


def test_slots_capped_at_1023(store, pid):
    for n in range(1023):
        store.slot_for(pid, f"user{n}")
    with pytest.raises(ValueError):
        store.slot_for(pid, "one-too-many")


def test_record_open_and_members(store, pid, clock):
    clock.now += 50
    store.record_open(pid, "student2")
    assert store.last_open(pid) == clock.now
    assert set(store.members(pid)) == {"student1", "student2"}


def test_record_open_clears_notified(store, pid):
    store.mark_notified(pid)
    assert store.notified(pid)
    store.record_open(pid, "student1")
    assert not store.notified(pid)


def test_stale_projects_skips_keep(store, pid, clock):
    other = store.create_project("Team Projects/Other.fcteam", "Other", "student2")
    clock.now += 10 * 86400
    assert set(store.stale_projects(5 * 86400)) == {pid, other}
    store.set_keep(other, True)
    assert store.is_keep(other)
    assert store.stale_projects(5 * 86400) == [pid]
    store.record_open(pid, "student1")
    assert store.stale_projects(5 * 86400) == []


def test_set_folder_and_forget(store, pid):
    store.set_folder(pid, "Team Projects/Renamed.fcteam")
    assert store.project(pid)["folder"] == "Team Projects/Renamed.fcteam"
    store.take_lock(pid, 1, "student1")
    store.forget(pid)
    assert store.project(pid) is None
    assert store.locks(pid) == {}


def test_unknown_project(store):
    assert store.project("0" * 32) is None
    assert not store.take_lock("0" * 32, 1, "student1").ok
