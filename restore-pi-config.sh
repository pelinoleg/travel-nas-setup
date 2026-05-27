#!/bin/bash
# =============================================================================
# restore-pi-config.sh - Восстановление конфигов из бэкапа pi-config-backup.sh
# =============================================================================
# Запускать ПОСЛЕ:
#   1. Чистой установки PiOS Desktop
#   2. travel-nas-setup (создаёт юзера, ставит ПО)
#   3. Монтирования T7 (T7_MOUNT блок)
#
# Использование:
#   bash restore-pi-config.sh                       # auto-find в /mnt/t7/pi-config-backups
#   bash restore-pi-config.sh /path/to/backup       # из конкретной папки
#
# Бэкапы имеют зеркальную структуру:
#   $BACKUP_ROOT/etc/fstab               → /etc/fstab
#   $BACKUP_ROOT/usr/local/bin/foo       → /usr/local/bin/foo
#   $BACKUP_ROOT/home/oleg/Desktop       → /home/oleg/Desktop
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

# =============================================================================
# Поиск backup-папки
# =============================================================================
BACKUP_ROOT="${1%/}"

if [[ -z "$BACKUP_ROOT" ]]; then
    SEARCH_PATHS=(
        "/mnt/t7/pi-config-backups"
        "/home/$(whoami)/pi-config-backups"
    )
    FOUND_ROOT=""
    for p in "${SEARCH_PATHS[@]}"; do
        [[ -d "$p" ]] && { FOUND_ROOT="$p"; break; }
    done

    if [[ -z "$FOUND_ROOT" ]]; then
        err "Папка с бэкапами не найдена. Искал:"
        printf '  %s\n' "${SEARCH_PATHS[@]}"
        err ""
        err "Укажи путь: bash $0 /path/to/backup"
        exit 1
    fi

    info "Найдены бэкапы в: $FOUND_ROOT"

    BACKUPS=()
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        DATE=$(basename "$dir")
        DESC=""
        [[ -f "$dir/backup-info.txt" ]] && \
            DESC=$(grep "Hostname:" "$dir/backup-info.txt" 2>/dev/null | awk '{print $2}')
        BACKUPS+=("$DATE" "${DESC:-?}")
    done < <(find "$FOUND_ROOT" -maxdepth 1 -mindepth 1 -type d | sort -r)

    if [[ ${#BACKUPS[@]} -eq 0 ]]; then
        err "В $FOUND_ROOT нет бэкапов"
        exit 1
    fi

    SELECTED_DATE=$(whiptail --title "Выбери бэкап" \
        --menu "Какой использовать:" 20 70 10 "${BACKUPS[@]}" \
        3>&1 1>&2 2>&3) || exit 0
    BACKUP_ROOT="$FOUND_ROOT/$SELECTED_DATE"
fi

if [[ ! -d "$BACKUP_ROOT" ]]; then
    err "Папка $BACKUP_ROOT не существует"
    exit 1
fi

info "Restore из: $BACKUP_ROOT"
[[ -f "$BACKUP_ROOT/backup-info.txt" ]] && cat "$BACKUP_ROOT/backup-info.txt"
echo ""

# =============================================================================
# Меню что восстанавливать
# =============================================================================
# Категории: проверяем наличие на бэкапе и предлагаем по дефолту критичные.
MENU=()
[[ -d "$BACKUP_ROOT/etc/travel-nas"      ]] && MENU+=("TRAVELNAS"  "/etc/travel-nas/ (КРИТИЧНО — токены, пароли)" ON)
[[ -d "$BACKUP_ROOT/usr/local/bin"       ]] && MENU+=("SCRIPTS"    "/usr/local/bin/ (наши скрипты)" ON)
[[ -d "$BACKUP_ROOT/etc/systemd/system"  ]] && MENU+=("SYSTEMD"    "systemd units" ON)
[[ -d "$BACKUP_ROOT/etc/sudoers.d"       ]] && MENU+=("SUDOERS"    "/etc/sudoers.d/travel-nas-dashboard" ON)
[[ -d "$BACKUP_ROOT/etc/tmpfiles.d"      ]] && MENU+=("TMPFILES"   "/etc/tmpfiles.d/travel-nas.conf" ON)
[[ -d "$BACKUP_ROOT/etc/NetworkManager"  ]] && MENU+=("NMDISP"     "NetworkManager dispatcher (power-mode)" ON)
[[ -d "$BACKUP_ROOT/etc/udev"            ]] && MENU+=("UDEV"       "/etc/udev/rules.d/99-photo-backup.rules" ON)
[[ -f "$BACKUP_ROOT/etc/motd"            ]] && MENU+=("MOTD"       "/etc/motd (SSH-баннер)" ON)
[[ -f "$BACKUP_ROOT/etc/fstab"           ]] && MENU+=("FSTAB"      "/etc/fstab" ON)
[[ -d "$BACKUP_ROOT/etc/samba"           ]] && MENU+=("SAMBA"      "/etc/samba/" ON)
[[ -f "$BACKUP_ROOT/etc/hosts"           ]] && MENU+=("HOSTS"      "/etc/hosts" OFF)
[[ -f "$BACKUP_ROOT/etc/hostname"        ]] && MENU+=("HOSTNAME"   "/etc/hostname" OFF)
[[ -d "$BACKUP_ROOT/etc/network"         ]] && MENU+=("NETWORK"    "/etc/network/" OFF)
[[ -d "$BACKUP_ROOT/etc/casaos"          ]] && MENU+=("CASAOSETC"  "/etc/casaos/" ON)
[[ -d "$BACKUP_ROOT/etc/conf.d"          ]] && MENU+=("DEVMON"     "/etc/conf.d/devmon" ON)
[[ -d "$BACKUP_ROOT/var/lib/casaos"      ]] && MENU+=("CASAOSAPPS" "/var/lib/casaos/apps + db" ON)
[[ -f "$BACKUP_ROOT/opt/photoview/docker-compose.yml" ]] && MENU+=("PHOTOVIEW" "/opt/photoview/ (Photoview compose)" ON)
[[ -d "$BACKUP_ROOT/home"                ]] && MENU+=("USERHOME"   "~/.config (autostart/lxsession/pcmanfm) + ~/Desktop" ON)
[[ -d "$BACKUP_ROOT/var/lib/travel-nas"  ]] && MENU+=("STATE"      "/var/lib/travel-nas/summary-queue.txt" OFF)
[[ -d "$BACKUP_ROOT/boot"                ]] && MENU+=("BOOT"       "/boot/firmware/cmdline.txt + config.txt" OFF)
[[ -f "$BACKUP_ROOT/crontab-root.txt"    ]] && MENU+=("CRONROOT"   "Root crontab (Pi-config-backup еженедельно)" ON)
[[ -f "$BACKUP_ROOT/installed-packages.txt" ]] && MENU+=("PACKAGES" "apt-пакеты из списка (10-30 мин)" OFF)

if [[ ${#MENU[@]} -eq 0 ]]; then
    err "В бэкапе нет ничего узнаваемого"
    exit 1
fi

SELECTED=$(whiptail --title "Что восстанавливать?" \
    --checklist "Выбери:" 26 80 18 "${MENU[@]}" \
    3>&1 1>&2 2>&3) || exit 0
[[ -z "$SELECTED" ]] && { warn "Ничего не выбрано"; exit 0; }

for opt in $SELECTED; do
    declare "DO_$(echo "$opt" | tr -d '"')=1"
done

# =============================================================================
# Подтверждение
# =============================================================================
warn "Текущие файлы будут перезаписаны (с резервной копией .before-restore-<ts>)"
echo "Продолжить? (y/N)"; read -r ans
[[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0

BACKUP_SUFFIX=".before-restore-$(date +%s)"

# =============================================================================
# Helpers
# =============================================================================
# Скопировать src → dst, сохранив старое в dst.before-restore-<ts>
restore_to() {
    local src="$1" dst="$2"
    if [[ ! -e "$src" ]]; then
        warn "Источник не найден: $src"
        return 1
    fi
    if [[ -e "$dst" ]]; then
        sudo cp -a "$dst" "${dst}${BACKUP_SUFFIX}" 2>/dev/null || true
    fi
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp -a "$src" "$dst"
    log "✓ $dst"
}

# Скопировать всё содержимое src/ → dst/ (рекурсивно с сохранением)
restore_tree() {
    local src="$1" dst="$2"
    if [[ ! -d "$src" ]]; then
        warn "Источник не найден: $src"
        return 1
    fi
    if [[ -e "$dst" ]]; then
        sudo cp -a "$dst" "${dst}${BACKUP_SUFFIX}" 2>/dev/null || true
    fi
    sudo mkdir -p "$dst"
    sudo cp -a "$src/." "$dst/"
    log "✓ $dst/"
}

# =============================================================================
# Применение
# =============================================================================
[[ -n "${DO_TRAVELNAS:-}" ]]  && restore_tree "$BACKUP_ROOT/etc/travel-nas"    "/etc/travel-nas"
[[ -n "${DO_SCRIPTS:-}" ]]    && restore_tree "$BACKUP_ROOT/usr/local/bin"    "/usr/local/bin"
[[ -n "${DO_SYSTEMD:-}" ]]    && { restore_tree "$BACKUP_ROOT/etc/systemd/system" "/etc/systemd/system"; sudo systemctl daemon-reload; }
[[ -n "${DO_SUDOERS:-}" ]]    && {
    restore_to "$BACKUP_ROOT/etc/sudoers.d/travel-nas-dashboard" "/etc/sudoers.d/travel-nas-dashboard"
    sudo chmod 0440 /etc/sudoers.d/travel-nas-dashboard
    sudo visudo -c -f /etc/sudoers.d/travel-nas-dashboard >/dev/null || warn "sudoers invalid!"
}
[[ -n "${DO_TMPFILES:-}" ]]   && {
    restore_to "$BACKUP_ROOT/etc/tmpfiles.d/travel-nas.conf" "/etc/tmpfiles.d/travel-nas.conf"
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/travel-nas.conf 2>/dev/null || true
}
[[ -n "${DO_NMDISP:-}" ]]     && {
    restore_to "$BACKUP_ROOT/etc/NetworkManager/dispatcher.d/99-travel-nas-power" \
               "/etc/NetworkManager/dispatcher.d/99-travel-nas-power"
    sudo chown root:root /etc/NetworkManager/dispatcher.d/99-travel-nas-power
    sudo chmod 0755 /etc/NetworkManager/dispatcher.d/99-travel-nas-power
}
[[ -n "${DO_UDEV:-}" ]]       && { restore_tree "$BACKUP_ROOT/etc/udev/rules.d" "/etc/udev/rules.d"; sudo udevadm control --reload-rules; }
[[ -n "${DO_MOTD:-}" ]]       && restore_to "$BACKUP_ROOT/etc/motd"      "/etc/motd"
[[ -n "${DO_FSTAB:-}" ]]      && restore_to "$BACKUP_ROOT/etc/fstab"     "/etc/fstab"
[[ -n "${DO_SAMBA:-}" ]]      && restore_tree "$BACKUP_ROOT/etc/samba"   "/etc/samba"
[[ -n "${DO_HOSTS:-}" ]]      && restore_to "$BACKUP_ROOT/etc/hosts"     "/etc/hosts"
[[ -n "${DO_HOSTNAME:-}" ]]   && restore_to "$BACKUP_ROOT/etc/hostname"  "/etc/hostname"
[[ -n "${DO_NETWORK:-}" ]]    && restore_tree "$BACKUP_ROOT/etc/network" "/etc/network"
[[ -n "${DO_CASAOSETC:-}" ]]  && restore_tree "$BACKUP_ROOT/etc/casaos"  "/etc/casaos"
[[ -n "${DO_DEVMON:-}" ]]     && restore_to "$BACKUP_ROOT/etc/conf.d/devmon" "/etc/conf.d/devmon"
[[ -n "${DO_PHOTOVIEW:-}" ]]  && {
    restore_to "$BACKUP_ROOT/opt/photoview/docker-compose.yml" "/opt/photoview/docker-compose.yml"
    info "Запусти Photoview: cd /opt/photoview && sudo docker compose up -d"
}
[[ -n "${DO_CASAOSAPPS:-}" ]] && {
    if command -v casaos-cli &>/dev/null; then
        [[ -d "$BACKUP_ROOT/var/lib/casaos/apps" ]] && restore_tree "$BACKUP_ROOT/var/lib/casaos/apps" "/var/lib/casaos/apps"
        [[ -d "$BACKUP_ROOT/var/lib/casaos/db" ]]   && restore_tree "$BACKUP_ROOT/var/lib/casaos/db" "/var/lib/casaos/db"
        info "Перезапусти CasaOS: sudo systemctl restart casaos casaos-gateway"
    else
        warn "CasaOS не установлен — пропускаю apps"
    fi
}
[[ -n "${DO_USERHOME:-}" ]]   && {
    USER_HOME="$BACKUP_ROOT/home"
    # Берём первого пользователя из бэкапа
    BACKUP_USER_HOME=$(find "$USER_HOME" -maxdepth 1 -mindepth 1 -type d | head -1)
    if [[ -n "$BACKUP_USER_HOME" ]]; then
        CURRENT_USER_HOME="/home/$(whoami)"
        for sub in .config/autostart .config/lxsession .config/pcmanfm Desktop; do
            [[ -e "$BACKUP_USER_HOME/$sub" ]] && restore_tree "$BACKUP_USER_HOME/$sub" "$CURRENT_USER_HOME/$sub"
        done
        # Возвращаем владельца на текущего юзера (могло быть другое имя в бэкапе)
        sudo chown -R "$(whoami):$(whoami)" "$CURRENT_USER_HOME/.config" "$CURRENT_USER_HOME/Desktop" 2>/dev/null || true
    fi
}
[[ -n "${DO_STATE:-}" ]]      && restore_to "$BACKUP_ROOT/var/lib/travel-nas/summary-queue.txt" "/var/lib/travel-nas/summary-queue.txt"
[[ -n "${DO_BOOT:-}" ]]       && {
    restore_to "$BACKUP_ROOT/boot/firmware/cmdline.txt" "/boot/firmware/cmdline.txt"
    restore_to "$BACKUP_ROOT/boot/firmware/config.txt"  "/boot/firmware/config.txt"
}
[[ -n "${DO_CRONROOT:-}" ]] && [[ -f "$BACKUP_ROOT/crontab-root.txt" ]] && {
    sudo crontab -l > "/tmp/crontab-root${BACKUP_SUFFIX}.txt" 2>/dev/null || true
    sudo crontab "$BACKUP_ROOT/crontab-root.txt"
    log "✓ root crontab"
}
[[ -n "${DO_PACKAGES:-}" ]] && {
    warn "Установка пакетов ~10-30 минут"
    echo "Продолжить? (y/N)"; read -r ans
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        sudo apt-get update
        sudo dpkg --set-selections < "$BACKUP_ROOT/installed-packages.txt"
        sudo apt-get -y dselect-upgrade || true
        log "✓ apt пакеты"
    fi
}

# =============================================================================
# Финал
# =============================================================================
echo ""
echo "================================================================"
log "Восстановление завершено!"
echo "================================================================"
echo ""
info "Резервные копии в файлах с суффиксом: $BACKUP_SUFFIX"
echo ""

NEEDS_REBOOT=""
[[ -n "${DO_BOOT:-}" || -n "${DO_FSTAB:-}" || -n "${DO_DEVMON:-}" || -n "${DO_HOSTNAME:-}" ]] && NEEDS_REBOOT="1"
[[ -n "$NEEDS_REBOOT" ]] && { warn "Нужен ребут: sudo reboot"; }

[[ -n "${DO_SAMBA:-}" ]]      && info "sudo systemctl restart smbd nmbd"
[[ -n "${DO_CASAOSAPPS:-}" ]] && info "sudo systemctl restart casaos casaos-gateway"
[[ -n "${DO_SYSTEMD:-}" ]]    && info "Включить таймеры: sudo systemctl enable --now <unit>.timer"
echo ""
