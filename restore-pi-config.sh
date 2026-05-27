#!/bin/bash
# =============================================================================
# restore-pi-config.sh - Восстановление конфигов из бэкапа
# =============================================================================
# Запускать ПОСЛЕ:
#   1. Чистой установки Pi OS Desktop
#   2. Запуска setup.sh (создаёт юзеров, ставит ПО)
#   3. Монтирования T7 в /mnt/t7
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
    err "Не запускай через sudo!"
    exit 1
fi

if ! command -v whiptail &>/dev/null; then
    sudo apt-get install -y whiptail
fi

# === Поиск бэкапов ===

BACKUP_ROOT="${1%/}"

if [[ -z "$BACKUP_ROOT" ]]; then
    SEARCH_PATHS=(
        "/mnt/t7/pi-config-backups"
        "/mnt/nvme_target/pi-config-backups"
        "/media/nvme_target/pi-config-backups"
        "/home/$(whoami)/pi-config-backups"
    )

    FOUND_ROOT=""
    for path in "${SEARCH_PATHS[@]}"; do
        if [[ -d "$path" ]]; then
            FOUND_ROOT="$path"
            break
        fi
    done

    if [[ -z "$FOUND_ROOT" ]]; then
        err "Папка с бэкапами не найдена"
        for path in "${SEARCH_PATHS[@]}"; do
            err "  $path"
        done
        err ""
        err "Укажи путь: bash $0 /path/to/backup"
        exit 1
    fi

    info "Найдены бэкапы в: $FOUND_ROOT"

    BACKUPS=()
    while IFS= read -r dir; do
        if [[ -d "$dir" ]]; then
            DATE=$(basename "$dir")
            DESC=""
            if [[ -f "$dir/backup-info.txt" ]]; then
                HOST=$(grep "Hostname:" "$dir/backup-info.txt" 2>/dev/null | awk '{print $2}')
                DESC="$HOST"
            fi
            BACKUPS+=("$DATE" "$DESC")
        fi
    done < <(find "$FOUND_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        err "В $FOUND_ROOT нет бэкапов"
        exit 1
    fi

    SELECTED_DATE=$(whiptail \
        --title "Восстановление конфигов" \
        --menu "Выбери бэкап:" 20 70 10 \
        "${BACKUPS[@]}" \
        3>&1 1>&2 2>&3) || exit 0

    BACKUP_ROOT="$FOUND_ROOT/$SELECTED_DATE"
fi

if [[ ! -d "$BACKUP_ROOT" ]]; then
    err "Папка $BACKUP_ROOT не существует"
    exit 1
fi

info "Восстанавливаю из: $BACKUP_ROOT"

if [[ -f "$BACKUP_ROOT/backup-info.txt" ]]; then
    cat "$BACKUP_ROOT/backup-info.txt"
fi
echo ""

# === Меню что восстанавливать ===

MENU_OPTIONS=()
[[ -f "$BACKUP_ROOT/fstab" ]]               && MENU_OPTIONS+=("FSTAB"    "Восстановить /etc/fstab" ON)
[[ -d "$BACKUP_ROOT/samba" ]]               && MENU_OPTIONS+=("SAMBA"    "Восстановить /etc/samba/" ON)
[[ -d "$BACKUP_ROOT/network" ]]             && MENU_OPTIONS+=("NETWORK"  "Восстановить /etc/network/" OFF)
[[ -d "$BACKUP_ROOT/travel-nas" ]]          && MENU_OPTIONS+=("TRAVELNAS" "Восстановить /etc/travel-nas/" ON)
[[ -f "$BACKUP_ROOT/cmdline.txt" ]]         && MENU_OPTIONS+=("CMDLINE"  "Восстановить cmdline.txt" OFF)
[[ -f "$BACKUP_ROOT/config.txt" ]]          && MENU_OPTIONS+=("CONFIG"   "Восстановить config.txt" OFF)
[[ -d "$BACKUP_ROOT/scripts" ]]             && MENU_OPTIONS+=("SCRIPTS"  "Восстановить /usr/local/bin/" ON)
[[ -d "$BACKUP_ROOT/systemd" ]]             && MENU_OPTIONS+=("SYSTEMD"  "Восстановить systemd units" ON)
[[ -d "$BACKUP_ROOT/udev" ]]                && MENU_OPTIONS+=("UDEV"     "Восстановить udev rules" ON)
[[ -d "$BACKUP_ROOT/casaos" ]]              && MENU_OPTIONS+=("CASAOS"   "Восстановить CasaOS apps + db" ON)
[[ -d "$BACKUP_ROOT/casaos" ]]              && MENU_OPTIONS+=("CASAOSETC" "Восстановить /etc/casaos/" ON)
[[ -f "$BACKUP_ROOT/devmon.conf" ]]         && MENU_OPTIONS+=("DEVMON"   "Восстановить devmon config" ON)
[[ -f "$BACKUP_ROOT/installed-packages.txt" ]] && MENU_OPTIONS+=("PACKAGES" "Установить apt-пакеты" OFF)
[[ -f "$BACKUP_ROOT/crontab-root.txt" ]]    && MENU_OPTIONS+=("CRONROOT" "Восстановить root crontab" ON)

if [[ ${#MENU_OPTIONS[@]} -eq 0 ]]; then
    err "В бэкапе ничего нет"
    exit 1
fi

SELECTED=$(whiptail \
    --title "Что восстанавливать?" \
    --checklist "Выбери:" 25 78 14 \
    "${MENU_OPTIONS[@]}" \
    3>&1 1>&2 2>&3) || exit 0

if [[ -z "$SELECTED" ]]; then
    warn "Ничего не выбрано"
    exit 0
fi

for opt in $SELECTED; do
    opt_clean=$(echo "$opt" | tr -d '"')
    declare "DO_$opt_clean=1"
done

# === Подтверждение ===

warn "Текущие файлы будут перезаписаны (с резервной копией .before-restore-<timestamp>)"
echo "Продолжить? (y/N)"
read -r ans
[[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0

BACKUP_SUFFIX=".before-restore-$(date +%s)"

# === Функции восстановления ===

restore_file() {
    local src="$1"
    local dst="$2"
    if [[ ! -e "$src" ]]; then
        warn "Источник не найден: $src"
        return 1
    fi
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

# === Восстановление ===

[[ -n "${DO_FSTAB:-}" ]]     && restore_file "$BACKUP_ROOT/fstab" "/etc/fstab"
[[ -n "${DO_SAMBA:-}" ]]     && restore_dir  "$BACKUP_ROOT/samba" "/etc/samba"
[[ -n "${DO_NETWORK:-}" ]]   && restore_dir  "$BACKUP_ROOT/network" "/etc/network"
[[ -n "${DO_TRAVELNAS:-}" ]] && restore_dir  "$BACKUP_ROOT/travel-nas" "/etc/travel-nas"
[[ -n "${DO_CMDLINE:-}" ]]   && restore_file "$BACKUP_ROOT/cmdline.txt" "/boot/firmware/cmdline.txt"
[[ -n "${DO_CONFIG:-}" ]]    && restore_file "$BACKUP_ROOT/config.txt" "/boot/firmware/config.txt"

if [[ -n "${DO_SCRIPTS:-}" ]]; then
    for script in "$BACKUP_ROOT/scripts/"*; do
        if [[ -f "$script" ]]; then
            name=$(basename "$script")
            restore_file "$script" "/usr/local/bin/$name"
            sudo chmod +x "/usr/local/bin/$name"
        fi
    done
fi

if [[ -n "${DO_SYSTEMD:-}" ]]; then
    for unit in "$BACKUP_ROOT/systemd/"*; do
        if [[ -f "$unit" ]]; then
            name=$(basename "$unit")
            restore_file "$unit" "/etc/systemd/system/$name"
        fi
    done
    sudo systemctl daemon-reload
fi

if [[ -n "${DO_UDEV:-}" ]]; then
    for rule in "$BACKUP_ROOT/udev/"*; do
        if [[ -f "$rule" ]]; then
            name=$(basename "$rule")
            restore_file "$rule" "/etc/udev/rules.d/$name"
        fi
    done
    sudo udevadm control --reload-rules
fi

if [[ -n "${DO_CASAOS:-}" ]]; then
    if command -v casaos-cli &>/dev/null; then
        [[ -d "$BACKUP_ROOT/casaos/apps" ]] && restore_dir "$BACKUP_ROOT/casaos/apps" "/var/lib/casaos/apps"
        [[ -d "$BACKUP_ROOT/casaos/db" ]]   && restore_dir "$BACKUP_ROOT/casaos/db" "/var/lib/casaos/db"
        info "После CasaOS apps: sudo systemctl restart casaos casaos-gateway"
    else
        warn "CasaOS не установлен — пропускаю apps"
    fi
fi

[[ -n "${DO_CASAOSETC:-}" ]] && restore_dir "$BACKUP_ROOT/casaos" "/etc/casaos"
[[ -n "${DO_DEVMON:-}" ]]    && restore_file "$BACKUP_ROOT/devmon.conf" "/etc/conf.d/devmon"

if [[ -n "${DO_CRONROOT:-}" ]] && [[ -f "$BACKUP_ROOT/crontab-root.txt" ]]; then
    sudo crontab -l > "/tmp/crontab-root${BACKUP_SUFFIX}.txt" 2>/dev/null || true
    sudo crontab "$BACKUP_ROOT/crontab-root.txt"
    log "Root crontab восстановлен"
fi

if [[ -n "${DO_PACKAGES:-}" ]]; then
    warn "Установка пакетов ~10-30 минут"
    echo "Продолжить? (y/N)"
    read -r ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        sudo apt update
        sudo dpkg --set-selections < "$BACKUP_ROOT/installed-packages.txt"
        sudo apt-get -y dselect-upgrade || true
        log "Пакеты установлены"
    fi
fi

# === Финал ===

echo ""
echo "================================================================"
log "Восстановление завершено!"
echo "================================================================"
echo ""
info "Резервные копии в файлах с суффиксом: $BACKUP_SUFFIX"

NEEDS_REBOOT=""
[[ -n "${DO_CMDLINE:-}" || -n "${DO_CONFIG:-}" || -n "${DO_FSTAB:-}" || -n "${DO_DEVMON:-}" ]] && NEEDS_REBOOT="1"

if [[ -n "$NEEDS_REBOOT" ]]; then
    warn "Изменены критичные файлы — нужен ребут:"
    warn "  sudo reboot"
fi
[[ -n "${DO_SAMBA:-}" ]]  && info "Перезапустить: sudo systemctl restart smbd nmbd"
[[ -n "${DO_CASAOS:-}" ]] && info "Перезапустить: sudo systemctl restart casaos casaos-gateway"
echo ""
