# Remote SMB via Cloudflare WARP (Zero Trust)

Remote **Finder / Explorer** mounts of the Ugreen NAS **without** opening the school router and **without** Tailscale.

```text
smb://192.168.1.50
```

Replace `192.168.1.50` with your NAS LAN IP throughout this guide, and `your-team` with your Cloudflare Zero Trust team name.

- Auth for the share: **NAS username + password** (UGOS — not Google Drive login)
- Auth for remote reachability: **Cloudflare WARP** enrolled in your Zero Trust team
- Multi-share works the same as on campus once you can reach the IP

In-app instructions: Drive web UI → sidebar **Connect in Finder**.

Cloudflare reference: [SMB via Cloudflare One Client + Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/smb/).

---

## Architecture

```
Mac (WARP enrolled in team your-team)
  → Cloudflare edge (private network)
  → cloudflared on NAS (your tunnel, outbound-only)
  → 192.168.1.50:445  (UGOS Samba)
  → Finder share list (InFocus Drive, home, …)
```

No inbound SMB on the school firewall. Same tunnel that publishes the web hostnames (e.g. `drive.example.com` / `ugos.example.com` / `ssh.example.com`).

---

## Reference configuration

| Item | Value |
|------|--------|
| Zero Trust team name | `your-team` |
| Enroll URL | `https://your-team.cloudflareaccess.com/warp` |
| Tunnel | the tunnel whose `cloudflared` connector runs on the NAS |
| Private CIDR | `192.168.1.50/32` |
| Device profile split tunnels | **Include** → `192.168.1.50/32` |
| Gateway network | **Allow NAS SMB** (dest `192.168.1.50`, ports `445` + `139`) above private-traffic deny |
| Enrollment policy | **WARP allowlist** — **exact emails only** (no domain-wide `@pausd.*`) |
| Login methods | One-time PIN (and/or your IdP) |
| WARP client (macOS) | [Get started — macOS](https://developers.cloudflare.com/warp-client/get-started/macos/) |

### WARP allowlist (device enrollment)

Policy name: **WARP allowlist** (Access policy attached to Warp Login App).

Only **exact** emails you list may enroll (add/remove one at a time in the dashboard), for example:

- `admin@example.org`
- `teacher1@example.org`
- `student1@example.org`

**Do not** use “emails ending in `@pausd.org` / `@pausd.us`” — that would open WARP to the whole school.

**Add a person:** Zero Trust → **Team & Resources → Devices** → device enrollment / **WARP allowlist** → add their email → Save.

---

## Admin setup

### 1. Tunnel private network

- **Networking → Tunnels** → your NAS tunnel
- **CIDR routes** → `192.168.1.50/32`
- Do not delete published app hostnames (`drive` / `ugos` / `ssh`)

### 2. Device enrollment (WARP allowlist)

- **Devices → enrollment permissions**
- One **Allow** policy with **Include → Emails** (exact list)
- No domain-wide include rules
- One-time PIN IdP available

### 3. Split Tunnels

- Default device profile → **Include** mode
- Include `192.168.1.50/32` (+ CF Zero Trust required domains/IPs if the UI requires them)

### 4. Gateway

- **Allow NAS SMB**: destination IP `192.168.1.50`, ports `445`, `139`
- Keep a default deny for other private traffic if desired

### 5. Drive app env (NAS)

In the NAS `.env` next to `docker-compose.yml` (never commit secrets):

```bash
WARP_TEAM_NAME=your-team
WARP_ENROLL_URL=https://your-team.cloudflareaccess.com/warp
SMB_HOST=192.168.1.50
SMB_SHARE_INFOCUS=InFocus Drive
```

Recreate the Drive container after changing env so **Connect in Finder** shows the right team name.

### 6. UGOS

- SMB file service on; users have passwords; share ACLs correct
- **Do not** port-forward 445 to the public internet

---

## User steps

### First time (off campus)

1. Install WARP: [macOS get-started](https://developers.cloudflare.com/warp-client/get-started/macos/)
2. WARP → **Profile** → **Cloudflare One team login** → **Login**  
   (not Settings → Split Tunnel)
3. Team name: **`your-team`** (not an email)
4. Sign in with an **allowlisted** email only  
   - Prefer **One-time PIN** if offered  
   - “That account does not have access” = email not on the allowlist
5. Leave WARP **Connected**

### Every time (remote)

1. WARP Connected (enrolled in `your-team`)
2. Finder → **Go → Connect to Server…** (`⌘K`)
3. `smb://192.168.1.50`
4. **NAS** username + **NAS** password (not Google)
5. Pick share

### On campus

Skip WARP. Same `smb://192.168.1.50` on school Wi‑Fi (usually faster).

### Windows

After WARP enroll: `\\192.168.1.50\` or `\\192.168.1.50\InFocus Drive`.

---

## Speed / UX

| Expectation | Reality |
|-------------|---------|
| Best remote option under “no school router, no Tailscale, real Finder drive” | Yes — WARP + private SMB |
| Match campus LAN speed | No |
| Browse + copy packages / media | Good enough |
| Scrub / edit multi‑GB 4K live off the share | Prefer copy local first |

---

## Validation

| Check | Expected |
|-------|----------|
| WARP enrolled | Team `your-team`, not consumer-only “Account type: WARP” |
| Finder off campus, WARP on | Share list after NAS login |
| Finder off campus, WARP off | Times out (SMB not public — good) |
| Random school-domain enroll | Denied |
| Allowlisted email enroll | Allowed |

---

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| “That account does not have access” | Email not on **WARP allowlist** |
| Connect times out with WARP on | Not enrolled; split tunnel missing NAS; tunnel down |
| Auth fails at SMB | Wrong **NAS** password (not Google) |
| Only works on campus | WARP not connected / not enrolled off-site |
| Using the web hostname in Connect to Server | Wrong — that host is HTTPS web only |

---

## What we deliberately do not do

- Public `smb://` on the web hostname or Spectrum on 445  
- School router port-forward of SMB  
- Tailscale  
- Domain-wide school WARP enrollment  

---

## Related

- LAN guide: [FINDER-NETWORK-DRIVE.md](./FINDER-NETWORK-DRIVE.md)  
- System: [SYSTEM.md](./SYSTEM.md)  
- Deploy: [DEPLOY.md](./DEPLOY.md)  
- Web UI → **Connect in Finder**
