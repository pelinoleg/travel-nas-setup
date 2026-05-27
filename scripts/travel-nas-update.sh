#!/bin/bash
# =============================================================================
# travel-nas-update — быстрое обновление наших скриптов из GitHub
# =============================================================================
# Что делает:
#   - Cкачивает свежие .sh/.py из main-ветки в /usr/local/bin/
#   - Перезапускает tg-listener.service если бежит
#   - Перезапускает dashboard если бежит
#
# Что НЕ делает (для этого — `travel-nas-setup`):
#   - Не трогает /etc/travel-nas/ конфиги
#   - Не пересоздаёт systemd units
#   - Не лезет в sudoers / tmpfiles.d / NetworkManager
#   - Не ставит apt-пакеты
#   - Не трогает Docker
#
# Использование:
#   travel-nas-update
# =============================================================================

set -u

# Самопродвижение в root: если не root — re-exec через sudo. Так и tg-listener
# (NOPASSWD: travel-nas-update), и интерактивный юзер (sudo prompts in tty) —
# оба попадут в одну и ту же ветку без необходимости разруливать sudo внутри.
if [[ "$EUID" -ne 0 ]]; then
    if [[ -t 0 ]]; then
        exec sudo -- "$0" "$@"
    fi
    echo "ERROR: must run as root (или через sudo с tty)" >&2
    exit 1
fi

REPO_RAW="https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main"

# Пары: src-имя-в-репо  →  target-путь на устройстве
declare -A SCRIPTS=(
    [tg-notify.sh]=/usr/local/bin/tg-notify.sh
    [photo-backup.sh]=/usr/local/bin/photo-backup.sh
    [nas-backup.sh]=/usr/local/bin/nas-backup.sh
    [pi-config-backup.sh]=/usr/local/bin/pi-config-backup.sh
    [disk-watchdog.sh]=/usr/local/bin/disk-watchdog.sh
    [system-monitor.sh]=/usr/local/bin/system-monitor.sh
    [daily-summary.sh]=/usr/local/bin/daily-summary.sh
    [set-led.sh]=/usr/local/bin/set-led.sh
    [power-mode.sh]=/usr/local/bin/power-mode.sh
    [docker-mgr.sh]=/usr/local/bin/docker-mgr.sh
    [travel-nas-setup.sh]=/usr/local/bin/travel-nas-setup
    [travel-nas-update.sh]=/usr/local/bin/travel-nas-update
    [travel-nas-display.py]=/usr/local/bin/travel-nas-display.py
    [nas-backup-status.py]=/usr/local/bin/nas-backup-status.py
    [tg-listener.py]=/usr/local/bin/tg-listener.py
    [backup-progress-writer.py]=/usr/local/bin/backup-progress-writer.py
)

# Cache-buster на случай если CDN отдаёт стейл
TS=$(date +%s)
OK=0; FAIL=0

echo "→ Fetching latest from $REPO_RAW (timestamp=$TS)..."
echo ""

for name in "${!SCRIPTS[@]}"; do
    target="${SCRIPTS[$name]}"
    tmp="${target}.tmp.$$"
    if curl -fsSL "$REPO_RAW/scripts/${name}?${TS}" -o "$tmp"; then
        mv "$tmp" "$target"
        chmod +x "$target"
        echo "  ✓ $target"
        OK=$((OK + 1))
    else
        rm -f "$tmp" 2>/dev/null
        echo "  ✗ $name — fetch failed"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Fetched: $OK ok, $FAIL failed"

# Перезапуск running сервисов чтоб подхватили новый код
RESTARTED=()
echo ""
echo "→ Restarting active services..."
for svc in tg-listener.service; do
    if systemctl is-active --quiet "$svc"; then
        if systemctl restart "$svc"; then
            RESTARTED+=("$svc")
            echo "  ✓ $svc"
        else
            echo "  ✗ $svc — restart failed"
        fi
    fi
done

# Dashboard — перезапуск только если бежит и есть X-сессия.
# Внутри скрипт root (после exec sudo), но dashboard должен бежать от юзера
# (его X-сессия). Берём оригинального юзера из SUDO_USER, fallback на logname.
USER_LOGIN="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
USER_HOME="/home/$USER_LOGIN"

if pgrep -f /usr/local/bin/travel-nas-display.py >/dev/null; then
    pkill -f /usr/local/bin/travel-nas-display.py 2>/dev/null || true
    sleep 1
    if [[ -n "$USER_LOGIN" && -e "$USER_HOME/.Xauthority" ]]; then
        # Дропаем привилегии обратно к юзеру и запускаем в его X
        sudo -u "$USER_LOGIN" -H \
            env DISPLAY=:0 XAUTHORITY="$USER_HOME/.Xauthority" \
            nohup /usr/bin/python3 /usr/local/bin/travel-nas-display.py \
            >/tmp/travel-nas-display.out 2>&1 &
        disown 2>/dev/null || true
        RESTARTED+=("dashboard")
        echo "  ✓ dashboard (as $USER_LOGIN)"
    else
        echo "  ⚠ нет X-сессии — dashboard поднимется при следующем логине"
    fi
fi

# =============================================================================
# Sync sudoers — каноничный список NOPASSWD-команд для dashboard/tg-listener
# =============================================================================
# Хранится здесь, в модуле 19-display и пересоздаётся при travel-nas-setup.
# travel-nas-update тоже проверяет каждую строку и доливает недостающие —
# иначе при добавлении новой возможности (новый скрипт) надо перезапускать
# setup wizard'а, что неудобно.
SUDOERS_FILE="/etc/sudoers.d/travel-nas-dashboard"
USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
[[ -z "$USER_NAME" ]] && USER_NAME="oleg"

REQUIRED_CMDS=(
    "/usr/local/bin/nas-backup.sh"
    "/usr/local/bin/nas-backup-status.py"
    "/usr/local/bin/daily-summary.sh"
    "/usr/local/bin/pi-config-backup.sh"
    "/usr/local/bin/travel-nas-update"
    "/usr/local/bin/power-mode.sh"
    "/usr/local/bin/set-led.sh"
    "/usr/local/bin/docker-mgr.sh"
    "/usr/bin/comitup-cli"
    "/usr/bin/nmcli connection down *"
    "/usr/bin/systemctl reboot, /usr/bin/systemctl poweroff"
    "/usr/bin/systemctl restart comitup"
    "/usr/sbin/smartctl"
    "/usr/bin/smbstatus"
)

if [[ -f "$SUDOERS_FILE" ]]; then
    echo ""
    echo "→ Syncing sudoers ($SUDOERS_FILE)..."
    BACKUP="${SUDOERS_FILE}.bak.$$"
    cp "$SUDOERS_FILE" "$BACKUP"
    ADDED=0
    for cmd in "${REQUIRED_CMDS[@]}"; do
        # Сравниваем по полному "NOPASSWD: $cmd" чтобы не путать с похожими
        if ! grep -qF "NOPASSWD: $cmd" "$SUDOERS_FILE"; then
            echo "$USER_NAME ALL=(root) NOPASSWD: $cmd" >> "$SUDOERS_FILE"
            echo "  + $cmd"
            ADDED=$((ADDED + 1))
        fi
    done
    if (( ADDED > 0 )); then
        if visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
            echo "  ✓ added $ADDED entries, syntax OK"
            rm -f "$BACKUP"
        else
            echo "  ✗ sudoers invalid после правки — откатываюсь"
            mv "$BACKUP" "$SUDOERS_FILE"
        fi
    else
        echo "  ✓ already in sync"
        rm -f "$BACKUP"
    fi
fi

echo ""
echo "Done. Configs in /etc/travel-nas/ untouched."
if [[ ${#RESTARTED[@]} -gt 0 ]]; then
    echo "Restarted: ${RESTARTED[*]}"
fi

# Marker для tg-listener: он переживёт собственный рестарт (запущен через
# Popen start_new_session=True) и на следующем старте увидит /tmp/...done →
# пришлёт "✅ Update done" в Telegram. Так юзер получает обратную связь
# несмотря на то что вызывающий бот был перезапущен этим же скриптом.
echo "$OK ok / $((OK + FAIL)) fetched, sudoers +${ADDED:-0}" > /tmp/travel-nas-update.done
