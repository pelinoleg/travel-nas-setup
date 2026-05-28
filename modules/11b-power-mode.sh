[[ -n "${DO_POWER_MODE:-}" ]] || return 0

info "=== Power mode ==="
if (
    set -e
    fetch_script "power-mode.sh" "$SCRIPT_DIR/power-mode.sh"
    sudo mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/power-mode.conf" ]]; then
        fetch_conf_example "power-mode.conf.example" "$CONFIG_DIR/power-mode.conf"
    fi
    sudo chown "$(whoami):$(whoami)" "$CONFIG_DIR/power-mode.conf"
    sudo chmod 0644 "$CONFIG_DIR/power-mode.conf"

    # NetworkManager dispatcher — при connect/disconnect пересчитывает режим
    DISP_DIR="/etc/NetworkManager/dispatcher.d"
    if [[ -d "$DISP_DIR" ]]; then
        fetch_script "99-travel-nas-power" "$DISP_DIR/99-travel-nas-power"
        sudo chown root:root "$DISP_DIR/99-travel-nas-power"
        sudo chmod 0755 "$DISP_DIR/99-travel-nas-power"
    fi
    # Минутный тик power-mode — отдельный от system-monitor (тот раз в 5 мин,
    # ловит крупные события). Для температуры 5 мин слишком грубо — короткие
    # пики Pi-5 успевают остыть между тиками и saver не включается.
    write_systemd_unit power-mode-tick.service << 'EOF'
[Unit]
Description=Travel-NAS power-mode auto-tick

[Service]
Type=oneshot
ExecStart=/usr/local/bin/power-mode.sh auto-tick
EOF
    write_systemd_unit power-mode-tick.timer << 'EOF'
[Unit]
Description=Run power-mode auto-tick every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Unit=power-mode-tick.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now power-mode-tick.timer

    # Один раз сейчас — применить режим по текущему состоянию
    sudo /usr/local/bin/power-mode.sh auto-tick >/dev/null 2>&1 || true
); then
    mark_ok "POWER_MODE" "1-min tick + NM dispatcher"
else
    mark_fail "POWER_MODE" "install failed"
fi
