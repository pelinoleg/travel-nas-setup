#!/bin/bash
# =============================================================================
# restore-pi-config.sh - Восстановление конфигов из бэкапа backup-pi-config.sh
# =============================================================================
# Использование:
#   bash restore-pi-config.sh                  # интерактивный выбор
#   bash restore-pi-config.sh <путь_к_бэкапу>  # восстановить из конкретного
#
# Запускать ПОСЛЕ:
#   1. Чистой установки Pi OS
#   2. Запуска setup-lbb.sh (создаёт юзеров, ставит ПО)
#   3. Монтирования старого NVMe с бэкапами в /mnt/nvme_target
#
# Скрипт восстановит файлы конфигурации, но не данные приложений.
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

if [[ "$EUID" -eq 0 ]]; then
    err "Не запускай через sudo! Скрипт сам попросит sudo где нужно."
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    sudo apt-get install -y whiptail
fi

# =============================================================================
# Выбор бэкапа
# =============================================================================

BACKUP_ROOT="${1%/}"

if [[ -z "$BACKUP_ROOT" ]]; then
    # Ищем папку с бэкапами
    SEARCH_PATHS=(
        "/mnt/nvme_target/pi-config-backups"
        "/media/nvme_target/pi-config-backups"
        "/home/$(whoami)/pi-config-backups"
        "/home/pi/pi-config-backups"
        "/home/oleg/pi-config-backups"
    )

    FOUND_ROOT=""
    for path in "${SEARCH_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            FOUND_ROOT="$path"
            break
        fi
    done

    if [[ -z "$FOUND_ROOT" ]]; then
        err "Папка с бэкапами не найдена."
        err "Проверены пути:"
        for path in "${SEARCH_PATHS[@]}"; do
            err "  $path"
        done
        err ""
        err "Укажи путь вручную: bash $0 /path/to/backup"
        exit 1
    fi

    info "Найдены бэкапы в: $FOUND_ROOT"

    # Список доступных бэкапов
    BACKUPS=()
    while IFS= read -r dir; do
        if [[ -d "$dir" ]]; then
            DATE=$(basename "$dir")
            # Если есть backup-info.txt — добавим описание
            DESC=""
            if [[ -f "$dir/backup-info.txt" ]]; then
                HOST=$(grep "Hostname:" "$dir/backup-info.txt" | awk '{print $2}')
                DESC="$HOST"
            fi
            BACKUPS+=("$DATE" "$DESC")
        fi
    done < <(find "$FOUND_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        err "В $FOUND_ROOT нет бэкапов."
        exit 1
    fi

    SELECTED_DATE=$(whiptail \
        --title "Восстановление конфигов" \
        --menu "Выбери бэкап (новейшие сверху):" \
        20 70 10 \
        "${BACKUPS[@]}" \
        3>&1 1>&2 2>&3) || exit 0

    BACKUP_ROOT="$FOUND_ROOT/$SELECTED_DATE"
fi

if [[ ! -d "$BACKUP_ROOT" ]]; then
    err "Папка $BACKUP_ROOT не существует"
    exit 1
fi

info "Восстанавливаю из: $BACKUP_ROOT"
echo ""

# Покажем что внутри
if [[ -f "$BACKUP_ROOT/backup-info.txt" ]]; then
    cat "$BACKUP_ROOT/backup-info.txt"
    echo ""
fi

# =============================================================================
# Выбор что восстанавливать
# =============================================================================

# Подготовим меню в зависимости от того что есть в бэкапе
MENU_OPTIONS=()
[[ -f "$BACKUP_ROOT/fstab" ]]              && MENU_OPTIONS+=("FSTAB"    "Восстановить /etc/fstab" ON)
[[ -d "$BACKUP_ROOT/samba" ]]              && MENU_OPTIONS+=("SAMBA"    "Восстановить /etc/samba/" ON)
[[ -d "$BACKUP_ROOT/network" ]]            && MENU_OPTIONS+=("NETWORK"  "Восстановить /etc/network/" OFF)
[[ -f "$BACKUP_ROOT/cmdline.txt" ]]        && MENU_OPTIONS+=("CMDLINE"  "Восстановить /boot/firmware/cmdline.txt" ON)
[[ -f "$BACKUP_ROOT/config.txt" ]]         && MENU_OPTIONS+=("CONFIG"   "Восстановить /boot/firmware/config.txt" ON)
[[ -f "$BACKUP_ROOT/lbb-config.cfg" ]]     && MENU_OPTIONS+=("LBB"      "Восстановить lbb config.cfg" ON)
[[ -d "$BACKUP_ROOT/casaos" ]]             && MENU_OPTIONS+=("CASAOS"   "Восстановить CasaOS apps + db" ON)
[[ -d "$BACKUP_ROOT/casaos" ]]             && MENU_OPTIONS+=("CASAOSETC" "Восстановить /etc/casaos/" ON)
[[ -f "$BACKUP_ROOT/devmon.conf" ]]        && MENU_OPTIONS+=("DEVMON"   "Восстановить devmon (защита от CasaOS)" ON)
[[ -f "$BACKUP_ROOT/installed-packages.txt" ]] && MENU_OPTIONS+=("PACKAGES" "Установить недостающие apt-пакеты" OFF)
[[ -f "$BACKUP_ROOT/crontab-root.txt" ]]   && MENU_OPTIONS+=("CRONROOT" "Восстановить crontab root" ON)

if [[ ${#MENU_OPTIONS[@]} -eq 0 ]]; then
    err "В бэкапе нет ничего для восстановления"
    exit 1
fi

SELECTED=$(whiptail \
    --title "Что восстанавливать?" \
    --checklist "Выбери что нужно восстановить:" \
    25 78 14 \
    "${MENU_OPTIONS[@]}" \
    3>&1 1>&2 2>&3) || exit 0

if [[ -z "$SELECTED" ]]; then
    warn "Ничего не выбрано"
    exit 0
fi

# Преобразуем в DO_*
for opt in $SELECTED; do
    opt_clean=$(echo "$opt" | tr -d '"')
    declare "DO_$opt_clean=1"
done

# =============================================================================
# Подтверждение
# =============================================================================

warn "Сейчас будут перезаписаны выбранные системные файлы."
warn "На всякий случай оригиналы будут сохранены с суффиксом .before-restore"
echo ""
echo "Продолжить? (y/N)"
read -r ans
[[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0

BACKUP_SUFFIX=".before-restore-$(date +%s)"

# =============================================================================
# Восстановление
# =============================================================================

restore_file() {
    local src="$1"
    local dst="$2"

    if [[ ! -e "$src" ]]; then
        warn "Источник не найден: $src"
        return 1
    fi

    # Бэкап текущего файла если он есть
    if [[ -e "$dst" ]]; then
        sudo cp -a "$dst" "${dst}${BACKUP_SUFFIX}"
    fi

    sudo cp -a "$src" "$dst"
    log "Восстановлен $dst"
}

restore_dir() {
    local src="$1"
    local dst="$2"

    if [[ ! -d "$src" ]]; then
        warn "Источник не найден: $src"
        return 1
    fi

    if [[ -d "$dst" ]]; then
        sudo cp -a "$dst" "${dst}${BACKUP_SUFFIX}"
    fi

    sudo mkdir -p "$(dirname "$dst")"
    sudo cp -a "$src" "$dst"
    log "Восстановлена папка $dst"
}

[[ -n "$DO_FSTAB" ]]     && restore_file "$BACKUP_ROOT/fstab" "/etc/fstab"
[[ -n "$DO_SAMBA" ]]     && restore_dir  "$BACKUP_ROOT/samba" "/etc/samba"
[[ -n "$DO_NETWORK" ]]   && restore_dir  "$BACKUP_ROOT/network" "/etc/network"
[[ -n "$DO_CMDLINE" ]]   && restore_file "$BACKUP_ROOT/cmdline.txt" "/boot/firmware/cmdline.txt"
[[ -n "$DO_CONFIG" ]]    && restore_file "$BACKUP_ROOT/config.txt" "/boot/firmware/config.txt"

if [[ -n "$DO_LBB" ]]; then
    if [[ -d /var/www/little-backup-box ]]; then
        restore_file "$BACKUP_ROOT/lbb-config.cfg" "/var/www/little-backup-box/config.cfg"
    else
        warn "lbb не установлен — пропускаю восстановление lbb config"
    fi
fi

if [[ -n "$DO_CASAOS" ]]; then
    if command -v casaos-cli &>/dev/null; then
        if [[ -d "$BACKUP_ROOT/casaos/apps" ]]; then
            restore_dir "$BACKUP_ROOT/casaos/apps" "/var/lib/casaos/apps"
        fi
        if [[ -d "$BACKUP_ROOT/casaos/db" ]]; then
            restore_dir "$BACKUP_ROOT/casaos/db" "/var/lib/casaos/db"
        fi
        info "После восстановления CasaOS apps нужно перезапустить CasaOS:"
        info "  sudo systemctl restart casaos casaos-gateway casaos-app-management"
    else
        warn "CasaOS не установлен — пропускаю восстановление apps"
    fi
fi

[[ -n "$DO_CASAOSETC" ]] && restore_dir "$BACKUP_ROOT/casaos" "/etc/casaos"
[[ -n "$DO_DEVMON" ]]    && restore_file "$BACKUP_ROOT/devmon.conf" "/etc/conf.d/devmon"

if [[ -n "$DO_CRONROOT" ]]; then
    if [[ -f "$BACKUP_ROOT/crontab-root.txt" ]]; then
        sudo crontab -l > "/tmp/crontab-root${BACKUP_SUFFIX}.txt" 2>/dev/null || true
        sudo crontab "$BACKUP_ROOT/crontab-root.txt"
        log "Восстановлен root crontab (старый: /tmp/crontab-root${BACKUP_SUFFIX}.txt)"
    fi
fi

if [[ -n "$DO_PACKAGES" ]]; then
    info "Установка пакетов из списка..."
    warn "Это может занять 10-30 минут"
    echo "Продолжить? (y/N)"
    read -r ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        sudo apt update
        sudo dpkg --set-selections < "$BACKUP_ROOT/installed-packages.txt"
        sudo apt-get -y dselect-upgrade || warn "Часть пакетов не установилась — это нормально для пакетов другой версии"
        log "Пакеты установлены"
    fi
fi

# =============================================================================
# Финал
# =============================================================================

echo ""
echo "================================================================"
log "Восстановление завершено!"
echo "================================================================"
echo ""
info "Файлы перед восстановлением сохранены с суффиксом: $BACKUP_SUFFIX"
info "Если что-то сломалось — можешь откатиться вручную."
echo ""

NEEDS_REBOOT=""
[[ -n "$DO_CMDLINE" || -n "$DO_CONFIG" || -n "$DO_FSTAB" || -n "$DO_DEVMON" ]] && NEEDS_REBOOT="1"

if [[ -n "$NEEDS_REBOOT" ]]; then
    warn "Изменены критичные файлы (cmdline/config/fstab/devmon)."
    warn "Нужен ребут: sudo reboot"
fi

if [[ -n "$DO_SAMBA" ]]; then
    info "Перезапусти Samba: sudo systemctl restart smbd nmbd"
fi

if [[ -n "$DO_CASAOS" ]]; then
    info "Перезапусти CasaOS: sudo systemctl restart casaos casaos-gateway casaos-app-management"
fi

echo ""