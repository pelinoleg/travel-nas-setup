[[ -n "${DO_PHOTO_BACKUP:-}" ]] || return 0

info "=== Photo backup ==="
if (
    set -e
    sudo mkdir -p "$CONFIG_DIR"
    fetch_script "photo-backup.sh" "$SCRIPT_DIR/photo-backup.sh"
    # Progress writer нужен photo-backup для прогресс-плашки в dashboard
    fetch_script "backup-progress-writer.py" "$SCRIPT_DIR/backup-progress-writer.py"
    T7_UUID=""
    if [[ -f "$CONFIG_DIR/t7-info.conf" ]]; then
        source "$CONFIG_DIR/t7-info.conf"
    fi
    if [[ ! -f "$CONFIG_DIR/photo-backup.conf" ]]; then
        sudo tee "$CONFIG_DIR/photo-backup.conf" > /dev/null << EOF
DEST="$T7_MOUNT/usb-imports"
AUTO_UMOUNT=true
T7_UUID="${T7_UUID:-}"
MIN_SIZE=1
WAIT_FOR_DEVMON=3
EOF
        sudo chmod 644 "$CONFIG_DIR/photo-backup.conf"
    fi
    write_systemd_unit photo-backup@.service << 'EOF'
[Unit]
Description=Photo Backup for %i
After=local-fs.target network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/photo-backup.sh /dev/%i
User=root
TimeoutStartSec=7200
EOF
    sudo tee /etc/udev/rules.d/99-photo-backup.rules > /dev/null << 'EOF'
ACTION=="add", KERNEL=="sd[a-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}+="photo-backup@%k.service"
EOF
    sudo systemctl daemon-reload
    sudo udevadm control --reload-rules
); then
    mark_ok "PHOTO_BACKUP"
else
    mark_fail "PHOTO_BACKUP" "udev/systemd setup failed"
fi
