[[ -n "${DO_VERIFY:-}" ]] || return 0

info "=== Backup verify scrub ==="
if (
    set -e
    fetch_script "nas-verify.py" "$SCRIPT_DIR/nas-verify.py"
    sudo install -d -o "$(whoami)" -g "$(whoami)" -m 0755 /var/lib/travel-nas

    write_systemd_unit nas-verify.service << 'EOF'
[Unit]
Description=Travel-NAS T7 verify scrub (sha256 manifest + I/O check)
After=mnt-t7.mount
RequiresMountsFor=/mnt/t7

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/python3 /usr/local/bin/nas-verify.py
EOF
    write_systemd_unit nas-verify.timer << 'EOF'
[Unit]
Description=Run nas-verify monthly

[Timer]
# Раз в месяц, 1-го числа в 04:15. На travel-NAS обычно ночью пусто.
OnCalendar=monthly
# Persistent=true: если Pi был выключен в назначенное время, догонит при загрузке.
Persistent=true
Unit=nas-verify.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now nas-verify.timer
); then
    NEXT=$(systemctl list-timers nas-verify.timer 2>/dev/null | awk 'NR==2 {print $1,$2}')
    mark_ok "VERIFY" "ежемесячно (next: ${NEXT:-?})"
else
    mark_fail "VERIFY" "setup failed"
fi
