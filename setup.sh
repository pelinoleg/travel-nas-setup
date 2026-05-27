#!/bin/bash
# =============================================================================
# setup.sh - Travel-NAS Setup orchestrator
# =============================================================================
# Цель: одной командой подготовить чистую PiOS Desktop к работе как travel-NAS.
#
# Использование:
#   bash setup.sh                # интерактивное whiptail-меню
#   bash setup.sh --all          # установить всё
#   bash setup.sh --help         # справка
#
# Архитектура:
#   setup.sh           — этот файл, парсит аргументы + запускает модули
#   lib/common.sh      — helpers (log, mark_ok/fail, wait_for_apt, fetch_*)
#   modules/NN-*.sh    — каждый компонент = отдельный source-файл
#
# Поддерживает повторный запуск — модули пропускают уже установленное.
# При запуске через curl|bash подкачивает lib/ и modules/ с GitHub в /tmp.
# =============================================================================

set -u

# Базовая константа для bootstrap'а — остальные определены в lib/common.sh
REPO_RAW="https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main"

# Цвета для bootstrap (до загрузки common.sh)
_RED='\033[0;31m'; _GRE='\033[0;32m'; _YEL='\033[1;33m'; _BLU='\033[0;34m'; _NC='\033[0m'
_log()  { echo -e "${_GRE}[OK]${_NC} $*"; }
_warn() { echo -e "${_YEL}[WARN]${_NC} $*"; }
_err()  { echo -e "${_RED}[ERR]${_NC} $*"; }
_info() { echo -e "${_BLU}[INFO]${_NC} $*"; }

# ----- Проверки -----
if [[ "$EUID" -eq 0 ]]; then
    _err "Не запускай через sudo! Скрипт сам попросит sudo где нужно."
    exit 1
fi

if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
    _warn "Не похоже на Raspberry Pi 5. Продолжить? (y/N)"
    read -r ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0
fi

# whiptail нужен для меню (если ещё нет — ставим)
if ! command -v whiptail &>/dev/null; then
    _info "Устанавливаю whiptail..."
    sudo apt-get update -qq
    sudo apt-get install -y whiptail
fi

# =============================================================================
# Bootstrap: находим lib/common.sh и modules/. Если запущены из git checkout —
# берём локально. Иначе подкачиваем с GitHub в /tmp.
# =============================================================================

# Список модулей в порядке выполнения (имена без расширения)
MODULES=(
    01-update
    02-utils
    03-hostname
    04-t7-mount
    05-tg-notify
    06-samba
    07-pi-backup
    08-photo-backup
    09-nas-backup
    10-watchdog
    11-sys-monitor
    11b-power-mode
    11c-tg-listener
    12-daily-sum
    13-log2ram
    14-zram
    15-comitup
    16-casaos
    17-photoview
    18-ytarchiver
    19-display
    20-desktop
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

if [[ -d "$REPO_ROOT/lib" && -d "$REPO_ROOT/modules" ]]; then
    _info "Запуск из локального чекаута: $REPO_ROOT"
    LIB_DIR="$REPO_ROOT/lib"
    MODULES_DIR="$REPO_ROOT/modules"
else
    _info "Запуск через curl|bash — подкачиваю lib/ и modules/ с GitHub..."
    TMP_BOOT="$(mktemp -d -t travel-nas-XXXXXX)"
    LIB_DIR="$TMP_BOOT/lib"
    MODULES_DIR="$TMP_BOOT/modules"
    mkdir -p "$LIB_DIR" "$MODULES_DIR"

    # lib/common.sh
    if ! curl -fsSL "$REPO_RAW/lib/common.sh" -o "$LIB_DIR/common.sh"; then
        _err "Не удалось скачать lib/common.sh"
        exit 1
    fi
    # modules/*.sh
    for m in "${MODULES[@]}"; do
        if ! curl -fsSL "$REPO_RAW/modules/${m}.sh" -o "$MODULES_DIR/${m}.sh"; then
            _err "Не удалось скачать modules/${m}.sh"
            exit 1
        fi
    done
    REPO_ROOT="$TMP_BOOT"
fi

# Загружаем общие хелперы. Они переопределят _log/_warn/etc на log/warn/etc.
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

# fetch_script / fetch_conf_example смотрят SETUP_REPO_ROOT для локальных файлов
export SETUP_REPO_ROOT="$REPO_ROOT"

# =============================================================================
# Меню выбора компонентов
# =============================================================================

ALL_COMPONENTS="UPDATE UTILS HOSTNAME T7_MOUNT TG_NOTIFY SAMBA PI_BACKUP \
PHOTO_BACKUP NAS_BACKUP WATCHDOG SYS_MONITOR POWER_MODE TG_LISTENER DAILY_SUM \
LOG2RAM ZRAM COMITUP CASAOS PHOTOVIEW YTARCHIVER DISPLAY DESKTOP"

if [[ "${1:-}" == "--all" ]]; then
    SELECTED="$ALL_COMPONENTS"
elif [[ "${1:-}" == "--help" ]]; then
    cat << EOF
Travel-NAS Setup

Usage:
  bash setup.sh           Interactive menu
  bash setup.sh --all     Install everything

Components:
  UPDATE         apt update + upgrade
  UTILS          htop, ncdu, tmux, git, smartmontools, exiftool, etc + travel-nas-setup shortcut
  HOSTNAME       Переименовать Pi в "travel-nas"
  T7_MOUNT       Mount внешнего диска в /mnt/t7 (wizard для форматирования)
  TG_NOTIFY      Telegram уведомления (helper)
  SAMBA          SMB share /mnt/t7
  PI_BACKUP      Еженедельный бэкап конфигов (воскр 03:00)
  PHOTO_BACKUP   Автобэкап SD/USB карт при подключении
  NAS_BACKUP     Manual бэкап с домашнего NAS
  WATCHDOG       Disk health monitor (5min timer)
  SYS_MONITOR    CPU/temp/throttling/microSD-wear monitor (5min)
  POWER_MODE     Авто power-профиль (home/field/emergency)
  TG_LISTENER    Двусторонний Telegram бот (/status /backup /logs etc)
  DAILY_SUM      Daily summary в Telegram (21:00) + JSON refresh 10мин
  LOG2RAM        Логи в RAM (microSD friendly)
  ZRAM           Сжатый swap
  COMITUP        Field WiFi AP-режим
  CASAOS         CasaOS (для Docker-приложений)
  PHOTOVIEW      Photo gallery (Docker, после CASAOS)
  YTARCHIVER     YouTube archiver (Docker, после CASAOS, UI на :8081)
  DISPLAY        MHS35 + Python dashboard (X11 kiosk)
  DESKTOP        Ярлыки на десктоп (Dashboard, Setup, T7 Files, ...)
EOF
    exit 0
else
    SELECTED=$(whiptail --title "Travel-NAS Setup" \
        --checklist "Что устанавливать? (Space — выбор, Enter — OK)" 30 80 24 \
        "UPDATE"       "apt update + upgrade"                              ON \
        "UTILS"        "Утилиты + travel-nas-setup команда + LED helper"  ON \
        "HOSTNAME"     "Переименовать в travel-nas"                       ON \
        "T7_MOUNT"     "Внешний диск → /mnt/t7 (wizard форматирования)"   ON \
        "TG_NOTIFY"    "Telegram уведомления"                             ON \
        "SAMBA"        "Samba шара /mnt/t7"                               ON \
        "PI_BACKUP"    "Еженедельный бэкап конфигов"                      ON \
        "PHOTO_BACKUP" "Автобэкап SD/USB карт"                            ON \
        "NAS_BACKUP"   "Бэкап с домашнего NAS"                            ON \
        "WATCHDOG"     "Disk watchdog (5 мин)"                            ON \
        "SYS_MONITOR"  "CPU/temp/throttle/SD-wear (5 мин)"                ON \
        "POWER_MODE"   "Авто power-профиль"                               ON \
        "TG_LISTENER"  "Telegram бот: /status /backup /logs /reboot"      ON \
        "DAILY_SUM"    "Daily summary (21:00) + JSON refresh"             ON \
        "LOG2RAM"      "Логи в RAM"                                       ON \
        "ZRAM"         "Сжатый swap"                                       ON \
        "COMITUP"      "Полевой WiFi AP"                                  ON \
        "CASAOS"       "CasaOS"                                           ON \
        "PHOTOVIEW"    "Photoview (нужен CASAOS)"                         ON \
        "YTARCHIVER"   "YT-Archiver (нужен CASAOS, :8081)"                ON \
        "DISPLAY"      "MHS35 + dashboard"                                ON \
        "DESKTOP"      "Ярлыки на десктоп"                                ON \
        3>&1 1>&2 2>&3) || exit 0
fi

# Преобразуем в DO_*
for opt in $SELECTED; do
    opt_clean=$(echo "$opt" | tr -d '"')
    declare "DO_$opt_clean=1"
done

# =============================================================================
# Загрузка модулей — каждый сам решит запускаться или нет (по DO_*)
# =============================================================================
for m in "${MODULES[@]}"; do
    mod_file="$MODULES_DIR/${m}.sh"
    if [[ -f "$mod_file" ]]; then
        # shellcheck source=/dev/null
        source "$mod_file"
    else
        warn "Модуль не найден: $mod_file"
    fi
done

# =============================================================================
# Финальный отчёт
# =============================================================================
echo ""
echo "================================================================"
echo "                    Установка завершена"
echo "================================================================"
echo ""

if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    log "Установлено успешно (${#INSTALLED[@]}):"
    for item in "${INSTALLED[@]}"; do
        echo "   ✓ $item"
    done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    err "Не удалось установить (${#FAILED[@]}):"
    for item in "${FAILED[@]}"; do
        echo "   ✗ $item"
    done
fi

echo ""
IP=$(hostname -I | awk '{print $1}')
echo "IP:       $IP"
echo "Hostname: $(hostname).local"

# Telegram-итог если бот настроен
if [[ -x /usr/local/bin/tg-notify.sh ]] && [[ -f /etc/travel-nas/tg-notify.conf ]]; then
    REPORT="Setup finished.

✅ Installed (${#INSTALLED[@]}):
$(printf '• %s\n' "${INSTALLED[@]}")"

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        REPORT+="

❌ Failed (${#FAILED[@]}):
$(printf '• %s\n' "${FAILED[@]}")"
    fi

    REPORT+="

IP: $IP
Hostname: $(hostname).local"

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        /usr/local/bin/tg-notify.sh -l warning "Setup finished with errors" "$REPORT" 2>/dev/null || true
    else
        /usr/local/bin/tg-notify.sh -l success "Setup complete" "$REPORT" 2>/dev/null || true
    fi
fi

# Рекомендация ребута если ставили hostname / display / kernel-modules
if [[ -n "${DO_HOSTNAME:-}" || -n "${DO_DISPLAY:-}" ]]; then
    echo ""
    warn "Рекомендуется ребут для применения hostname и других изменений:"
    warn "  sudo reboot"
fi

exit 0
