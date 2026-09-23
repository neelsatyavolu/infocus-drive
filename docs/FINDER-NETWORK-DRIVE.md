# Finder / network drive (SMB)

Mount the Ugreen NAS in **macOS Finder** (or Windows Explorer) with **NAS username + password** — not Google OAuth. You can pick **any share** your NAS ACL allows (InFocus Drive, home folders, other shares, etc.).

The web app (e.g. **https://drive.example.com**) is **not** a network-drive server. Do not put that hostname in **Connect to Server**.

In-app copy-paste helper: Drive sidebar → **Connect in Finder**.

---

## Web app vs SMB

| | Web (`drive.example.com`) | SMB (Finder network drive) |
|--|--|--|
| Auth | Google OAuth → mapped NAS user | **NAS username + password** |
| Shares | InFocus Drive only (browser root) | **All shares** your NAS ACL allows |
| Best for | Browser browse / packages API | Desktop apps, multi-share, large files |
| On campus | Cloudflare Tunnel | School LAN → NAS LAN IP (e.g. `192.168.1.50`) |
| Off campus | Cloudflare Tunnel | **WARP** → private network → same IP |

---

## On campus (LAN)

1. Finder → **Go → Connect to Server…** (`⌘K`)
2. Server address:

   ```text
   smb://192.168.1.50
   ```

   Replace `192.168.1.50` with your NAS LAN IP.

   Leave the share off the URL so Finder can list **every** share you may access.

3. Connect → **NAS username** (often email local-part, e.g. `student1` for `student1@pausd.us`)  
4. Password: **NAS / UGOS password** — not Google  

WARP is **not** required on campus.

### Windows

```text
\\192.168.1.50\
```

---

## Off campus (remote)

SMB is **not** public on the internet. Use Cloudflare WARP:

1. Install [WARP for macOS](https://developers.cloudflare.com/warp-client/get-started/macos/)
2. **Profile → Cloudflare One team login → Login**
3. Team: **`your-team`** (your Zero Trust team name)
4. Sign in with an **allowlisted** email only (adviser must add you — not all of PAUSD)
5. Leave WARP **Connected**
6. Same as on campus: `smb://<NAS LAN IP>` + NAS password

Full remote guide (admin + allowlist + CF dashboard): **[REMOTE-SMB-WARP.md](./REMOTE-SMB-WARP.md)**.

Do **not** port-forward SMB (445) to the public internet.

---

## Drive app config (NAS `.env`)

| Env | Example | Purpose |
|-----|----------------|---------|
| `SMB_HOST` | `192.168.1.50` | LAN IP for `smb://…` |
| `SMB_HOSTNAME` | _(empty)_ | Optional friendlier name if UGOS advertises one |
| `SMB_SHARE_INFOCUS` | `InFocus Drive` | Shown in docs; UI focuses on server-level mount |
| `WARP_TEAM_NAME` | `your-team` | Shown in **Connect in Finder** |
| `WARP_ENROLL_URL` | `https://your-team.cloudflareaccess.com/warp` | Optional enroll link |

---

## UGOS checklist

1. **File Services → SMB** enabled  
2. User accounts exist with known passwords  
3. Share permissions / ACLs grant the right people on the right shares  
4. Firewall: **445** from school LAN (not from WAN)

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Connect times out on campus | Wrong Wi‑Fi / VLAN; confirm NAS IP |
| Connect times out off campus | WARP not enrolled/connected — see [REMOTE-SMB-WARP.md](./REMOTE-SMB-WARP.md) |
| Auth failed | NAS password, not Google |
| Share missing | ACL / share permission in UGOS |
| Web hostname in Connect to Server | Expected to fail — use `smb://<NAS LAN IP>` |
| WARP “That account does not have access” | Email not on allowlist — ask an adviser |

---

## Related

- Remote WARP: [REMOTE-SMB-WARP.md](./REMOTE-SMB-WARP.md)  
- System: [SYSTEM.md](./SYSTEM.md)  
- Web: `https://drive.example.com`  
- UGOS: `https://ugos.example.com/`
