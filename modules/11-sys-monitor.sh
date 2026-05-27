[[ -n "${DO_SYS_MONITOR:-}" ]] || return 0

info "=== System monitor ==="
if (
    set -e
    fetch_script "system-monitor.sh" "$SCRIPT_DIR/system-monitor.sh"
    write_systemd_unit system-monitor.service << 'EOF'
[Unit]
Description=Travel-NAS system monitor

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-monitor.sh
EOF
    write_systemd_unit system-monitor.timer << 'EOF'
[Unit]
Description=Run system-monitor every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Unit=system-monitor.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now system-monitor.timer
); then
    mark_ok "SYS_MONITOR"
else
    mark_fail "SYS_MONITOR" "systemd setup failed"
fi
