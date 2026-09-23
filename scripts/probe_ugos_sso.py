#!/usr/bin/python3
"""Bounded NAS-only proof: temporarily add Google-ticket PAM authentication.

Run as root with ugos_sso_pam.py beside this file. Restores the original PAM
file in finally and schedules an independent 90-second rollback first.
Reads the existing test account's password from stdin only to verify that
normal password authentication still works; never stores or prints it.
"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


PAM_FILE = Path("/etc/pam.d/ugreen-login")
BRIDGE = """# Temporary InFocus SSO proof
auth [success=2 default=ignore] pam_exec.so quiet quiet_log expose_authtok /usr/bin/python3 -I {helper}
auth substack common-auth-faillock
auth [default=4] pam_permit.so
auth requisite pam_faillock.so preauth audit
auth requisite pam_ug_login.so preauth
auth optional pam_faillock.so authsucc audit
auth optional pam_ug_login.so authsucc
auth required pam_permit.so
"""

# The container already has the current UGOS HTTP client and dependencies.
CHECK = r'''
import json, sys
sys.path.insert(0, "/app")
from ugos_api import nas_password_login, UgosClient
p = json.load(sys.stdin)
r = nas_password_login("http://127.0.0.1:9999", p["username"], p["credential"], return_session=True)
out = {"ok": bool(r.get("ok")), "need_otp": bool(r.get("need_otp")), "code": r.get("code")}
if r.get("session"):
    with UgosClient("http://127.0.0.1:9999", p["username"], "") as c:
        c._token = r["session"]["token"]
        c._en_public_key = r["session"]["public_key"]
        try:
            response = c._authed("GET", "/ugreen/v1/verify/is_login")
            out["session_valid"] = response.get("code") == 200
        finally:
            c._authed("PUT", "/ugreen/v1/verify/logout")
print(json.dumps(out))
'''


def check(username, credential):
    result = subprocess.run(
        ["docker", "exec", "-i", "infocus-drive", "python", "-c", CHECK],
        input=json.dumps({"username": username, "credential": credential}),
        capture_output=True, text=True, timeout=45,
    )
    if result.returncode:
        # Client tracebacks could contain request material: do not echo them.
        raise RuntimeError("UGOS check failed; diagnostic output withheld")
    return json.loads(result.stdout)


def main():
    username = sys.argv[1]
    native_password = sys.stdin.readline().rstrip("\n")
    original = PAM_FILE.read_bytes()
    marker = b"@include common-auth-faillock"
    if original.count(marker) != 1 or b"infocus" in original.lower():
        raise RuntimeError("Unexpected PAM configuration; no changes made")
    probe = Path(tempfile.mkdtemp(prefix="infocus-ugos-proof-", dir="/run"))
    backup = probe / "original-pam"
    backup.write_bytes(original)
    backup.chmod(0o600)
    helper = probe / "helper"
    shutil.copyfile(Path(__file__).with_name("ugos_sso_pam.py"), helper)
    helper.chmod(0o700)
    unit = probe.name + "-rollback"
    subprocess.run(
        ["systemd-run", "--quiet", "--unit", unit, "--on-active=90s", "/bin/cp", "--", str(backup), str(PAM_FILE)],
        check=True, capture_output=True,
    )
    try:
        PAM_FILE.write_bytes(original.replace(marker, BRIDGE.format(helper=helper).encode()))
        ticket = subprocess.run(
            ["/usr/bin/python3", "-I", str(helper), "--issue", username], capture_output=True, text=True, check=True, timeout=5,
        ).stdout.strip()
        print("ticket_login", json.dumps(check(username, ticket)), flush=True)
        print("native_password_login", json.dumps(check(username, native_password)), flush=True)
    finally:
        PAM_FILE.write_bytes(original)
        if PAM_FILE.read_bytes() != original:
            raise RuntimeError("PAM restore verification failed")
        print("original_pam_restored", flush=True)
        subprocess.run(["systemctl", "stop", unit + ".timer"], check=True, capture_output=True)
        shutil.rmtree(probe)


if __name__ == "__main__":
    main()
