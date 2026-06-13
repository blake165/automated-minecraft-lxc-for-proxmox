# Troubleshooting — Minecraft LXC (Crafty Controller)

Fixes for issues hit setting up Crafty in a Proxmox LXC. Commands run on the
**Proxmox node shell** unless noted. Replace `130` with your container ID.

---

## Panel won't load / "site doesn't exist"

Work through these in order — they mirror an actual debugging session.

### 1. Is the service running AND staying up?
```bash
pct exec 130 -- systemctl is-active crafty
```
`active` is good. If it says `activating` or `failed`, it's crash-looping —
check the log (next step). "Running" in `systemctl status` can be misleading if
it's auto-restarting every few seconds; `is-active` plus the log is clearer.

### 2. Read the actual error
```bash
pct exec 130 -- journalctl -u crafty -n 40 --no-pager
```

### 3. Is anything listening on the panel port?
```bash
pct exec 130 -- bash -c "ss -tlnp | grep python"
```
Empty = Crafty isn't actually serving (it crashed or is still booting). A line
showing `:8443` = it's up and the problem is browser-side.

### 4. Use https and the right IP
The panel is **https** (not http) on port 8443:
```
https://<container-ip>:8443
```
Get the IP with `pct exec 130 -- hostname -I`. Click through the self-signed
cert warning — that warning means Crafty answered (success, not an error).
Your browser must be on the same LAN as the container.

---

## Specific errors

### "ModuleNotFoundError: No module named 'peewee'" (or any module)
Crafty's Python dependencies didn't fully install into its venv. Install them
explicitly (the venv is `.venv`, one level above `crafty-4`):
```bash
pct exec 130 -- bash -c "cd /var/opt/minecraft/crafty/crafty-4 && /var/opt/minecraft/crafty/.venv/bin/pip install -r requirements.txt"
pct exec 130 -- systemctl restart crafty
```

### "CRITICAL: Root detected. Root/Admin access denied."
Crafty refuses to run as root and shuts itself down — so the web port never
opens. The service must run as the unprivileged `crafty` user the installer
created. Fix the service file:
```bash
pct exec 130 -- bash -c 'cat > /etc/systemd/system/crafty.service <<UNIT
[Unit]
Description=Crafty Controller (Minecraft panel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=crafty
Group=crafty
WorkingDirectory=/var/opt/minecraft/crafty/crafty-4
ExecStart=/var/opt/minecraft/crafty/.venv/bin/python3 main.py
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
Environment=LANG=en_US.UTF-8
Environment=LC_ALL=en_US.UTF-8

[Install]
WantedBy=multi-user.target
UNIT
chown -R crafty:crafty /var/opt/minecraft
systemctl daemon-reload
systemctl restart crafty'
```
(The current installer script does this automatically — this is the manual fix
if you hit it on an older build.)

### Service file points at "venv" but install made ".venv"
Crafty's installer creates the virtualenv as `.venv` (with a dot) one level
above `crafty-4`, i.e. `/var/opt/minecraft/crafty/.venv`. If `ExecStart`
points at `crafty-4/venv/...` it'll fail. Correct path:
`/var/opt/minecraft/crafty/.venv/bin/python3`.

### Service "could not be found"
The installer exited before creating the systemd service (usually because the
path check failed). Re-run the setup script inside the container:
```bash
pct exec 130 -- bash /root/mc-lxc-setup.sh
```

---

## First-login password

If you didn't set an admin password in the wizard, Crafty auto-generates one:
```bash
pct exec 130 -- cat /var/opt/minecraft/crafty/crafty-4/app/config/default-creds.txt
```
or, if that file was already consumed:
```bash
pct exec 130 -- bash -c "journalctl -u crafty --no-pager | grep -i password"
```
Log in as `admin`, then change it in the panel under user settings.

---

## Locale warnings during install
`perl: warning: Setting locale failed` / `Can't set locale` — harmless Debian
container noise. The current setup script generates en_US.UTF-8 to suppress it.

---

## General debugging
```bash
pct exec 130 -- systemctl status crafty           # service state
pct exec 130 -- journalctl -u crafty -f           # live log
pct exec 130 -- bash -c "ss -tlnp | grep python"  # is it listening?
pct enter 130                                      # shell inside container
```
