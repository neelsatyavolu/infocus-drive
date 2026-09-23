"""Google-authenticated Drive -> UGOS, with browser-bound one-use handoffs."""
from __future__ import annotations

import hashlib
import hmac
import html
import json
from pathlib import Path
import re
import secrets
import threading
import time
from urllib.parse import urlencode, urlsplit

from fastapi import APIRouter, Form, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse

from config import get_settings
from ugos_api import nas_otp_login, nas_password_login, nas_send_otp_email
from user_sync import UserdClient, UserdError
from users import resolve_nas_user

router = APIRouter()
COOKIE = "__Host-infocus_ugos_handoff"
NO_STORE = {"Cache-Control": "private, no-store", "CDN-Cache-Control": "no-store", "Referrer-Policy": "no-referrer"}
_lock = threading.Lock()
_flows: dict[str, dict] = {}
_hits: dict[int, list[float]] = {}


def _fail(status, message):
    raise HTTPException(status, message, headers=NO_STORE)


def _digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def _origins():
    s = get_settings()
    if not s.ugos_sso_enabled:
        _fail(404, "Google sign-in for UGOS is not enabled.")
    drive = s.public_base_url.rstrip("/")
    url = urlsplit(s.ugos_admin_path)
    ugos = f"{url.scheme}://{url.netloc}"
    if not drive.startswith("https://") or url.scheme != "https" or not url.netloc or ugos == drive:
        _fail(503, "UGOS sign-in is not configured.")
    return drive, ugos


def _host(request, expected):
    if f"{request.url.scheme}://{request.url.netloc}" != expected:
        _fail(403, "Open sign-in on the correct website.")


def _flow(state):
    # Call only while holding _lock. Expired sessions are never delivered.
    now = time.time()
    for key in list(_flows):
        if _flows[key]["expires"] <= now:
            del _flows[key]
    value = _flows.get(state)
    if value is None:
        _fail(400, "Sign-in expired. Open the control panel again.")
    return value


def _identity(request):
    user = request.session.get("user") or {}
    if user.get("auth_provider") != "google" or not user.get("google_sub"):
        return None
    nas = resolve_nas_user(str(user.get("email") or ""))
    if nas is None or (nas.username, nas.uid) != (user.get("username"), user.get("uid")):
        _fail(403, "Your NAS account mapping changed. Sign in to Drive again.")
    return user


def issue_ticket(username, uid):
    s = get_settings()
    client = UserdClient(s.userd_url, s.userd_token, timeout=10)
    try:
        return client.issue_ugos_ticket(username, uid)["credential"]
    except (UserdError, KeyError):
        _fail(503, "Google sign-in for UGOS is temporarily unavailable.")
    finally:
        client.close()


def _page(content, *, script="", login_data=None):
    nonce = secrets.token_urlsafe(24)
    scripts = f'<script nonce="{nonce}">{script}</script>' if script else ""
    if login_data is not None:
        data = json.dumps(login_data).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
        scripts = f'<script type="application/json" id="ugos-login-data">{data}</script><script type="module" nonce="{nonce}" src="/infocus-sso/bootstrap.js"></script>'
    # HTML forms need their real Origin for CSRF checks. no-referrer turns it
    # into null on navigation POSTs; strict-origin exposes no path or state.
    headers = {**NO_STORE, "Referrer-Policy": "strict-origin", "X-Frame-Options": "DENY", "Content-Security-Policy": f"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'unsafe-inline'; form-action {_origins()[0]} {_origins()[1]}; base-uri 'none'; frame-ancestors 'none'"}
    return HTMLResponse(f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>UGOS · InFocus</title>
<style>body{{margin:0;background:#f4f5f7;color:#20252b;font:16px system-ui,sans-serif;display:grid;min-height:100vh;place-items:center}}main{{width:min(380px,calc(100vw - 80px));padding:32px;background:white;border:1px solid #dfe2e7;border-radius:16px}}h1{{font-size:25px;letter-spacing:-.6px}}p{{line-height:1.5;color:#59616d}}button,.button{{display:block;box-sizing:border-box;width:100%;background:#20252b;color:white;border:0;border-radius:8px;padding:13px;text-align:center;text-decoration:none;font:inherit;cursor:pointer}}a{{color:#354d75}}input,select{{box-sizing:border-box;width:100%;padding:12px;font:inherit;border:1px solid #b7bdc6;border-radius:7px;margin:8px 0 16px}}label{{display:block}}small{{color:#68717c}}</style>
<main><small>InFocus</small><h1>UGOS Control Panel</h1>{content}</main>{scripts}</html>''', headers=headers)


@router.get("/infocus-sso/")
def landing(request: Request):
    _host(request, _origins()[1])
    return _page('<p>Use your school Google account to open your NAS account.</p><a class="button" href="/infocus-sso/start">Continue with Google</a><p><a href="/desktop/?os=ugospro">Use NAS username and password</a></p>')


@router.get("/infocus-sso/bootstrap.js")
def bootstrap_script(request: Request):
    _host(request, _origins()[1])
    return FileResponse(Path(__file__).parent / "static/ugos-bootstrap.js", media_type="text/javascript", headers=NO_STORE)


@router.get("/infocus-sso/start")
def start(request: Request):
    drive, ugos = _origins()
    _host(request, ugos)
    state, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    with _lock:
        now = time.time()
        for key in list(_flows):
            if _flows[key]["expires"] <= now:
                del _flows[key]
        if len(_flows) >= 1024:
            _fail(429, "Sign-in is busy. Try again shortly.")
        _flows[state] = {"browser": _digest(nonce), "expires": now + 600, "phase": "new"}
    response = RedirectResponse(f"{drive}/auth/ugos/continue?{urlencode({'state': state})}", status_code=302, headers=NO_STORE)
    response.set_cookie(COOKIE, nonce, max_age=600, secure=True, httponly=True, samesite="lax", path="/")
    return response


def _otp_page(state, message="Enter the two-factor code for your NAS account."):
    with _lock:
        flow = _flow(state)
        can_email, email_sent = flow.get("can_email"), flow.get("email_sent", False)
    method = '<input type="hidden" name="otp_type" value="1">'
    email_button = ""
    if can_email:
        selected = " selected" if email_sent else ""
        method = f'<label>Code from<select name="otp_type"><option value="1">Authenticator app</option><option value="2"{selected}>Email</option></select></label>'
        email_button = '<p><button formaction="/auth/ugos/otp/email" formnovalidate>Email a code</button></p>'
    return _page(f'''<p>{html.escape(message)}</p><form method="post" action="/auth/ugos/otp"><input type="hidden" name="state" value="{html.escape(state, quote=True)}"><label>Authentication code<input name="otp" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{{6}}" maxlength="6" required autofocus></label>{method}<button>Continue</button>{email_button}</form>''')


def _ready(state, result, user):
    data = result.get("login_data") or {}
    if not data.get("token") or not data.get("public_key") or data.get("role") in (None, "") or (data.get("username"), str(data.get("uid"))) != (user["username"], str(user["uid"])):
        _fail(502, "UGOS did not return the expected account. No session was transferred.")
    # Let native account-completion rules remain authoritative.
    if data.get("enable_change_pwd") or data.get("password_expire") or data.get("username") == "admin":
        _fail(403, "UGOS requires an account update. Open the NAS password login to complete it.")
    code = secrets.token_urlsafe(32)
    with _lock:
        flow = _flow(state)
        flow.update(phase="ready", data=data, code=_digest(code), expires=time.time() + 60)
        flow.pop("otp_id", None)
    # The extra code is essential: knowing the pre-login state and cookie alone
    # must never let an initiator redeem another browser's Google authentication.
    return _page(f'''<p>Opening your control panel…</p><form id="handoff" method="post" action="{_origins()[1]}/infocus-sso/finish"><input type="hidden" name="state" value="{state}"><input type="hidden" name="code" value="{code}"><button>Open control panel</button></form>''', script='document.getElementById("handoff").submit();')


@router.get("/auth/ugos/continue")
def continue_login(request: Request, state: str = ""):
    drive, _ = _origins()
    _host(request, drive)
    with _lock:
        if _flow(state)["phase"] != "new":
            _fail(400, "This sign-in has already been used. Open the control panel again.")
    user = _identity(request)
    if user is None:
        return RedirectResponse("/auth/login?" + urlencode({"next": "/auth/ugos/continue?" + urlencode({"state": state})}), status_code=302, headers=NO_STORE)
    drive_nonce = secrets.token_urlsafe(32)
    request.session["ugos_flow_nonce"] = drive_nonce
    with _lock:
        flow = _flow(state)
        if flow["phase"] != "new":
            _fail(400, "This sign-in has already been used.")
        now = time.time()
        for uid in list(_hits):
            _hits[uid] = [t for t in _hits[uid] if t > now - 300]
            if not _hits[uid]:
                del _hits[uid]
        hits = _hits.setdefault(user["uid"], [])
        if len(hits) >= 12:
            _fail(429, "Too many sign-in attempts. Try again in a few minutes.")
        hits.append(now)
        flow.update(phase="issuing", user=dict(user), drive_browser=_digest(drive_nonce))
    ticket = issue_ticket(user["username"], user["uid"])
    result = nas_password_login(get_settings().ugos_api_url, user["username"], ticket, return_login_data=True)
    if not result.get("ok"):
        _fail(503, "UGOS could not sign you in. Try again later.")
    if result.get("need_otp"):
        with _lock:
            _flow(state).update(phase="otp", otp_id=result["token_id"], attempts=0, can_email=bool(result.get("can_email_otp")), expires=time.time() + 300)
        return _otp_page(state)
    return _ready(state, result, user)


@router.post("/auth/ugos/otp/email")
def send_otp_email(request: Request, state: str = Form(...)):
    drive, _ = _origins()
    _host(request, drive)
    if request.headers.get("origin") != drive:
        _fail(403, "Request a code from the sign-in page.")
    user = _identity(request)
    with _lock:
        flow = _flow(state)
        if user is None or user != flow.get("user") or not hmac.compare_digest(_digest(request.session.get("ugos_flow_nonce", "")), flow.get("drive_browser", "")):
            _fail(403, "Use the browser that started sign-in.")
        if flow["phase"] != "otp" or not flow.get("can_email"):
            _fail(400, "Email verification is not available for this sign-in.")
        now = time.time()
        if now - flow.get("email_at", 0) < 60 or flow.get("emails", 0) >= 3:
            _fail(429, "Wait a minute before requesting another code.")
        flow.update(email_at=now, emails=flow.get("emails", 0) + 1)
    sent = nas_send_otp_email(get_settings().ugos_api_url, user["username"])
    if sent:
        with _lock:
            _flow(state)["email_sent"] = True
    return _otp_page(state, "Check the recovery email configured in UGOS for your code." if sent else "UGOS could not send the email. Try again later or use your authenticator.")


@router.post("/auth/ugos/otp")
def otp_login(request: Request, state: str = Form(...), otp: str = Form(...), otp_type: int = Form(1)):
    drive, _ = _origins()
    _host(request, drive)
    if request.headers.get("origin") != drive:
        _fail(403, "Submit the code from the sign-in page.")
    user = _identity(request)
    with _lock:
        flow = _flow(state)
        if user is None or user != flow.get("user") or not hmac.compare_digest(_digest(request.session.get("ugos_flow_nonce", "")), flow.get("drive_browser", "")):
            _fail(403, "Use the browser that started sign-in.")
        if flow["phase"] != "otp" or flow["attempts"] >= 5:
            _fail(400, "Start sign-in again.")
        if not re.fullmatch(r"[0-9]{6}", otp) or otp_type not in (1, 2):
            _fail(400, "Enter a six-digit code.")
        flow.update(phase="verifying", attempts=flow["attempts"] + 1)
        token_id = flow["otp_id"]
    result = nas_otp_login(get_settings().ugos_api_url, code=otp, token_id=token_id, otp_type=otp_type, return_login_data=True)
    if not result.get("ok"):
        with _lock:
            _flow(state)["phase"] = "otp"
        return _otp_page(state, "That code was invalid or expired. Try another code.")
    return _ready(state, result, user)


@router.post("/infocus-sso/finish")
def finish(request: Request, state: str = Form(...), code: str = Form(...)):
    drive, ugos = _origins()
    _host(request, ugos)
    if request.headers.get("origin") != drive:
        _fail(403, "Complete sign-in from InFocus Drive.")
    with _lock:
        flow = _flow(state)
        if flow["phase"] != "ready" or not hmac.compare_digest(flow["code"], _digest(code)) or not hmac.compare_digest(flow["browser"], _digest(request.cookies.get(COOKIE, ""))):
            _fail(400, "This sign-in belongs to another browser or has expired.")
        data = _flows.pop(state)["data"]
    response = _page('<p id="sign-in-status">Opening your control panel…</p><p><a href="/infocus-sso/start">Start again</a></p>', login_data=data)
    response.delete_cookie(COOKIE, secure=True, httponly=True, samesite="lax", path="/")
    return response
