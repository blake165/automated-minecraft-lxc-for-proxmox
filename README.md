# Modded Minecraft LXC for Proxmox — one-command install

Spin up a Proxmox LXC running [Crafty Controller](https://craftycontrol.com/) —
a web panel for launching and managing modded Minecraft servers (Forge,
Fabric, NeoForge, Paper, Vanilla) — with a single command.

## Usage

Paste into the **Proxmox node shell** (as root):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-minecraft-lxc-for-proxmox/main/proxmox-create-mc-lxc.sh)"
```

An interactive wizard asks for container ID, resources, network, and a root
password, then:

- downloads the Debian 12 LXC template (if missing)
- creates + starts an unprivileged container (onboot enabled)
- installs Java (Temurin 8/17/21), Python, and Crafty Controller inside it
- sets up a systemd service so the panel survives reboots
- prints the panel URL when done

When it finishes, open **https://\<container-ip\>:8443**, grab the first-run
admin password from the logs, and start creating servers.

### Customizing inline

```bash
CTID=131 HOSTNAME_CT=mc-create CORES=6 MEMORY=12288 DISK_GB=80 \
IP_CONFIG="192.168.1.60/24" GATEWAY="192.168.1.1" \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-minecraft-lxc-for-proxmox/main/proxmox-create-mc-lxc.sh)"
```

| Variable | Default | Notes |
|---|---|---|
| `CTID` | `130` | must be unused |
| `HOSTNAME_CT` | `minecraft` | container hostname |
| `CORES` | `4` | |
| `MEMORY` | `8192` | MB — bump for big modpacks (12288+) |
| `DISK_GB` | `40` | modpacks + worlds grow fast |
| `STORAGE` | `local-lvm` | |
| `BRIDGE` | `vmbr0` | |
| `IP_CONFIG` | `dhcp` | or static `192.168.1.60/24` |
| `GATEWAY` | — | required if static |
| `CT_ROOT_PASSWORD` | — | prompted (hidden) if unset |
| `ENABLE_SSH_ROOT` | `1` | for uploading pack zips via scp/sftp |
| `CRAFTY_PORT` | `8443` | panel web port |

## Creating a modded server

1. Log into the panel, change the admin password
2. **Create New Server** → type **Forge**, **Fabric**, or **NeoForge**
3. Pick the Minecraft + loader version and RAM allocation
4. Accept the EULA, then **Start** — Crafty downloads everything

## CurseForge modpacks

Crafty can import packs, but **some pack authors disable third-party API
downloads** (a CurseForge flag), which makes any panel fail on those specific
packs. The universal workaround that works for every pack:

1. On the CurseForge site, download the pack's **server** files (zip)
2. In Crafty's file manager, create a server and upload/extract the zip
3. Point the server's start command at the pack's start script or forge jar

There is no "log in with CurseForge" — CurseForge offers no consumer OAuth for
third-party apps, only project-ID API access — so URL/zip import is the
reliable path.

## Java versions

The installer puts Java 8, 17, and 21 in the container so any MC version works
(1.8–1.16 → Java 8, 1.17–1.20.4 → 17, 1.20.5+ → 21). Pick per-server in Crafty.

## Ports

- `8443` — Crafty web panel
- `25565`, `25566`, … — one per Minecraft server you create; forward TCP on
  your router for outside players

## Updating Crafty

```bash
pct exec <CTID> -- bash -c "cd /var/opt/minecraft/crafty/crafty-4 && git pull && venv/bin/pip install -r requirements.txt"
pct exec <CTID> -- systemctl restart crafty
```
