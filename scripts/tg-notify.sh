#!/bin/bash
# =============================================================================
# tg-notify.sh - Единый helper для отправки уведомлений в Telegram
# =============================================================================
# Используется всеми скриптами travel-NAS для отправки уведомлений.
#
# Использование:
#   tg-notify "title" "message"                    # обычное (🟡)
#   tg-notify -l info "title" "message"            # тихое (🟢, можно копить в summary)
#   tg-notify -l critical "title" "message"        # критическое (🔴, повторяется)
#   tg-notify --append <type> "message"            # добавить в очередь daily summary
#
# Конфиг: /etc/travel-nas/tg-notify.conf
# =============================================================================

CONFIG="/etc/travel-nas/tg-notify.conf"
SUMMARY_QUEUE="/var/lib/travel-nas/summary-queue.txt"
LAST_CRITICAL="/var/lib/travel-nas/last-critical.txt"

# Загружаем конфиг
if [[ ! -f "$CONFIG" ]]; then
    echo "tg-notify: config not found at $CONFIG" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

# Проверка переменных
if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo "tg-notify: TG_BOT_TOKEN or TG_CHAT_ID not set in $CONFIG" >&2
    exit 1
fi

HOSTNAME_LABEL="${HOSTNAME_LABEL:-Travel-NAS}"

# Создаём папки если нет
mkdir -p "$(dirname "$SUMMARY_QUEUE")" 2>/dev/null

# Парсинг аргументов
LEVEL="normal"
APPEND_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--level)
            LEVEL="$2"
            shift 2
            ;;
        --append)
            APPEND_MODE=true
            LEVEL="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

TITLE="${1:-}"
MESSAGE="${2:-}"

if [[ -z "$TITLE" && -z "$MESSAGE" ]]; then
    echo "Usage: tg-notify [-l level] \"title\" \"message\"" >&2
    exit 1
fi

# Иконка по уровню
case "$LEVEL" in
    info)     ICON="🟢" ;;
    normal)   ICON="🟡" ;;
    critical) ICON="🔴" ;;
    success)  ICON="✅" ;;
    error)    ICON="❌" ;;
    warning)  ICON="⚠️" ;;
    *)        ICON="📢" ;;
esac

TIMESTAMP=$(date '+%d-%m-%Y %H:%M')

# Если режим --append: пишем в очередь summary, не отправляем сейчас
if $APPEND_MODE; then
    echo "${TIMESTAMP} ${ICON} ${TITLE}: ${MESSAGE}" >> "$SUMMARY_QUEUE"
    exit 0
fi

# Формируем сообщение
if [[ -n "$TITLE" && -n "$MESSAGE" ]]; then
    FULL_MSG="${ICON} *${TITLE}*
_${HOSTNAME_LABEL} · ${TIMESTAMP}_

${MESSAGE}"
else
    FULL_MSG="${ICON} ${TITLE}${MESSAGE}"
fi

# Отправка
RESPONSE=$(curl -s --max-time 10 \
    -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="${FULL_MSG}")

# Для critical — запоминаем чтобы повторить через час если проблема не исчезнет
if [[ "$LEVEL" == "critical" ]]; then
    echo "$(date +%s)|${TITLE}|${MESSAGE}" > "$LAST_CRITICAL"
fi

# Проверка успеха
if echo "$RESPONSE" | grep -q '"ok":true'; then
    exit 0
else
    echo "tg-notify error: $RESPONSE" >&2
    exit 1
fi
