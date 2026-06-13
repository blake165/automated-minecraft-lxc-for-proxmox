#!/usr/bin/env bash
###############################################################################
# Modded Minecraft LXC - automated provisioning for Proxmox (Crafty Controller)
#
# One-liner from the Proxmox node shell (root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/blake165/automated-minecraft-lxc-for-proxmox/main/proxmox-create-mc-lxc.sh)"
#
# Creates an LXC, installs Crafty Controller inside it, and sets it to
# autostart. Crafty's web UI then manages your Forge/Fabric/NeoForge servers
# and CurseForge modpacks.
#
# Prompts will ask for CTID, resources, network, and root password.
# Skip prompts:  NONINTERACTIVE=1 CT_ROOT_PASSWORD=x bash -c "$(curl ...)"
###############################################################################
set -euo pipefail

# ----------------------------- configurable ---------------------------------
# All overridable inline, e.g.  CTID=130 MEMORY=8192 bash -c "$(curl ...)"
CTID="${CTID:-130}"
HOSTNAME="${HOSTNAME_CT:-minecraft}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"                  # MB - modded MC is RAM-hungry
SWAP="${SWAP:-2048}"
DISK_GB="${DISK_GB:-40}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"

IP_CONFIG="${IP_CONFIG:-dhcp}"            # or static, e.g. 192.168.1.60/24
GATEWAY="${GATEWAY:-}"

CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-}"
ENABLE_SSH_ROOT="${ENABLE_SSH_ROOT:-1}"  # for scp/sftp uploads of pack zips
NONINTERACTIVE="${NONINTERACTIVE:-0}"
CRAFTY_PORT="${CRAFTY_PORT:-8443}"
CRAFTY_ADMIN_PASSWORD="${CRAFTY_ADMIN_PASSWORD:-}"  # panel login; blank = use Crafty's random one

RAW_BASE="https://raw.githubusercontent.com/blake165/automated-minecraft-lxc-for-proxmox/main"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then echo "Run as root on the Proxmox host." >&2; exit 1; fi
if ! command -v pct &>/dev/null; then echo "pct not found - is this a Proxmox host?" >&2; exit 1; fi

# Locate or download the container setup script
LOCAL_SETUP="$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")" 2>/dev/null)/mc-lxc-setup.sh"
if [[ -f "${LOCAL_SETUP}" ]]; then
  SETUP_SCRIPT="${LOCAL_SETUP}"
  echo "==> Using local mc-lxc-setup.sh"
else
  SETUP_SCRIPT="$(mktemp /tmp/mc-lxc-setup.XXXXXX.sh)"
  echo "==> Downloading mc-lxc-setup.sh from ${RAW_BASE}..."
  if ! curl -fsSL -o "${SETUP_SCRIPT}" "${RAW_BASE}/mc-lxc-setup.sh"; then
    echo "Failed to download mc-lxc-setup.sh - check RAW_BASE in this script." >&2
    exit 1
  fi
fi

# --------------------------- interactive wizard -----------------------------
ask() { local q="$1" def="$2" ans; read -r -p "  ${q} [${def}]: " ans </dev/tty; echo "${ans:-$def}"; }

if [[ "${NONINTERACTIVE}" != "1" && -e /dev/tty ]]; then
  echo ""
  echo "============================================"
  echo "   Modded Minecraft LXC - interactive setup"
  echo "   (Crafty Controller panel)"
  echo "============================================"
  echo "Press Enter to accept the [default] value."
  echo ""

  while :; do
    CTID=$(ask "Container ID" "${CTID}")
    if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then echo "  ! Must be a number."
    elif pct status "${CTID}" &>/dev/null; then echo "  ! CTID ${CTID} is already in use, pick another."
    else break; fi
  done

  HOSTNAME=$(ask "Hostname" "${HOSTNAME}")
  CORES=$(ask "CPU cores" "${CORES}")
  MEMORY=$(ask "Memory (MB) - 8192+ recommended for modpacks" "${MEMORY}")
  DISK_GB=$(ask "Disk size (GB)" "${DISK_GB}")
  STORAGE=$(ask "Storage for container disk" "${STORAGE}")
  BRIDGE=$(ask "Network bridge" "${BRIDGE}")

  NET_CHOICE=$(ask "Network: dhcp or static?" "$([[ ${IP_CONFIG} == dhcp ]] && echo dhcp || echo static)")
  if [[ "${NET_CHOICE}" == "static" ]]; then
    while :; do
      IP_CONFIG=$(ask "Static IP with CIDR (e.g. 192.168.1.60/24)" "$([[ ${IP_CONFIG} == dhcp ]] && echo '' || echo "${IP_CONFIG}")")
      [[ "${IP_CONFIG}" =~ ^[0-9.]+/[0-9]+$ ]] && break
      echo "  ! Format must be IP/prefix, e.g. 192.168.1.60/24"
    done
    while :; do
      GATEWAY=$(ask "Gateway (e.g. 192.168.1.1)" "${GATEWAY}")
      [[ -n "${GATEWAY}" ]] && break
      echo "  ! Gateway is required for a static IP."
    done
  else
    IP_CONFIG="dhcp"; GATEWAY=""
  fi

  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    while :; do
      read -r -s -p "  Container root password: " PW1 </dev/tty; echo
      read -r -s -p "  Confirm password: " PW2 </dev/tty; echo
      if [[ -z "${PW1}" ]]; then echo "  ! Password cannot be empty."
      elif [[ "${PW1}" != "${PW2}" ]]; then echo "  ! Passwords do not match, try again."
      else CT_ROOT_PASSWORD="${PW1}"; break; fi
    done
  fi

  SSH_CHOICE=$(ask "Enable SSH root login (for uploading pack zips)? (yes/no)" "yes")
  [[ "${SSH_CHOICE}" =~ ^[Yy] ]] && ENABLE_SSH_ROOT=1 || ENABLE_SSH_ROOT=0

  # Crafty web panel port
  while :; do
    CRAFTY_PORT=$(ask "Crafty web panel port" "${CRAFTY_PORT}")
    if [[ "${CRAFTY_PORT}" =~ ^[0-9]+$ ]] && (( CRAFTY_PORT >= 1 && CRAFTY_PORT <= 65535 )); then break; fi
    echo "  ! Must be a port number 1-65535."
  done

  # Crafty admin password - optional; blank keeps Crafty's auto-generated one
  echo "  (Crafty admin password: leave blank to use Crafty's random one,"
  echo "   which you'd retrieve from the logs after setup.)"
  read -r -s -p "  Crafty admin password (optional): " CPW1 </dev/tty; echo
  if [[ -n "${CPW1}" ]]; then
    while :; do
      read -r -s -p "  Confirm Crafty admin password: " CPW2 </dev/tty; echo
      if [[ "${CPW1}" != "${CPW2}" ]]; then
        echo "  ! Passwords do not match, try again."
        read -r -s -p "  Crafty admin password: " CPW1 </dev/tty; echo
      else
        CRAFTY_ADMIN_PASSWORD="${CPW1}"; break
      fi
    done
  fi

  echo ""
  echo "--------------------------------------------"
  echo "  CTID      : ${CTID}"
  echo "  Hostname  : ${HOSTNAME}"
  echo "  Cores     : ${CORES}"
  echo "  Memory    : ${MEMORY} MB"
  echo "  Disk      : ${DISK_GB} GB on ${STORAGE}"
  echo "  Network   : ${BRIDGE}, ${IP_CONFIG}${GATEWAY:+ gw ${GATEWAY}}"
  echo "  SSH root  : $([[ ${ENABLE_SSH_ROOT} == 1 ]] && echo enabled || echo disabled)"
  echo "  Panel     : Crafty on port ${CRAFTY_PORT}"
  echo "  Admin pw  : $([[ -n ${CRAFTY_ADMIN_PASSWORD} ]] && echo "set by you" || echo "Crafty random (from logs)")"
  echo "--------------------------------------------"
  CONFIRM=$(ask "Create this container? (yes/no)" "yes")
  [[ "${CONFIRM}" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  echo ""
else
  if [[ -z "${CT_ROOT_PASSWORD}" ]]; then
    echo "Non-interactive mode: set CT_ROOT_PASSWORD env var." >&2
    exit 1
  fi
fi
# -----------------------------------------------------------------------------

if pct status "${CTID}" &>/dev/null; then
  echo "CTID ${CTID} already exists. Pick a free ID." >&2; exit 1
fi

echo "==> Checking for Debian 12 template..."
pveam update >/dev/null
TEMPLATE=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null | awk '/debian-12-standard/ {print $1; exit}')
if [[ -z "${TEMPLATE}" ]]; then
  TEMPLATE_NAME=$(pveam available --section system | awk '/debian-12-standard/ {print $2; exit}')
  [[ -z "${TEMPLATE_NAME}" ]] && { echo "No debian-12-standard template available." >&2; exit 1; }
  echo "    Downloading ${TEMPLATE_NAME}..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_NAME}"
  TEMPLATE="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
fi
echo "    Using template: ${TEMPLATE}"

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG}"
if [[ "${IP_CONFIG}" != "dhcp" ]]; then
  [[ -z "${GATEWAY}" ]] && { echo "Static IP set but GATEWAY is empty." >&2; exit 1; }
  NET0+=",gw=${GATEWAY}"
fi

echo "==> Creating container ${CTID} (${HOSTNAME})..."
pct create "${CTID}" "${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory "${MEMORY}" \
  --swap "${SWAP}" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "${NET0}" \
  --unprivileged 1 \
  --features nesting=1 \
  --password "${CT_ROOT_PASSWORD}" \
  --onboot 1

echo "==> Starting container..."
pct start "${CTID}"

echo "==> Waiting for network inside the container..."
for i in $(seq 1 30); do
  pct exec "${CTID}" -- ping -c1 -W2 deb.debian.org &>/dev/null && break
  sleep 2
  [[ $i -eq 30 ]] && { echo "Container never got network access." >&2; exit 1; }
done

if [[ "${ENABLE_SSH_ROOT}" == "1" ]]; then
  echo "==> Enabling SSH root login..."
  pct exec "${CTID}" -- bash -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
    mkdir -p /etc/ssh/sshd_config.d
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-mc-root.conf
    systemctl enable ssh >/dev/null 2>&1 || true
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  "
fi

echo "==> Pushing and running Crafty setup script (installs Java + Crafty)..."
pct push "${CTID}" "${SETUP_SCRIPT}" /root/mc-lxc-setup.sh
pct exec "${CTID}" -- env \
  CRAFTY_PORT="${CRAFTY_PORT}" \
  CRAFTY_ADMIN_PASSWORD="${CRAFTY_ADMIN_PASSWORD}" \
  bash /root/mc-lxc-setup.sh

CT_IP=$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')

cat <<EOM

=============================================================================
 Container ${CTID} provisioned successfully!
=============================================================================
 Crafty panel : https://${CT_IP}:${CRAFTY_PORT}
                (self-signed cert - click through the browser warning)
 Root login   : 'pct enter ${CTID}' or console
EOM
[[ "${ENABLE_SSH_ROOT}" == "1" ]] && echo " SSH          : ssh root@${CT_IP}  (password you chose in the wizard)"
cat <<EOM

 Get your Crafty admin password (printed on first boot):
   pct exec ${CTID} -- bash -c "journalctl -u crafty -n 80 | grep -i password"
   (or: cat /var/opt/minecraft/crafty/crafty-4/app/config/default-creds.txt)

 Then in the panel: Create New Server -> Forge/Fabric/NeoForge -> pick
 version + RAM -> accept EULA -> Start. Upload CurseForge pack zips through
 the file manager if a pack blocks API downloads.

 Remember to forward each server's port (25565, 25566, ...) TCP on your
 router for outside players, and set a DHCP reservation for ${CT_IP}.
=============================================================================
EOM
