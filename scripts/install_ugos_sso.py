#!/usr/bin/python3
"""Install/roll back the service-local UGOS login bridge. Run on the NAS as root."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PAM = Path("/etc/pam.d/ugreen-login")
HELPER = Path("/usr/local/libexec/infocus-ugos-sso-pam")
NGINX = Path("/etc/nginx/conf.d/infocus_sso.conf")
ROOT_CONFIGS = [Path("/etc/nginx") / name for name in ("ugreen.conf", "ugreen_ssl.conf", "ugreen_ssl2.conf")]
BACKUP = Path("/var/lib/infocus-ugos-sso")
MARKER = "# InFocus Google sign-in"
PAM_BRIDGE = f'''{MARKER}
auth [success=2 default=ignore] pam_exec.so quiet quiet_log expose_authtok /usr/bin/python3 -I {HELPER}
auth substack common-auth-faillock
auth [default=4] pam_permit.so
auth requisite pam_faillock.so preauth audit
auth requisite pam_ug_login.so preauth
auth optional pam_faillock.so authsucc audit
auth optional pam_ug_login.so authsucc
auth required pam_permit.so
'''
NGINX_BRIDGE = f'''{MARKER}
location ^~ /infocus-sso/ {{
    if ($host != ugos.infocuspaly.com) {{ return 404; }}
    proxy_pass http://127.0.0.1:8787;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 60s;
    proxy_buffering off;
    add_header Cache-Control "private, no-store" always;
}}
'''
OLD_ROOT = 'ngx.header["Location"] = "/desktop/?os=ugospro"'
NEW_ROOT = 'ngx.header["Location"] = (ngx.var.host == "ugos.infocuspaly.com") and "/infocus-sso/" or "/desktop/?os=ugospro"'


def pam_config(original):
    if MARKER in original:
        return original
    if original.count("@include common-auth-faillock") != 1:
        raise RuntimeError("Unexpected UGOS PAM configuration; refusing to replace it")
    return original.replace("@include common-auth-faillock", PAM_BRIDGE)


def root_config(original):
    if NEW_ROOT in original:
        return original
    return original.replace(OLD_ROOT, NEW_ROOT)


def write_atomic(path, content, mode):
    descriptor, temp = tempfile.mkstemp(prefix=path.name + ".infocus-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as out:
            os.fchmod(out.fileno(), mode)
            out.write(content)
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


def reload_nginx():
    subprocess.run(["nginx", "-t"], check=True, timeout=15)
    subprocess.run(["systemctl", "reload", "nginx"], check=True, timeout=20)


def main():
    if os.geteuid() != 0:
        raise RuntimeError("Run this installer as root")
    os.umask(0o077)
    manifest = BACKUP / "manifest.json"
    if sys.argv[1:] == ["--rollback"]:
        records = json.loads(manifest.read_text())
        for item in records:
            path = Path(item["path"])
            if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != item["installed_hash"]:
                raise RuntimeError(f"{path} changed since installation; inspect before rollback")
        for item in records:
            path = Path(item["path"])
            if item["backup"] is None:
                path.unlink()
            else:
                write_atomic(path, (BACKUP / item["backup"]).read_bytes(), item["mode"])
        reload_nginx()
        manifest.rename(BACKUP / "rolled-back.json")
        print("UGOS Google sign-in removed; original files restored")
        return
    if sys.argv[1:]:
        raise RuntimeError("Usage: install_ugos_sso.py [--rollback]")
    if manifest.exists():
        raise RuntimeError("Already installed; use the documented rollback before reinstalling")
    if HELPER.exists() or NGINX.exists():
        raise RuntimeError("Bridge files already exist; inspect before installing")
    changes = {
        PAM: (pam_config(PAM.read_text()).encode(), 0o644),
        HELPER: (Path(__file__).with_name("ugos_sso_pam.py").read_bytes(), 0o700),
        NGINX: (NGINX_BRIDGE.encode(), 0o644),
    }
    for path in ROOT_CONFIGS:
        if path.exists():
            original = path.read_text()
            changed = root_config(original)
            if changed != original:
                changes[path] = (changed.encode(), path.stat().st_mode & 0o777)
    if len(changes) == 3:
        raise RuntimeError("Could not locate the native UGOS root redirect")
    BACKUP.mkdir(parents=True, mode=0o700, exist_ok=True)
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    records = []
    for index, (path, (content, mode)) in enumerate(changes.items()):
        backup = None
        if path.exists():
            backup = str(index) + ".original"
            shutil.copyfile(path, BACKUP / backup)
            (BACKUP / backup).chmod(0o600)
        records.append({"path": str(path), "backup": backup, "mode": path.stat().st_mode & 0o777 if path.exists() else mode,
                        "installed_hash": hashlib.sha256(content).hexdigest()})
    # Save rollback metadata before touching authentication configuration.
    manifest.write_text(json.dumps(records, indent=2))
    try:
        # Helper is present before enabling the PAM reference.
        for path in (HELPER, PAM, NGINX, *[p for p in changes if p not in (HELPER, PAM, NGINX)]):
            content, mode = changes[path]
            write_atomic(path, content, mode)
        reload_nginx()
    except BaseException:
        for item in records:
            path = Path(item["path"])
            if item["backup"] is None:
                path.unlink(missing_ok=True)
            else:
                write_atomic(path, (BACKUP / item["backup"]).read_bytes(), item["mode"])
        manifest.unlink()
        reload_nginx()
        raise
    print("UGOS Google sign-in installed; original files and rollback manifest saved")


if __name__ == "__main__":
    main()
