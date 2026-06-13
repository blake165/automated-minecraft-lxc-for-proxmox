#!/usr/bin/env bash
###############################################################################
# Crafty Controller (Minecraft panel) setup for a Proxmox LXC container
#
# Runs INSIDE the container as root. Normally invoked automatically by
# proxmox-create-mc-lxc.sh, but can be re-run by hand to repair/update:
#   bash /root/mc-lxc-setup.sh
#
# Installs: Java (Temurin JDK), Python3, Crafty Controller 4, and a systemd
# service so the panel autostarts with the container.
#
# Crafty's web UI then handles everything Minecraft-side: creating Vanilla/
# Paper/Fabric/Forge/NeoForge servers, version + RAM selection, live console,
# file manager, mod/modpack uploads, scheduled backups, and the EULA.
###############################################################################
set -euo pipefail

CRAFTY_PORT="${CRAFTY_PORT:-8443}"   # web panel (https)

if [[ $EUID -ne 0 ]]; then echo "Please run as root." >&2; exit 1; fi

echo "==> Installing base dependencies..."
export DEBIAN_FRONTEND=noninteractive
# Generate a locale so the perl/locale warnings don't spam everything
apt-get update -qq
apt-get install -y -qq locales curl wget git sudo ca-certificates gnupg \
  software-properties-common >/dev/null
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

echo "==> Installing Temurin JDK (Java)..."
# Adoptium repo provides modern JDKs; Crafty needs Java for the MC servers.
# Minecraft <1.17 needs Java 8, 1.17-1.20.4 needs 17, 1.20.5+ needs 21.
# We install 8, 17 and 21 so any pack works; Crafty lets you pick per-server.
mkdir -p /etc/apt/keyrings
wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
  > /etc/apt/sources.list.d/adoptium.list
apt-get update -qq
apt-get install -y -qq temurin-21-jdk temurin-17-jdk temurin-8-jdk >/dev/null \
  || apt-get install -y -qq temurin-21-jdk temurin-17-jdk >/dev/null
echo "    Java installed: $(java -version 2>&1 | head -1)"

echo "==> Installing Python and build tools for Crafty..."
apt-get install -y -qq python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev build-essential >/dev/null

echo "==> Installing Crafty Controller (this takes a few minutes)..."
INSTALL_DIR="/var/opt/minecraft"
mkdir -p "${INSTALL_DIR}"
if [[ ! -d "${INSTALL_DIR}/crafty/crafty-4" ]]; then
  cd /root
  rm -rf crafty-installer-4.0
  git clone -q https://gitlab.com/crafty-controller/crafty-installer-4.0.git
  cd crafty-installer-4.0
  # The installer is interactive; feed it the defaults (install dir + yes).
  yes | ./install_crafty.sh "${INSTALL_DIR}/crafty" || true
else
  echo "    Crafty already present at ${INSTALL_DIR}/crafty, skipping clone."
fi

# Locate the venv + entrypoint the installer produced
CRAFTY_HOME="${INSTALL_DIR}/crafty/crafty-4"
# Crafty's installer creates the virtualenv as ".venv" one level up from
# crafty-4 (i.e. ${INSTALL_DIR}/crafty/.venv), not inside crafty-4.
CRAFTY_VENV="${INSTALL_DIR}/crafty/.venv"
if [[ ! -f "${CRAFTY_HOME}/main.py" || ! -x "${CRAFTY_VENV}/bin/python3" ]]; then
  echo "Crafty install did not land where expected." >&2
  echo "  expected entrypoint: ${CRAFTY_HOME}/main.py" >&2
  echo "  expected venv:       ${CRAFTY_VENV}/bin/python3" >&2
  echo "Check /root/crafty-installer-4.0/installer.log and re-run." >&2
  exit 1
fi

# The installer's own pip step sometimes doesn't complete; install the Python
# dependencies into the venv explicitly so the panel can actually start.
echo "==> Installing Crafty Python dependencies into the venv..."
"${CRAFTY_VENV}/bin/pip" install -q -r "${CRAFTY_HOME}/requirements.txt"

# Verify the deps actually landed (peewee is the first import in main.py).
if ! "${CRAFTY_VENV}/bin/python3" -c "import peewee" 2>/dev/null; then
  echo "Crafty dependencies failed to install (peewee not importable)." >&2
  echo "Re-run: ${CRAFTY_VENV}/bin/pip install -r ${CRAFTY_HOME}/requirements.txt" >&2
  exit 1
fi

# Crafty REFUSES to run as root - it must run as an unprivileged user. The
# installer creates a 'crafty' user that owns the install dir; use it.
CRAFTY_USER="$(stat -c '%U' "${CRAFTY_HOME}")"
[[ "${CRAFTY_USER}" == "root" || -z "${CRAFTY_USER}" ]] && CRAFTY_USER="crafty"
id "${CRAFTY_USER}" &>/dev/null || useradd -r -d "${INSTALL_DIR}/crafty" -s /usr/sbin/nologin "${CRAFTY_USER}"
chown -R "${CRAFTY_USER}:${CRAFTY_USER}" "${INSTALL_DIR}"

echo "==> Creating systemd service (running as '${CRAFTY_USER}')..."
cat > /etc/systemd/system/crafty.service <<EOF
[Unit]
Description=Crafty Controller (Minecraft panel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CRAFTY_USER}
Group=${CRAFTY_USER}
WorkingDirectory=${CRAFTY_HOME}
ExecStart=${CRAFTY_VENV}/bin/python3 main.py
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8

[Install]
WantedBy=multi-user.target
EOF

# --- Preset the web panel port and admin credentials BEFORE first launch ---
# Crafty reads these config files on first boot. default.json is a one-shot
# file that Crafty ingests and deletes to set the initial admin account.
CONF_DIR="${CRAFTY_HOME}/app/config"

if [[ "${CRAFTY_PORT}" != "8443" ]]; then
  echo "==> Setting Crafty web port to ${CRAFTY_PORT}..."
  if [[ -f "${CONF_DIR}/config.json" ]]; then
    python3 - "$CONF_DIR/config.json" "$CRAFTY_PORT" <<'PY'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
with open(path) as f: cfg = json.load(f)
# the https port key has varied across versions; set whichever exist
for k in ("https_port", "port", "web_port"):
    if k in cfg: cfg[k] = port
with open(path, "w") as f: json.dump(cfg, f, indent=4)
PY
  fi
fi

if [[ -n "${CRAFTY_ADMIN_PASSWORD}" ]]; then
  echo "==> Presetting Crafty admin credentials..."
  cat > "${CONF_DIR}/default.json" <<EOF
{
    "username": "admin",
    "password": "${CRAFTY_ADMIN_PASSWORD}"
}
EOF
  chown "${CRAFTY_USER}:${CRAFTY_USER}" "${CONF_DIR}/default.json" 2>/dev/null || true
  ADMIN_NOTE="username 'admin' with the password you set in the wizard"
else
  ADMIN_NOTE="username 'admin' with a RANDOM password (retrieve it - see below)"
fi

# Final ownership pass - the config edits above may have written files as root.
chown -R "${CRAFTY_USER}:${CRAFTY_USER}" "${INSTALL_DIR}"

systemctl daemon-reload
systemctl enable crafty.service >/dev/null
systemctl restart crafty.service

cat <<EOM

=============================================================================
 Crafty Controller setup complete!
=============================================================================
 The panel is starting up (give it ~30-60 seconds on first run while it
 builds its database).

 Open it at:   https://<container-ip>:${CRAFTY_PORT}
   (You'll get a browser TLS warning - it's a self-signed cert on your own
    LAN, click through it. Crafty uses Argon2 password hashing behind it.)

 Login: ${ADMIN_NOTE}.
EOM
if [[ -z "${CRAFTY_ADMIN_PASSWORD}" ]]; then
  cat <<EOM
   Retrieve the random password with:
     journalctl -u crafty -n 60 | grep -i password
   or:  cat ${CONF_DIR}/default-creds.txt
EOM
fi
cat <<EOM
 Change it after first login under your user settings either way.

 Creating a modded server in the panel:
   1. Click "Create New Server"
   2. Server Type: choose Forge, Fabric, or NeoForge
   3. Pick the Minecraft + loader version, set RAM, name it
   4. Accept the EULA when prompted, then Start

 CurseForge modpacks:
   - Import packs via the panel's server-import / upload flow.
   - Some pack authors block third-party API downloads; for those, download
     the server-pack zip from CurseForge in your browser and upload it
     through Crafty's file manager. This works for ALL packs.

 Default ports: ${CRAFTY_PORT} (panel) and 25565+ (each MC server you make)
=============================================================================
EOM
