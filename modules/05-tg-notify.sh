[[ -n "${DO_TG_NOTIFY:-}" ]] || return 0

info "=== Telegram notifications ==="
if (
    set -e
    sudo mkdir -p "$CONFIG_DIR"
    fetch_script "tg-notify.sh" "$SCRIPT_DIR/tg-notify.sh"
    if [[ ! -f "$CONFIG_DIR/tg-notify.conf" ]]; then
        TG_TOKEN=$(whiptail --inputbox "Telegram bot token (от @BotFather):\nПусто = пропустить." 12 70 "" 3>&1 1>&2 2>&3) || TG_TOKEN=""
        TG_CHAT_ID=""
        if [[ -n "$TG_TOKEN" ]]; then
            TG_CHAT_ID=$(whiptail --inputbox "Telegram chat_id:" 10 70 "" 3>&1 1>&2 2>&3) || TG_CHAT_ID=""
        fi
        sudo tee "$CONFIG_DIR/tg-notify.conf" > /dev/null << EOF
TG_BOT_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
HOSTNAME_LABEL="Travel-NAS"
EOF
    fi
    # owner = $(whoami): тогда tg-notify.sh (запускается от oleg и от root) и
    # tg-listener.service (от oleg) могут читать/писать конфиг.
    sudo chown "$(whoami):$(whoami)" "$CONFIG_DIR/tg-notify.conf"
    sudo chmod 0640 "$CONFIG_DIR/tg-notify.conf"

    # Тестовое сообщение если уже есть креды
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/tg-notify.conf"
    if [[ -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]; then
        "$SCRIPT_DIR/tg-notify.sh" success "Travel-NAS setup" "Telegram настроен" || true
    fi
); then
    mark_ok "TG_NOTIFY"
else
    mark_fail "TG_NOTIFY" "config wizard failed"
fi
