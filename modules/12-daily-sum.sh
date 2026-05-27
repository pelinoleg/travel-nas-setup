[[ -n "${DO_DAILY_SUM:-}" ]] || return 0

info "=== Daily summary ==="
if (
    set -e
    fetch_script "daily-summary.sh" "$SCRIPT_DIR/daily-summary.sh"
    write_systemd_unit daily-summary.service << 'EOF'
[Unit]
Description=Travel-NAS daily summary

[Service]
Type=oneshot
ExecStart=/usr/local/bin/daily-summary.sh
EOF
    write_systemd_unit daily-summary.timer << 'EOF'
[Unit]
Description=Daily summary at 21:00

[Timer]
OnCalendar=*-*-* 21:00:00
Persistent=true
Unit=daily-summary.service

[Install]
WantedBy=timers.target
EOF
    # Второй сервис/таймер: лёгкий JSON-refresh для dashboard каждые 10 мин
    # (без Telegram, без очистки event queue).
    write_systemd_unit daily-summary-refresh.service << 'EOF'
[Unit]
Description=Refresh daily-summary JSON for dashboard
After=network.target

[Service]
Type=oneshot
Nice=15
ExecStart=/usr/local/bin/daily-summary.sh --json
EOF
    write_systemd_unit daily-summary-refresh.timer << 'EOF'
[Unit]
Description=Daily-summary JSON refresh every 10 min

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
Unit=daily-summary-refresh.service

[Install]
WantedBy=timers.target
EOF
    sudo install -d -o "$(whoami)" -g "$(whoami)" -m 0755 /var/lib/travel-nas
    sudo systemctl daemon-reload
    sudo systemctl enable --now daily-summary.timer
    sudo systemctl enable --now daily-summary-refresh.timer
); then
    mark_ok "DAILY_SUM" "21:00 + UI refresh every 10min"
else
    mark_fail "DAILY_SUM" "systemd setup failed"
fi
