[[ -n "${DO_THERMAL_GUARD:-}" ]] || return 0

info "=== Thermal guard ==="
if (
    set -e
    fetch_script "thermal-guard.py" "$SCRIPT_DIR/thermal-guard.py"
    sudo mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/thermal-guard.conf" ]]; then
        fetch_conf_example "thermal-guard.conf.example" "$CONFIG_DIR/thermal-guard.conf"
        # Owner = oleg чтобы /thermal в TG мог редактировать через python без sudo
        sudo chown "$(whoami):$(whoami)" "$CONFIG_DIR/thermal-guard.conf"
        sudo chmod 0644 "$CONFIG_DIR/thermal-guard.conf"
    fi
    sudo install -d -o "$(whoami)" -g "$(whoami)" -m 0755 /var/lib/travel-nas

    write_systemd_unit thermal-guard.service << 'EOF'
[Unit]
Description=Travel-NAS thermal guard tick
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/thermal-guard.py
EOF
    write_systemd_unit thermal-guard.timer << 'EOF'
[Unit]
Description=Run thermal-guard every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Unit=thermal-guard.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now thermal-guard.timer
); then
    mark_ok "THERMAL_GUARD" "every 1 min, default MODE=warn"
else
    mark_fail "THERMAL_GUARD" "setup failed"
fi
