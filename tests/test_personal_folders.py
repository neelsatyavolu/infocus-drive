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
