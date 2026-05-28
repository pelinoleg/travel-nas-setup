#!/bin/bash
# =============================================================================
# travel-nas-update — обновление travel-NAS из GitHub
# =============================================================================
# Два режима:
#
#   travel-nas-update              — БЫСТРО (~30 сек). Только наши скрипты:
#     - Скачивает свежие .sh/.py из main-ветки в /usr/local/bin/
#     - Перезапускает tg-listener / dashboard
#     - Синхронизирует sudoers
#     - НЕ трогает apt / Docker / конфиги
#
#   travel-nas-update --full       — ПОЛНОЕ (~5-15 мин). Всё что выше плюс:
#     - apt-get update && upgrade (включая kernel и tailscale)
#     - docker compose pull + up -d по всем CasaOS-приложениям
#     - На случай надо ребутнуться сам не делает — печатает варнинг
#
#   travel-nas-update --help       — справка
#
# Что НИКОГДА не трогает (для этого — `travel-nas-setup`):
#   - /etc/travel-nas/ конфиги
#   - systemd units (создание новых)
#   - sudoers (создание файла; sync существующего — да)
#   - tmpfiles.d / NetworkManager dispatcher (создание; обновление кода — да)
# =============================================================================

set -u

# --- Парсинг аргументов -----------------------------------------------------
MODE="fast"
for arg in "$@"; do
    case "$arg" in
        --full) MODE="full" ;;
        --help|-h)
            cat << 'HELP'
travel-nas-update — обновление travel-NAS из GitHub

Использование:
  travel-nas-update              Быстро (~30 сек): тянет наши .sh/.py
                                 из GitHub, рестартит tg-listener / dashboard,
                                 sync sudoers. Не трогает apt / Docker.

  travel-nas-update --full       Полное (~5-15 мин): то же +
                                   apt-get update && upgrade -y
                                   docker compose pull && up -d (все CasaOS-апсы)
                                 Если kernel или systemd обновились — печатает
                                 предупреждение что нужен reboot.

  travel-nas-update --help       Эта справка.

Конфиги в /etc/travel-nas/ НИКОГДА не трогаются — для этого `travel-nas-setup`.

См. docs/UPDATE.md.
HELP
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg '$arg'. См. --help" >&2
            exit 2
            ;;
    esac
done

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
    [nas-verify.py]=/usr/local/bin/nas-verify.py
    [tg-listener.py]=/usr/local/bin/tg-listener.py
    [backup-progress-writer.py]=/usr/local/bin/backup-progress-writer.py
    [99-travel-nas-power]=/etc/NetworkManager/dispatcher.d/99-travel-nas-power
    [touch-calibrate.sh]=/usr/local/bin/touch-calibrate.sh
    [fast-shutdown.sh]=/usr/local/bin/fast-shutdown.sh
    [fast-reboot.sh]=/usr/local/bin/fast-reboot.sh
    [zzz-sysrq-fallback]=/usr/lib/systemd/system-shutdown/zzz-sysrq-fallback
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
        # systemd-run --uid=oleg создаёт transient unit с правильным cgroup и
        # сессией. Переживает SSH-disconnect (в отличие от прежнего
        # `nohup ... &; disown` — тот гасился если update запущен из ssh).
        # --unit=travel-nas-display-runtime: фиксированное имя, чтобы повторный
        # запуск не плодил unit-ов.
        # Stop+reset для повторного использования имени unit'а. Без этого
        # `systemd-run --unit=X` фейлит если X уже зарегистрирован (даже
        # inactive после exit'а).
        systemctl stop travel-nas-display-runtime 2>/dev/null || true
        systemctl reset-failed travel-nas-display-runtime 2>/dev/null || true
        if systemd-run --unit=travel-nas-display-runtime --uid="$USER_LOGIN" \
            --setenv=DISPLAY=:0 --setenv=XAUTHORITY="$USER_HOME/.Xauthority" \
            --setenv=HOME="$USER_HOME" \
            /usr/bin/python3 /usr/local/bin/travel-nas-display.py >/dev/null 2>&1; then
            RESTARTED+=("dashboard")
            echo "  ✓ dashboard (systemd-run as $USER_LOGIN)"
        else
            echo "  ✗ dashboard — systemd-run failed"
        fi
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
    "/usr/local/bin/travel-nas-update --full"
    "/usr/local/bin/power-mode.sh"
    "/usr/local/bin/set-led.sh"
    "/usr/local/bin/docker-mgr.sh"
    "/usr/sbin/comitup-cli"
    "/usr/bin/nmcli connection down *"
    "/usr/bin/systemctl reboot, /usr/bin/systemctl poweroff"
    "/usr/bin/systemctl restart comitup"
    "/usr/bin/systemctl stop nas-backup-runtime"
    "/usr/bin/systemctl start --no-block nas-verify.service"
    "/usr/local/bin/touch-calibrate.sh"
    "/usr/local/bin/fast-shutdown.sh"
    "/usr/local/bin/fast-reboot.sh"
    "/usr/sbin/smartctl"
    "/usr/bin/smbstatus"
    "/usr/bin/dmesg"
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

# =============================================================================
# Desktop shortcuts — самовосстановление если иконки не создались (например,
# модуль 20-desktop отрабатывал до того как был ~/Desktop)
# =============================================================================
DESKTOP_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [[ -n "$DESKTOP_USER" ]]; then
    USER_HOME_D="/home/$DESKTOP_USER"
    DESKTOP_DIR="$USER_HOME_D/Desktop"
    if [[ ! -d "$DESKTOP_DIR" ]]; then
        sudo -u "$DESKTOP_USER" mkdir -p "$DESKTOP_DIR"
    fi
    ADDED_ICONS=0
    if [[ ! -f "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop" ]]; then
        sudo -u "$DESKTOP_USER" tee "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop" >/dev/null << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Dashboard
Comment=Re-open the kiosk dashboard
Exec=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
Icon=display
Terminal=false
Categories=System;
EOF
        chmod +x "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop"
        ADDED_ICONS=$((ADDED_ICONS + 1))
    fi
    if [[ ! -f "$DESKTOP_DIR/Travel-NAS-Update.desktop" ]]; then
        sudo -u "$DESKTOP_USER" tee "$DESKTOP_DIR/Travel-NAS-Update.desktop" >/dev/null << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Update
Comment=Pull latest scripts from GitHub
Exec=lxterminal --geometry=100x30 -e bash -c "travel-nas-update; echo; echo 'Готово. Нажми Enter чтобы закрыть.'; read"
Icon=system-software-update
Terminal=false
Categories=System;
EOF
        chmod +x "$DESKTOP_DIR/Travel-NAS-Update.desktop"
        ADDED_ICONS=$((ADDED_ICONS + 1))
    fi
    if (( ADDED_ICONS > 0 )); then
        echo ""
        echo "→ Восстановил $ADDED_ICONS ярлык(а) на ~/Desktop"
        # Перечитать рабочий стол без релогина
        if sudo -u "$DESKTOP_USER" pgrep -x pcmanfm >/dev/null 2>&1; then
            sudo -u "$DESKTOP_USER" -H env DISPLAY=:0 pcmanfm --reconfigure 2>/dev/null || true
        fi
    fi
fi

# =============================================================================
# --full режим: apt upgrade + docker pull/up. Запускается ПОСЛЕ обновления
# наших скриптов, чтобы свежий docker-mgr.sh использовать.
# =============================================================================
APT_UPGRADED=0
DOCKER_UPDATED=0
REBOOT_NEEDED=0
if [[ "$MODE" == "full" ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  --full: apt upgrade + docker pull/up"
    echo "═══════════════════════════════════════════════════"

    # --- apt upgrade ---
    echo ""
    echo "→ apt-get update..."
    if DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tail -3; then
        echo ""
        echo "→ apt-get upgrade (это может занять несколько минут)..."
        # -y: автоматическое подтверждение
        # -o Dpkg::Options::="--force-confdef --force-confold": сохраняем
        #     старые конфиги при конфликте (наши /etc/travel-nas/ не трогаются
        #     apt'ом, но какой-нибудь sshd_config мог быть отредактирован вручную)
        if UPG=$(DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" 2>&1); then
            APT_UPGRADED=$(echo "$UPG" | grep -cE "^Setting up " || true)
            echo "  ✓ $APT_UPGRADED packages upgraded"
        else
            echo "  ✗ apt-get upgrade failed"
            echo "$UPG" | tail -10
        fi
        # Проверка нужен ли ребут (после kernel/libc/etc)
        if [[ -f /var/run/reboot-required ]]; then
            REBOOT_NEEDED=1
            echo "  ⚠ /var/run/reboot-required: нужен reboot для применения"
        fi
    else
        echo "  ✗ apt-get update failed (нет интернета?)"
    fi

    # --- docker compose pull/up ---
    # CasaOS хранит приложения в /var/lib/casaos/apps/<name>/docker-compose.yml.
    # Идём по каждому и pull/up -d. Контейнеры с last-pulled-image не перезапустятся.
    if command -v docker &>/dev/null && [[ -d /var/lib/casaos/apps ]]; then
        echo ""
        echo "→ Docker (CasaOS apps): pull + up -d..."
        for compose in /var/lib/casaos/apps/*/docker-compose.yml; do
            [[ -f "$compose" ]] || continue
            app_name=$(basename "$(dirname "$compose")")
            echo "  • $app_name"
            if docker compose -f "$compose" pull --quiet 2>&1 | tail -2 | sed 's/^/    /'; then
                if docker compose -f "$compose" up -d 2>&1 | tail -2 | sed 's/^/    /'; then
                    DOCKER_UPDATED=$((DOCKER_UPDATED + 1))
                else
                    echo "    ✗ up -d failed"
                fi
            else
                echo "    ✗ pull failed"
            fi
        done
        # Очистка старых образов (могут весить десятки GB на CasaOS)
        if docker image prune -f 2>&1 | tail -1 | sed 's/^/  /'; then
            :
        fi
        echo "  ✓ $DOCKER_UPDATED apps updated"
    else
        echo ""
        echo "→ Docker не установлен / нет CasaOS apps — пропуск"
    fi
fi

echo ""
echo "Done. Configs in /etc/travel-nas/ untouched."
if [[ ${#RESTARTED[@]} -gt 0 ]]; then
    echo "Restarted: ${RESTARTED[*]}"
fi
if (( REBOOT_NEEDED )); then
    echo ""
    echo "⚠ Нужен reboot (kernel / systemd / иной критичный пакет обновился)."
    echo "  Выполни: sudo reboot — когда удобно."
fi

# Marker для tg-listener: он переживёт собственный рестарт (запущен через
# Popen start_new_session=True) и на следующем старте увидит /tmp/...done →
# пришлёт "✅ Update done" в Telegram. Так юзер получает обратную связь
# несмотря на то что вызывающий бот был перезапущен этим же скриптом.
{
    echo "$OK ok / $((OK + FAIL)) fetched, sudoers +${ADDED:-0}"
    if [[ "$MODE" == "full" ]]; then
        echo "apt: $APT_UPGRADED upgraded, docker: $DOCKER_UPDATED apps"
        (( REBOOT_NEEDED )) && echo "REBOOT_NEEDED"
    fi
} > /tmp/travel-nas-update.done
