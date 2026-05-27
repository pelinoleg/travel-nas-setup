[[ -n "${DO_WATCHDOG:-}" ]] || return 0

info "=== Disk watchdog ==="
if (
    set -e
    fetch_script "disk-watchdog.sh" "$SCRIPT_DIR/disk-watchdog.sh"
    write_systemd_unit disk-watchdog.service << 'EOF'
[Unit]
Description=Travel-NAS disk watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-watchdog.sh
EOF
    write_systemd_unit disk-watchdog.timer << 'EOF'
[Unit]
Description=Run disk-watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=disk-watchdog.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now disk-watchdog.timer
); then
    mark_ok "WATCHDOG" "каждые 5 мин"
else
    mark_fail "WATCHDOG" "systemd setup failed"
fi
