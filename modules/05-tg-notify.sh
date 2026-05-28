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
            # === Auto-detect chat_id ===
            # Просим юзера написать боту → опрашиваем getUpdates с long-poll
            # → выдёргиваем chat.id из последнего message. Если за 30 сек не
            # пришло — fallback на manual input.
            whiptail --msgbox \
"Открой Telegram, найди своего бота и напиши ему /start

Жду 30 секунд — после этого подцеплю chat_id автоматически.
(Если уже писал боту раньше — заберу из существующих updates.)" \
                12 70

            # Drain старые updates (могут быть тестовые сообщения), получим offset
            # для long-poll'а. Но для нашей цели достаточно ВЗЯТЬ ЛЮБОЙ update
            # с chat.id. Пишем response в файл чтобы не корёжить через bash quoting.
            TG_TMP=$(mktemp)
            curl -s --max-time 35 \
                "https://api.telegram.org/bot$TG_TOKEN/getUpdates?timeout=30" \
                > "$TG_TMP" || true
            TG_CHAT_ID=$(python3 - "$TG_TMP" << 'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
if not d.get("ok") or not d.get("result"):
    sys.exit(0)
for upd in reversed(d["result"]):
    msg = upd.get("message") or upd.get("edited_message") or {}
    chat = msg.get("chat") or {}
    if "id" in chat:
        print(chat["id"])
        break
PYEOF
)
            rm -f "$TG_TMP"

            if [[ -n "$TG_CHAT_ID" ]]; then
                whiptail --msgbox "✓ Подцепил chat_id: $TG_CHAT_ID" 8 60
            else
                whiptail --msgbox \
"Не удалось подцепить chat_id автоматически (нет сообщений или token неверный).

Введи вручную на следующем шаге. Получить можно так:
1. https://api.telegram.org/bot<TOKEN>/getUpdates в браузере
2. Найди \"chat\":{\"id\":<число>}
3. Это число и есть chat_id." \
                    14 70
                TG_CHAT_ID=$(whiptail --inputbox "Telegram chat_id (можно пустым, настроишь позже):" 10 70 "" 3>&1 1>&2 2>&3) || TG_CHAT_ID=""
            fi
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
