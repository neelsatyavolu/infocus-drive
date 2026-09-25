from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # Google OAuth (Google Workspace)
    google_client_id: str = ""
    google_client_secret: str = ""
    # Public origin, e.g. https://drive.example.com (Cloudflare Tunnel)
    public_base_url: str = "http://localhost:8787"
    # Direct LAN origin for the same app (nginx gateway). When reachable from
    # the browser, the UI session-handoffs here to skip the tunnel hop.
    # Empty string disables LAN prefer. Example: http://192.168.1.50:8790 (NAS IP + gateway port).
    lan_origin: str = ""
    # Auto-switch to LAN when probe succeeds (set false to only show a hint).
    lan_prefer: bool = True
    # Allowed Google email domains (comma-separated). Local-part maps to NAS username.
    allowed_email_domains: str = ""
    # Google OAuth `hd` (hosted domain). Restricts the account chooser to one Workspace domain.
    google_hosted_domain: str = ""

    session_secret: str = "change-me-in-production"
    # Email-code sign-in; state survives image rebuilds in the mounted config directory.
    resend_api_key: str = ""
    resend_from_email: str = ""
    email_sign_in_db_path: str = "/config/email_sign_in.sqlite3"
    # Terminal (`infocus` CLI) sign-ins; hashed tokens on the persistent config mount.
    cli_tokens_db_path: str = "/config/cli_tokens.sqlite3"

    session_cookie: str = "infocus_drive_session"
    session_max_age: int = 60 * 60 * 24 * 5  # 5 days

    # Default share root (packages service + non-admin UI). Mount under volume2 in compose.
    drive_root: str = "/data/volume2/InFocus Drive"
    # UGOS shared folders live under these volume mounts (non-@* dirs / Samba paths).
    shares_volume: str = "/data/volume2"
    # Comma-separated volume roots inside the container (volume1 + volume2 on Ugreen).
    shares_volumes: str = "/data/volume1,/data/volume2"
    # Extra shared folders mounted individually (legacy; volume1 mount covers these now).
    extra_shares_dir: str = "/data/extra"
    # UGOS Samba share definitions — source of truth for share names + valid users.
    samba_shares_conf: str = "/config/smbshare.conf"
    # Optional JSON map overrides: {"email@example.org": "nasusername"}
    user_map_path: str = "/config/user_map.json"
    # UGOS admin portal (relative path on same host via tunnel)
    # Full UGOS portal (separate hostname — UGOS breaks under path prefixes)
    ugos_admin_path: str = ""
    ugos_sso_enabled: bool = False

    # Finder / Windows network drive (native SMB on the Ugreen NAS — not OAuth).
    # On campus: direct LAN. Off campus: Cloudflare WARP private network (see docs/REMOTE-SMB-WARP.md).
    smb_host: str = ""
    # Optional NetBIOS/DNS name if UGOS advertises one (empty = use smb_host only)
    smb_hostname: str = ""
    # Share name for the InFocus program drive (spaces ok; URL-encoded in UI)
    smb_share_infocus: str = "InFocus Drive"
    # Cloudflare Zero Trust team name for WARP enrollment
    warp_team_name: str = ""
    # Optional full enroll URL; defaults to https://{warp_team_name}.cloudflareaccess.com/warp
    warp_enroll_url: str = ""

    # Machine auth for infocus-packages → NAS storage under Package Cycles
    # Generate a long random string; packages sets the same as DRIVE_SERVICE_TOKEN.
    packages_service_token: str = ""
    # NAS Linux username that owns Package Cycles writes (must exist, uid>=1000)
    packages_service_user: str = ""
    # Relative root under drive for packages media (must match site structure)
    packages_root: str = "Package Cycles"
    # infocus-packages origin for the Drive roster (same token as packages_service_token).
    packages_roster_url: str = ""
    # Last-seen packages emails; used to delete NAS users who left the roster.
    packages_roster_snapshot_path: str = "/config/packages_roster.json"

    # UGOS control-panel API (legacy; user create uses userd instead).
    ugos_api_url: str = "http://127.0.0.1:9999"
    ugos_admin_user: str = ""
    ugos_admin_password: str = ""
    personal_credential_path: str = "/config/personal_service.enc"
    personal_state_path: str = "/config/personal_folders.sqlite3"
    # Samba/UGOS group that may use the InFocus Drive share.
    ugos_sync_group: str = "InFocus Members"
    # Localhost helper (infocus-userd) that useradds on the NAS host.
    userd_url: str = "http://127.0.0.1:8791"
    userd_token: str = ""
    # Comma-separated NAS usernames that must never be created, edited, or deleted.
    user_sync_protected_usernames: str = ""
    # Comma-separated emails that must never be provisioned (super-admin).
    user_sync_protected_emails: str = ""

    host: str = "0.0.0.0"
    port: int = 8787


@lru_cache
def get_settings() -> Settings:
    return Settings()


SESSION_SECRET_MIN_LEN = 32
_PLACEHOLDER_SECRETS = ("generate-a-long-random-string",)


def require_strong_session_secret(secret: str) -> None:
    """Raise unless SESSION_SECRET is set to a real random value.

    It signs session cookies, OAuth state, LAN handoffs and file links, and
    encrypts stored UGOS sessions, so a guessable value is a full compromise.
    """
    value = (secret or "").strip()
    if (
        len(value) < SESSION_SECRET_MIN_LEN
        or value.lower().startswith("change-me")
        or value.lower() in _PLACEHOLDER_SECRETS
    ):
        raise RuntimeError(
            f"SESSION_SECRET must be a random string of at least {SESSION_SECRET_MIN_LEN} "
            "characters (e.g. `openssl rand -hex 32`); refusing to start with a "
            "missing, placeholder, or short value."
        )
