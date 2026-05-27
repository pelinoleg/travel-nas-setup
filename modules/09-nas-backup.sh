[[ -n "${DO_NAS_BACKUP:-}" ]] || return 0

info "=== NAS backup ==="
if (
    set -e
    sudo mkdir -p "$CONFIG_DIR"
    if ! command -v sshpass &>/dev/null; then
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass
    fi
    fetch_script "nas-backup.sh"        "$SCRIPT_DIR/nas-backup.sh"
    fetch_script "nas-backup-status.py" "$SCRIPT_DIR/nas-backup-status.py"

    # /var/lib/travel-nas (status JSONs) — oleg-owned для tg-listener offset etc
    sudo install -d -o "$(whoami)" -g "$(whoami)" -m 0755 /var/lib/travel-nas

    write_systemd_unit nas-backup-status.service << 'EOF'
[Unit]
Description=Refresh NAS-backup folder sizes/status
After=network.target

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/python3 /usr/local/bin/nas-backup-status.py
EOF
    write_systemd_unit nas-backup-status.timer << 'EOF'
[Unit]
Description=Hourly NAS-backup status refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Unit=nas-backup-status.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now nas-backup-status.timer

    if [[ ! -f "$CONFIG_DIR/nas-backup.conf" ]]; then
        NAS_HOST=$(whiptail --inputbox "NAS IP:" 10 60 "192.168.1.95" 3>&1 1>&2 2>&3) || NAS_HOST="192.168.1.95"
        NAS_USER=$(whiptail --inputbox "NAS user:" 10 60 "oleg" 3>&1 1>&2 2>&3) || NAS_USER="oleg"
        NAS_PASS=$(whiptail --passwordbox "NAS password:" 10 60 3>&1 1>&2 2>&3) || NAS_PASS=""
        sudo tee "$CONFIG_DIR/nas-backup.conf" > /dev/null << EOF
NAS_HOST="$NAS_HOST"
NAS_USER="$NAS_USER"
NAS_PASS="$NAS_PASS"
DEST="$T7_MOUNT/nas-backup"
MODULES=(
    "home|Personal"
    "docker|Docker"
    "Backup|Backup"
    "PMedia|PMedia"
    "Music|Music"
)
EXCLUDES=(
    "_gsdata_" ".DS_Store" "Thumbs.db" "@eaDir/" "#recycle/"
    ".Trash*" "*.tmp" ".cache/" "node_modules/" "__pycache__/"
    "vendor/" ".next/" ".nuxt/" "dist/" "build/" ".git/" ".svn/"
)
EOF
        sudo chmod 600 "$CONFIG_DIR/nas-backup.conf"
    fi
); then
    mark_ok "NAS_BACKUP"
else
    mark_fail "NAS_BACKUP" "config failed"
fi
