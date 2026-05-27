[[ -n "${DO_TG_LISTENER:-}" ]] || return 0

info "=== Telegram bot listener ==="
if [[ ! -f "$CONFIG_DIR/tg-notify.conf" ]]; then
    mark_fail "TG_LISTENER" "сначала настрой TG_NOTIFY (нужен токен бота)"
elif (
    set -e
    fetch_script "tg-listener.py" "$SCRIPT_DIR/tg-listener.py"

    write_systemd_unit tg-listener.service << EOF
[Unit]
Description=Travel-NAS Telegram bot listener
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
Group=$(whoami)
ExecStart=/usr/bin/python3 /usr/local/bin/tg-listener.py
Restart=always
RestartSec=10
StandardOutput=append:/mnt/t7/_logs/tg-listener.log
StandardError=append:/mnt/t7/_logs/tg-listener.log

[Install]
WantedBy=multi-user.target
EOF
    sudo install -d -o "$(whoami)" -g "$(whoami)" -m 0755 /var/lib/travel-nas
    sudo systemctl daemon-reload
    sudo systemctl enable --now tg-listener.service
); then
    mark_ok "TG_LISTENER" "/help в Telegram чтобы увидеть команды"
else
    mark_fail "TG_LISTENER" "systemd setup failed"
fi
