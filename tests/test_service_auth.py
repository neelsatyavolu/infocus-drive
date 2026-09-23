import sys
from pathlib import Path

import pytest
from fastapi import HTTPException

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from service_auth import assert_under_packages_root  # noqa: E402


def test_package_cycles_still_allowed():
    assert (
        assert_under_packages_root("Package Cycles/Cycle 1/Final Cut/clip.mp4")
        == "Package Cycles/Cycle 1/Final Cut/clip.mp4"
    )


def test_package_storage_allowed():
    assert (
        assert_under_packages_root("Package Storage/Cycle 1/Lee-Patel/A-roll B-roll/clip.mp4")
        == "Package Storage/Cycle 1/Lee-Patel/A-roll B-roll/clip.mp4"
    )


def test_empty_path_defaults_to_package_cycles():
    assert assert_under_packages_root("") == "Package Cycles"


def test_other_share_path_rejected():
    with pytest.raises(HTTPException) as exc:
        assert_under_packages_root("Other Share/secret.mp4")
    assert exc.value.status_code == 403
    assert "Package Cycles/" in str(exc.value.detail)
    assert "Package Storage/" in str(exc.value.detail)


def test_parent_traversal_rejected():
    with pytest.raises(HTTPException) as exc:
        assert_under_packages_root("Package Cycles/../etc/passwd")
    assert exc.value.status_code == 400


def test_session_rel_path_joins_folder_and_name():
    from chunk_upload import session_rel_path

    assert session_rel_path({"path": "Package Storage/Cycle 1/Lee", "name": "clip.mp4"}) == (
        "Package Storage/Cycle 1/Lee/clip.mp4"
    )
    assert session_rel_path({"path": "", "name": "clip.mp4"}) == "clip.mp4"
