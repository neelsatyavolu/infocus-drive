"""Ticket issuance checks without entering the host namespace or using real credentials."""

import io
import json
import subprocess
import sys
import traceback
from pathlib import Path

import httpx
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "app"))
import userd
from user_sync import UserdClient, UserdError


TICKET = "idsso_" + "A" * 43
ROW = "nasadmin:x:1029:10:UGREEN USER:/home/nasadmin:/bin/bash\n"


def request(payload, authorization="Bearer test-token"):
    handler = object.__new__(userd.Handler)
    raw = json.dumps(payload).encode()
    handler.path = "/ugos-sso/ticket"
    handler.headers = {"Authorization": authorization, "Content-Length": str(len(raw))}
    handler.rfile = io.BytesIO(raw)
    responses = []
    handler._json = lambda code, body: responses.append((code, body))
    handler.do_POST()
    return responses[0]


@pytest.fixture(autouse=True)
def bearer(monkeypatch):
    monkeypatch.setenv("USERD_TOKEN", "test-token")


def install_host(monkeypatch, row=ROW, helper=None):
    calls = []

    def run(args, **kwargs):
        calls.append((args, kwargs))
        assert args[:7] == ["nsenter", "-t", "1", "-m", "-u", "-i", "--"]
        assert args[7] in ("/usr/bin/getent", "/usr/bin/python3")
        assert 0 < kwargs["timeout"] <= 5
        assert kwargs["capture_output"] and kwargs["text"]
        if args[7] == "/usr/bin/getent":
            assert args[8:11] == ["-s", "files", "passwd"]
            return subprocess.CompletedProcess(args, 0, row, "")
        assert args[7:] == ["/usr/bin/python3", "-I", "/usr/local/libexec/infocus-ugos-sso-pam", "--issue", "nasadmin"]
        if isinstance(helper, Exception):
            raise helper
        return helper or subprocess.CompletedProcess(args, 0, TICKET + "\n", "")

    monkeypatch.setattr(userd.subprocess, "run", run)
    return calls


@pytest.mark.parametrize("authorization", ["", "Bearer wrong", "Basic test-token"])
def test_unauthorized_never_runs_host(monkeypatch, authorization):
    calls = install_host(monkeypatch)
    assert request({"username": "nasadmin", "uid": 1029}, authorization)[0] == 401
    assert not calls


def test_issue_checks_local_uid_before_helper(monkeypatch, capsys):
    calls = install_host(monkeypatch)
    assert request({"username": "nasadmin", "uid": 1029}) == (
        200, {"status": "ok", "credential": TICKET, "uid": 1029}
    )
    assert len(calls) == 2
    assert TICKET not in str(capsys.readouterr())


@pytest.mark.parametrize("payload", [
    {}, {"username": "nasadmin"}, {"username": " nasadmin", "uid": 1029},
    {"username": "nasadmin\n", "uid": 1029}, {"username": "-root", "uid": 1029},
    {"username": "../nasadmin", "uid": 1029}, {"username": ["nasadmin"], "uid": 1029},
    {"username": "nasadmin", "uid": "1029"}, {"username": "nasadmin", "uid": True},
    {"username": "root", "uid": 0}, {"username": "nasadmin", "uid": 60000},
    {"username": "infocus-drive-svc", "uid": 1200},
])
def test_invalid_request_never_runs_host(monkeypatch, payload):
    calls = install_host(monkeypatch)
    code, body = request(payload)
    assert code == 400
    assert "credential" not in body
    assert not calls


@pytest.mark.parametrize("row", [
    "", ROW.replace(":1029:", ":1030:"), ROW.replace("nasadmin:", "other:"),
    ROW.replace("/bin/bash", "/usr/sbin/nologin"), ROW.replace("/bin/bash", "/bin/false"),
    "nasadmin:x:not-a-uid:10::/:/bin/bash\n", ROW + ROW,
])
def test_account_mismatch_or_service_never_issues(monkeypatch, row):
    calls = install_host(monkeypatch, row=row)
    assert request({"username": "nasadmin", "uid": 1029})[0] >= 400
    assert len(calls) == 1


@pytest.mark.parametrize("helper", [
    subprocess.CompletedProcess([], 1, TICKET, "private-error"),
    subprocess.CompletedProcess([], 0, "", ""),
    subprocess.CompletedProcess([], 0, TICKET + "\nprivate-error", ""),
    subprocess.TimeoutExpired("helper", 5, output=TICKET, stderr="private-error"),
    OSError("private-error"),
])
def test_helper_failures_are_generic(monkeypatch, helper, capsys):
    install_host(monkeypatch, helper=helper)
    code, body = request({"username": "nasadmin", "uid": 1029})
    assert code >= 400
    assert body == {"status": "error", "detail": "UGOS ticket unavailable"}
    assert TICKET not in str(capsys.readouterr())


@pytest.mark.parametrize("failure", [
    subprocess.CompletedProcess([], 1, TICKET, "private-error"),
    subprocess.TimeoutExpired("getent", 5, output=TICKET),
    OSError("private-error"),
])
def test_lookup_failure_never_issues_or_leaks(monkeypatch, failure):
    calls = []

    def run(args, **kwargs):
        calls.append(args)
        if isinstance(failure, Exception):
            raise failure
        return failure

    monkeypatch.setattr(userd.subprocess, "run", run)
    code, body = request({"username": "nasadmin", "uid": 1029})
    assert code in (400, 503)
    assert body == {"status": "error", "detail": "UGOS ticket unavailable"}
    assert len(calls) == 1
    assert calls[0][7] == "/usr/bin/getent"


@pytest.mark.parametrize("payload", [None, [], "private-error", 1029])
def test_non_object_requests_are_generic(monkeypatch, payload):
    calls = install_host(monkeypatch)
    assert request(payload) == (400, {"status": "error", "detail": "UGOS ticket unavailable"})
    assert not calls


def test_missing_configured_token_denies_issuance(monkeypatch):
    monkeypatch.delenv("USERD_TOKEN", raising=False)
    calls = install_host(monkeypatch)
    assert request({"username": "nasadmin", "uid": 1029})[0] == 401
    assert not calls


def client_with(transport):
    client = UserdClient("http://userd", "test-token")
    client._http.close()
    client._http = httpx.Client(transport=httpx.MockTransport(transport))
    return client


def test_client_sends_expected_uid_and_bearer():
    def transport(req):
        assert req.url.path == "/ugos-sso/ticket"
        assert req.headers["Authorization"] == "Bearer test-token"
        assert json.loads(req.content) == {"username": "nasadmin", "uid": 1029}
        return httpx.Response(200, json={"status": "ok", "uid": 1029, "credential": TICKET})

    client = client_with(transport)
    try:
        assert client.issue_ugos_ticket("nasadmin", 1029) == {"status": "ok", "uid": 1029, "credential": TICKET}
    finally:
        client.close()


@pytest.mark.parametrize("response", [
    httpx.Response(500, text=TICKET), httpx.Response(200, text=TICKET),
    httpx.Response(200, json=[TICKET]),
    httpx.Response(200, json={"status": "error", "detail": TICKET}),
    httpx.Response(200, json={"status": "ok", "uid": 1030, "credential": TICKET}),
    httpx.Response(200, json={"status": "ok", "uid": 1029, "credential": ""}),
    httpx.ConnectError(TICKET),
])
def test_client_errors_do_not_disclose_response_or_exception(response):
    def transport(req):
        if isinstance(response, Exception):
            raise response
        return response

    client = client_with(transport)
    try:
        with pytest.raises(UserdError, match="^UGOS ticket unavailable$") as caught:
            client.issue_ugos_ticket("nasadmin", 1029)
        assert TICKET not in "".join(traceback.format_exception(caught.value))
    finally:
        client.close()
