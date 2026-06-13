# Modded Minecraft LXC for Proxmox — one-command install

Spin up a Proxmox LXC running [Crafty Controller](https://craftycontrol.com/) —
a web panel for launching and managing modded Minecraft servers (Forge,
Fabric, NeoForge, Paper, Vanilla) — with a single pasted command. An
interactive wizard handles all the setup; Crafty's web UI handles the servers.

## Usage

Paste into the **Proxmox node shell** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-minecraft-lxc-for-proxmox/main/proxmox-create-mc-lxc.sh)"
```

A wizard walks you through every setting — press Enter to accept any
`[default]`:

```
  Container ID [130]:
  Hostname [minecraft]:
  CPU cores [4]:
  Memory (MB) - 8192+ recommended for modpacks [8192]:
  Disk size (GB) [40]:
  Storage for container disk [local-lvm]:
  Network bridge [vmbr0]:
  Network: dhcp or static? [dhcp]:
  Container root password:        (hidden, confirmed)
  Enable SSH root login? (yes/no) [yes]:
  Crafty web panel port [8443]:
  Crafty admin password (optional):   (blank = Crafty's random one)
  Create this container? (yes/no) [yes]:
```

Then it:

- downloads the Debian 12 LXC template (if missing)
- creates + starts an unprivileged container (autostart on boot enabled)
- installs Java (Temurin 8/17/21), Python, and Crafty Controller
- presets your chosen panel port and admin password before first launch
- sets up a systemd service so the panel survives reboots
- prints the panel URL and login when done

When it finishes, open **https://\<container-ip\>:\<port\>**, click through the
self-signed-cert warning, log in, and start creating servers.

## What the wizard lets you set

| Prompt | Default | Notes |
|---|---|---|
| Container ID | `130` | must be unused (FiveM repo uses 110 — no clash) |
| Hostname | `minecraft` | |
| CPU cores | `4` | |
| Memory (MB) | `8192` | modded MC is RAM-hungry — bump to 12288+ for big packs |
| Disk (GB) | `40` | modpacks + worlds grow fast |
| Storage | `local-lvm` | any Proxmox storage |
| Network | `dhcp` | or static `IP/CIDR` + gateway |
| Container root password | — | hidden, confirmed twice |
| SSH root login | `yes` | for uploading pack zips via WinSCP/scp |
| Crafty panel port | `8443` | validated, written to Crafty's config |
| Crafty admin password | random | set one, or leave blank for Crafty's auto-generated |

### Scripted / unattended install

Skip the wizard with env vars:

```bash
NONINTERACTIVE=1 \
CTID=131 HOSTNAME_CT=mc-create CORES=6 MEMORY=12288 DISK_GB=80 \
IP_CONFIG="192.168.1.60/24" GATEWAY="192.168.1.1" \
CT_ROOT_PASSWORD='root-pass' \
CRAFTY_PORT=8443 CRAFTY_ADMIN_PASSWORD='panel-pass' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-minecraft-lxc-for-proxmox/main/proxmox-create-mc-lxc.sh)"
```

## Creating a modded server

1. Log into the panel (change the admin password if it auto-generated one)
2. **Create New Server** → type **Forge**, **Fabric**, or **NeoForge**
3. Pick the Minecraft + loader version and RAM allocation
4. Accept the EULA, then **Start** — Crafty downloads everything

The installer puts **Java 8, 17, and 21** in the container so any MC version
works (1.8–1.16 → 8, 1.17–1.20.4 → 17, 1.20.5+ → 21). Pick per-server in Crafty.

## CurseForge modpacks

Crafty can import packs, but **some pack authors disable third-party API
downloads** (a CurseForge project flag) — which makes *any* panel fail on those
specific packs. The workaround that works for **every** pack:

1. On the CurseForge site, download the pack's **server** files (zip)
2. Upload it through Crafty's file manager (SSH/WinSCP for large zips)
3. Point the server's start command at the pack's start script or Forge jar

There is no "log in with CurseForge" — CurseForge offers no consumer OAuth for
third-party apps, only project-ID API access — so URL/zip import is the
reliable path.

## Ports

- **panel port** (default `8443`) — the Crafty web UI
- `25565`, `25566`, … — one per Minecraft server you create; forward **TCP**
  on your router for outside players, and set a DHCP reservation (or static IP)
  so the container's address doesn't change

## Updating Crafty

```bash
pct exec <CTID> -- bash -c "cd /var/opt/minecraft/crafty/crafty-4 && git pull && venv/bin/pip install -r requirements.txt"
pct exec <CTID> -- systemctl restart crafty
```

## Notes

- Container is **unprivileged** with `nesting=1` and `onboot=1` — starts with
  the Proxmox host automatically.
- The panel uses a self-signed TLS cert on your LAN; the browser warning is
  expected. Crafty hashes passwords with Argon2.
- Built with the same wizard pattern as
  [automated-FiveM-lxc-for-proxmox](https://github.com/blake165/automated-FiveM-lxc-for-proxmox).
