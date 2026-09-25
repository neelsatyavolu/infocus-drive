import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))
from personal_folders import PersonalFolders, OwnerSignInRequired
from ugos_api import UgosError


class NAS:
    state = 4
    locks = 0
    def personal_status(self, path):
        assert path == '/home/nasadmin'
        return self.state
    def lock_personal(self, path):
        self.locks += 1
        self.state = 3
    def unlock_personal(self, path, key, *, key_file=False):
        if key != 'correct':
            raise ValueError('bad key')
        self.state = 4


def test_deadline_does_not_slide_and_survives_restart(tmp_path):
    nas = NAS()
    now = [100.0]
    db = tmp_path / 'state.sqlite'
    manager = PersonalFolders(db, lambda: nas, clock=lambda: now[0])
    first = manager.status('nasadmin')
    assert first['expires_at'] == 86500
    now[0] = 200
    assert manager.status('nasadmin')['expires_at'] == 86500
    restarted = PersonalFolders(db, lambda: nas, clock=lambda: now[0])
    now[0] = 86501
    restarted.expire()
    assert nas.locks == 1
    assert restarted.status('nasadmin')['locked'] is True


def test_wrong_key_never_grants_access(tmp_path):
    nas = NAS()
    nas.state = 3
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas)
    with pytest.raises(ValueError):
        manager.unlock('nasadmin', 'wrong')
    assert manager.status('nasadmin')['locked'] is True
    assert manager.unlock('nasadmin', 'correct')['locked'] is False


def test_failed_relock_stays_expired_and_retries(tmp_path):
    nas = NAS()
    now = [0.0]
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas, clock=lambda: now[0])
    manager.status('nasadmin')
    now[0] = 86401
    def fail(path):
        raise RuntimeError('busy')
    nas.lock_personal = fail
    with pytest.raises(RuntimeError):
        manager.status('nasadmin')
    nas.lock_personal = lambda path: setattr(nas, 'state', 3)
    manager.expire()
    assert manager.status('nasadmin')['locked'] is True


def test_reject_path_injection(tmp_path):
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: NAS())
    with pytest.raises(ValueError):
        manager.status('../nasadmin')


def test_private_folder_requests_owner_signin_instead_of_generic_error(tmp_path):
    nas = NAS()
    now = [0.0]
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas, clock=lambda: now[0])
    manager.status('nasadmin')
    now[0] = 86401
    def hidden(path):
        raise UgosError('Hidden from others', code=40015)
    nas.lock_personal = hidden
    with pytest.raises(OwnerSignInRequired):
        manager.status('nasadmin')


def test_private_relock_uses_owner_session_and_preserves_deadline(tmp_path):
    nas = NAS()
    owner = NAS()
    now = [0.0]
    def owner_lock(path):
        nas.state = 3
    owner.lock_personal = owner_lock
    def denied(path):
        pytest.fail('must not use administrator to lock private folder')
    nas.lock_personal = denied
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas,
                              owner_client_factory=lambda name: owner, clock=lambda: now[0])
    manager.status('nasadmin')
    now[0] = 86401
    assert manager.status('nasadmin')['locked']


def test_owner_session_is_encrypted_and_does_not_save_password(tmp_path, monkeypatch):
    import personal_folders as pf
    manager = PersonalFolders(tmp_path / 'sessions.sqlite', lambda: NAS())
    monkeypatch.setattr(pf, 'folders', manager)
    pf.save_owner_session('nasadmin', {'token': 'private-token', 'public_key': 'key', 'password': 'must-not-save'})
    raw = manager.db_path.read_bytes()
    assert b'private-token' not in raw and b'must-not-save' not in raw
    client = pf._owner_client('nasadmin')
    assert client.username == 'nasadmin' and client.password == '' and client._token == 'private-token'
    client.close()


class BatchNAS:
    def __init__(self, states):
        self.states = dict(states)
        self.status_calls = []
        self.locks = []
    def personal_statuses(self, paths):
        self.status_calls.append(list(paths))
        return {p: self.states[p] for p in paths}
    def personal_status(self, path):
        return self.states[path]
    def lock_personal(self, path):
        self.locks.append(path)
        self.states[path] = 3


def test_statuses_uses_one_ugos_call_for_many_owners(tmp_path):
    nas = BatchNAS({'/home/nasadmin': 4, '/home/alice': 3, '/home/bob': 0})
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas, clock=lambda: 100.0)
    result = manager.statuses(['nasadmin', 'alice', 'bob'])
    assert nas.status_calls == [['/home/nasadmin', '/home/alice', '/home/bob']]
    assert result['nasadmin'] == {'encrypted': True, 'locked': False, 'expires_at': 86500, 'state': 4}
    assert result['alice'] == {'encrypted': True, 'locked': True, 'expires_at': None, 'state': 3}
    assert result['bob'] == {'encrypted': False, 'locked': False, 'expires_at': None, 'state': 0}


def test_statuses_still_relocks_expired_leases(tmp_path):
    nas = BatchNAS({'/home/nasadmin': 4, '/home/alice': 4})
    now = [0.0]
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas, clock=lambda: now[0])
    manager.statuses(['nasadmin', 'alice'])
    now[0] = 86401
    result = manager.statuses(['nasadmin', 'alice'])
    assert nas.locks == ['/home/nasadmin', '/home/alice']
    assert result['nasadmin']['locked'] and result['alice']['locked']




def test_statuses_isolates_one_owners_relock_failure(tmp_path):
    nas = BatchNAS({'/home/nasadmin': 4, '/home/alice': 4})
    now = [0.0]
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas, clock=lambda: now[0])
    manager.statuses(['nasadmin', 'alice'])
    now[0] = 86401
    def lock(path):
        if path == '/home/nasadmin':
            raise UgosError('Hidden from others', code=40015)
        nas.states[path] = 3
    nas.lock_personal = lock
    result = manager.statuses(['nasadmin', 'alice'])
    assert isinstance(result['nasadmin'], OwnerSignInRequired)
    assert result['alice']['locked'] is True


def test_statuses_asks_alone_for_paths_missing_from_batch(tmp_path):
    """If UGOS answers only part of a batch, the rest must not all read as locked."""
    nas = BatchNAS({'/home/nasadmin': 4, '/home/alice': 0})
    full = nas.personal_statuses
    nas.personal_statuses = lambda paths: {p: v for p, v in full(paths).items() if p == paths[0]}
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas, clock=lambda: 100.0)
    result = manager.statuses(['nasadmin', 'alice'])
    assert result['nasadmin']['locked'] is False
    assert result['alice'] == {'encrypted': False, 'locked': False, 'expires_at': None, 'state': 0}


def test_statuses_isolates_invalid_owner(tmp_path):
    nas = BatchNAS({'/home/nasadmin': 0})
    manager = PersonalFolders(tmp_path / 'state.sqlite', lambda: nas)
    result = manager.statuses(['nasadmin', '../etc'])
    assert isinstance(result['../etc'], ValueError)
    assert result['nasadmin']['locked'] is False
    assert nas.status_calls == [['/home/nasadmin']]
