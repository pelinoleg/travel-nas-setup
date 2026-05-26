#!/bin/bash
# =============================================================================
# setup-lbb.sh v2 - Travel-NAS на Raspberry Pi 5 + Little Backup Box
# =============================================================================
# Автор: для Олега, на базе совместной отладки в чате
# Цель: одной командой подготовить чистую Pi OS Desktop к работе как travel-NAS
#
# Использование:
#   bash setup-lbb.sh                 # интерактивное меню
#   bash setup-lbb.sh --all            # установить всё без вопросов
#   bash setup-lbb.sh --help           # справка
#
# Поддерживает повторный запуск — пропустит уже установленное.
# =============================================================================

set -e

# ----- Цвета для логов -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

# ----- Проверки -----
if [[ "$EUID" -eq 0 ]]; then
    err "Не запускай через sudo! Скрипт сам попросит sudo где нужно."
    exit 1
fi

if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
    warn "Не похоже на Raspberry Pi 5. Продолжить всё равно? (y/N)"
    read -r ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0
fi

# ----- Установка whiptail если нет -----
if ! command -v whiptail &>/dev/null; then
    info "Устанавливаю whiptail для меню..."
    sudo apt-get update -qq
    sudo apt-get install -y whiptail
fi

# =============================================================================
# Меню выбора компонентов
# =============================================================================

if [[ "$1" == "--all" ]]; then
    SELECTED="UPDATE PCIE USERS UTILS NVMEMOUNT LBB CASAOS SAMBA LOG2RAM ZRAM PIBACKUP LCD"
elif [[ "$1" == "--help" ]]; then
    sed -n '2,15p' "$0" | sed 's/^# //'
    exit 0
else
    SELECTED=$(whiptail \
        --title "Pi 5 Travel-NAS Setup" \
        --checklist "Что установить/настроить? (пробел = выбрать)" \
        25 78 14 \
        "UPDATE"    "Обновить систему" ON \
        "PCIE"      "Параметры NVMe + PCIe Gen 1 (критично!)" ON \
        "USERS"     "Создать юзера 'pi' (пароль hammett) для lbb" ON \
        "UTILS"     "Утилиты (htop, ncdu, tmux, git, nvme-cli...)" ON \
        "NVMEMOUNT" "Авто-монтирование NVMe через fstab" ON \
        "LBB"       "Установить Little Backup Box" ON \
        "CASAOS"    "Установить CasaOS (порт 100)" OFF \
        "SAMBA"     "SMB-шара (открытая, для домашней сети)" ON \
        "LOG2RAM"   "Log2ram (экономит microSD)" ON \
        "ZRAM"      "Тюнинг zram swap (4GB, swappiness=10)" ON \
        "PIBACKUP"  "Скрипт бэкапа конфига Pi" ON \
        "LCD"       "3.5\" экран MHS35 (ВНИМАНИЕ: ребутает в конце)" OFF \
        3>&1 1>&2 2>&3)

    if [[ -z "$SELECTED" ]]; then
        warn "Ничего не выбрано. Выход."
        exit 0
    fi
fi

# Преобразуем выбор в переменные DO_*
for opt in $SELECTED; do
    opt_clean=$(echo "$opt" | tr -d '"')
    declare "DO_$opt_clean=1"
done

# =============================================================================
# 1. Обновление системы
# =============================================================================

if [[ -n "$DO_UPDATE" ]]; then
    info "=== Обновление системы ==="
    sudo apt update
    sudo apt full-upgrade -y
    sudo apt autoremove -y
    log "Система обновлена"
fi

# =============================================================================
# 2. PCIe + NVMe параметры
# =============================================================================

if [[ -n "$DO_PCIE" ]]; then
    info "=== Настройка PCIe + NVMe ==="

    CMDLINE="/boot/firmware/cmdline.txt"
    CONFIG="/boot/firmware/config.txt"

    NVME_PARAMS="nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off"

    if ! grep -q "nvme_core.default_ps_max_latency_us=0" "$CMDLINE"; then
        sudo sed -i "1 s/\$/ $NVME_PARAMS/" "$CMDLINE"
        log "Добавлены NVMe-параметры в cmdline.txt"
    else
        info "NVMe-параметры в cmdline.txt уже есть"
    fi

    LINE_COUNT=$(wc -l < "$CMDLINE")
    if [[ "$LINE_COUNT" -gt 1 ]]; then
        err "cmdline.txt стал многострочным! Проверь вручную: sudo nano $CMDLINE"
        exit 1
    fi

    if ! grep -q "^dtparam=pciex1_gen=1" "$CONFIG"; then
        echo "" | sudo tee -a "$CONFIG" > /dev/null
        echo "# PCIe Gen 1 для стабильности NVMe (setup-lbb.sh)" | sudo tee -a "$CONFIG" > /dev/null
        echo "dtparam=pciex1_gen=1" | sudo tee -a "$CONFIG" > /dev/null
        log "Добавлен PCIe Gen 1 в config.txt"
    else
        info "PCIe Gen 1 в config.txt уже настроен"
    fi

    warn "PCIe-параметры применятся после ребута"
fi

# =============================================================================
# 3. Юзер pi
# =============================================================================

if [[ -n "$DO_USERS" ]]; then
    info "=== Юзеры ==="

    if id "pi" &>/dev/null; then
        info "Юзер pi уже существует"
    else
        sudo useradd -m -s /bin/bash -c "pi user" pi
        echo "pi:hammett" | sudo chpasswd
        log "Создан юзер pi (пароль hammett)"
    fi

    CURRENT_USER=$(whoami)
    GROUPS_LIST=$(groups "$CURRENT_USER" | cut -d: -f2 | tr ' ' ',' | sed 's/^,//' | sed "s/$CURRENT_USER,*//g" | sed 's/,,/,/g' | sed 's/^,\|,$//g')
    if [[ -n "$GROUPS_LIST" ]]; then
        sudo usermod -aG "$GROUPS_LIST" pi 2>/dev/null || true
    fi
    sudo usermod -aG sudo pi
    log "pi в нужных группах + sudo"
fi

# =============================================================================
# 4. Утилиты
# =============================================================================

if [[ -n "$DO_UTILS" ]]; then
    info "=== Утилиты ==="
    sudo apt install -y \
        htop ncdu tmux git curl wget \
        nvme-cli smartmontools \
        rsync tree jq unzip
    log "Утилиты установлены"
fi

# =============================================================================
# 5. Авто-монтирование NVMe через fstab
# =============================================================================
# Системное монтирование надёжнее чем через lbb или CasaOS:
#   - работает всегда, даже если lbb/CasaOS сломались
#   - монтирует ДО запуска lbb (lbb видит готовый путь)
#   - стандартный Linux способ, изучен и стабилен

if [[ -n "$DO_NVMEMOUNT" ]]; then
    info "=== Авто-монтирование NVMe ==="

    # Находим все NVMe-разделы
    NVME_PARTS=$(lsblk -rno NAME,SIZE,FSTYPE,LABEL /dev/nvme*n* 2>/dev/null | grep -E "p[0-9]" || true)

    if [[ -z "$NVME_PARTS" ]]; then
        warn "NVMe-разделов не найдено. Пропускаю."
    else
        # Формируем меню для whiptail
        MENU_ARGS=()
        while IFS= read -r line; do
            NAME=$(echo "$line" | awk '{print $1}')
            SIZE=$(echo "$line" | awk '{print $2}')
            FSTYPE=$(echo "$line" | awk '{print $3}')
            LABEL=$(echo "$line" | awk '{print $4}')
            DESC="${SIZE} ${FSTYPE:-no-fs} ${LABEL:-no-label}"
            MENU_ARGS+=("/dev/$NAME" "$DESC")
        done <<< "$NVME_PARTS"

        SELECTED_PART=$(whiptail \
            --title "Выбор NVMe-раздела" \
            --menu "Какой раздел монтировать в /media/nvme_target?" \
            18 70 8 \
            "${MENU_ARGS[@]}" \
            3>&1 1>&2 2>&3) || SELECTED_PART=""

        if [[ -n "$SELECTED_PART" ]]; then
            # Получаем UUID для надёжного монтирования
            UUID=$(sudo blkid -s UUID -o value "$SELECTED_PART")
            FSTYPE=$(sudo blkid -s TYPE -o value "$SELECTED_PART")

            if [[ -z "$UUID" || -z "$FSTYPE" ]]; then
                err "Не удалось получить UUID/FSTYPE для $SELECTED_PART"
                warn "Раздел отформатирован? Если нет — сначала отформатируй в ext4:"
                warn "  sudo mkfs.ext4 -L lbb-nvme $SELECTED_PART"
            else
                MOUNT_POINT="/media/nvme_target"
                sudo mkdir -p "$MOUNT_POINT"

                # Размонтируем если уже примонтировано в другом месте
                EXISTING_MOUNT=$(findmnt -n -o TARGET "$SELECTED_PART" 2>/dev/null || true)
                if [[ -n "$EXISTING_MOUNT" && "$EXISTING_MOUNT" != "$MOUNT_POINT" ]]; then
                    warn "$SELECTED_PART сейчас примонтирован в $EXISTING_MOUNT"
                    warn "Размонтировать и переключить на $MOUNT_POINT? (y/N)"
                    read -r ans
                    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
                        sudo umount "$EXISTING_MOUNT" || true
                    else
                        warn "Пропускаю переключение"
                        SELECTED_PART=""
                    fi
                fi

                if [[ -n "$SELECTED_PART" ]]; then
                    # Добавляем в fstab если ещё нет
                    if ! grep -q "$UUID" /etc/fstab; then
                        FSTAB_LINE="UUID=$UUID $MOUNT_POINT $FSTYPE defaults,nofail,noatime 0 2"
                        echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null
                        log "Добавлено в /etc/fstab: $FSTAB_LINE"
                    else
                        info "UUID $UUID уже в fstab"
                    fi

                    # Монтируем сейчас
                    sudo mount -a
                    if findmnt -n "$MOUNT_POINT" &>/dev/null; then
                        log "NVMe смонтирован в $MOUNT_POINT"

                        # Создаём подпапки для разных применений
                        sudo mkdir -p "$MOUNT_POINT/lbb-backups"
                        sudo mkdir -p "$MOUNT_POINT/casaos-data"
                        sudo mkdir -p "$MOUNT_POINT/photos"
                        sudo chmod 777 "$MOUNT_POINT/lbb-backups" "$MOUNT_POINT/photos"
                        log "Подпапки созданы: lbb-backups, casaos-data, photos"
                    else
                        err "Не удалось смонтировать. Проверь /etc/fstab вручную"
                    fi
                fi
            fi
        else
            warn "Раздел не выбран — пропускаю авто-монтирование"
        fi
    fi
fi

# =============================================================================
# 6. Заглушка rc.local (нужна для LCD-скрипта)
# =============================================================================

if [[ -n "$DO_LBB" || -n "$DO_LCD" ]]; then
    if [[ ! -f /etc/rc.local ]]; then
        info "Создаю заглушку /etc/rc.local..."
        sudo tee /etc/rc.local > /dev/null << 'RCEOF'
#!/bin/sh -e
exit 0
RCEOF
        sudo chmod +x /etc/rc.local
        log "/etc/rc.local создан"
    fi
fi

# =============================================================================
# 7. Little Backup Box
# =============================================================================

if [[ -n "$DO_LBB" ]]; then
    info "=== Little Backup Box ==="

    if [[ -d /var/www/little-backup-box ]]; then
        warn "lbb уже установлен. Для обновления:"
        warn "  branch='main'; curl -sSL https://raw.githubusercontent.com/outdoorbits/little-backup-box/\${branch}/install-little-backup-box.sh | bash -s -- \${branch}"
    else
        if ! id "pi" &>/dev/null; then
            err "lbb требует юзера 'pi'. Запусти скрипт с галочкой USERS."
            exit 1
        fi

        warn "Сейчас запустится установщик lbb (~15-30 минут)"
        warn "Рекомендую: backup mode = none, comitup = YES"
        echo "Нажми Enter для продолжения, Ctrl+C для отмены..."
        read -r

        cd ~
        branch='main'
        curl -sSL "https://raw.githubusercontent.com/outdoorbits/little-backup-box/${branch}/install-little-backup-box.sh" \
            | bash -s -- "${branch}" 2> ~/lbb-install-error.log || true

        if [[ -d /var/www/little-backup-box ]]; then
            log "lbb установлен!"
            info "Веб: http://lbb.local:8080 или https://lbb.local"
            info "Basic auth: lbb / <твой пароль>"
        else
            err "lbb установить не удалось. Смотри ~/lbb-install-error.log"
        fi
    fi
fi

# =============================================================================
# 8. CasaOS
# =============================================================================

if [[ -n "$DO_CASAOS" ]]; then
    info "=== CasaOS ==="

    if command -v casaos-cli &>/dev/null; then
        info "CasaOS уже установлен"
    else
        warn "CasaOS будет установлен. ~10 минут."
        echo "Нажми Enter для продолжения, Ctrl+C для отмены..."
        read -r

        curl -fsSL https://get.casaos.io | sudo bash || true

        if command -v casaos-cli &>/dev/null; then
            log "CasaOS установлен"
        else
            err "CasaOS установить не удалось"
        fi
    fi

    if command -v casaos-cli &>/dev/null; then
        CURRENT_PORT=$(sudo casaos-cli gateway port 2>/dev/null || echo "80")
        if [[ "$CURRENT_PORT" != "100" ]]; then
            sudo casaos-cli gateway port set 100 2>/dev/null || \
                warn "Не удалось сменить порт. Сделай вручную: sudo casaos-cli gateway port set 100"
            sudo systemctl restart casaos-gateway 2>/dev/null || true
            log "CasaOS на порту 100 → http://lbb.local:100"
        fi
    fi
fi

# =============================================================================
# 9. Samba (SMB-шара)
# =============================================================================
# Открытая шара /media/nvme_target для домашней сети
# Доступ с Mac: Finder → Cmd+K → smb://lbb.local
# Доступ с iPhone: Files → Browse → Connect to Server → smb://lbb.local

if [[ -n "$DO_SAMBA" ]]; then
    info "=== Samba (SMB-шара) ==="

    if ! command -v smbd &>/dev/null; then
        sudo apt install -y samba samba-common-bin
        log "Samba установлен"
    fi

    # Определяем что шарить
    if [[ -d /media/nvme_target ]]; then
        SHARE_PATH="/media/nvme_target"
    elif [[ -d /mnt/Kingston2TB ]]; then
        SHARE_PATH="/mnt/Kingston2TB"
    else
        SHARE_PATH="/home/$(whoami)/share"
        sudo mkdir -p "$SHARE_PATH"
        sudo chmod 777 "$SHARE_PATH"
        warn "NVMe не найден. Шара создана в $SHARE_PATH"
    fi

    SHARE_NAME="travel-nas"
    SMB_CONF="/etc/samba/smb.conf"

    if ! grep -q "^\[$SHARE_NAME\]" "$SMB_CONF" 2>/dev/null; then
        # Бэкап оригинального конфига
        if [[ ! -f "$SMB_CONF.original" ]]; then
            sudo cp "$SMB_CONF" "$SMB_CONF.original"
        fi

        # Добавляем шару (открытая, guest-доступ)
        sudo tee -a "$SMB_CONF" > /dev/null << EOF

[$SHARE_NAME]
   comment = Travel NAS storage
   path = $SHARE_PATH
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   create mask = 0666
   directory mask = 0777
   force user = nobody
   force group = nogroup
EOF

        # В глобальную секцию — разрешаем guest, если ещё не разрешено
        if ! grep -q "^   map to guest" "$SMB_CONF"; then
            sudo sed -i '/^\[global\]/a \   map to guest = Bad User' "$SMB_CONF"
        fi

        sudo systemctl restart smbd nmbd
        sudo systemctl enable smbd nmbd
        log "Samba настроен. Шара: \\\\lbb.local\\$SHARE_NAME"
        log "Путь: $SHARE_PATH"
        info "С Mac: Finder → Cmd+K → smb://lbb.local"
        info "С iPhone: Files → Browse → Servers → smb://lbb.local"
    else
        info "Шара $SHARE_NAME уже настроена"
    fi
fi

# =============================================================================
# 10. Log2ram (логи в RAM, экономит microSD)
# =============================================================================

if [[ -n "$DO_LOG2RAM" ]]; then
    info "=== Log2ram ==="

    if dpkg -l log2ram 2>/dev/null | grep -q "^ii"; then
        info "Log2ram уже установлен"
    else
        # Официальный install от azlux
        echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian/ bookworm main" \
            | sudo tee /etc/apt/sources.list.d/azlux.list > /dev/null
        sudo wget -O /usr/share/keyrings/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
        sudo apt update
        sudo apt install -y log2ram
        log "Log2ram установлен. Логи теперь в RAM."
        info "Размер настраивается в /etc/log2ram.conf (по умолчанию 40M, достаточно)"
    fi
fi

# =============================================================================
# 11. ZRAM swap тюнинг
# =============================================================================

if [[ -n "$DO_ZRAM" ]]; then
    info "=== ZRAM swap тюнинг ==="

    # У lbb по умолчанию zram 2GB. Увеличим до 4GB и понизим swappiness.
    # Это оптимально для бэкап-задач: меньше попыток свопить, больше места под burst.

    ZRAM_CONF="/etc/default/zramswap"

    if [[ -f "$ZRAM_CONF" ]]; then
        # Бэкап
        if [[ ! -f "$ZRAM_CONF.original" ]]; then
            sudo cp "$ZRAM_CONF" "$ZRAM_CONF.original"
        fi

        # Меняем размер на 4GB и алгоритм на zstd (быстрее lz4 на сжимаемых данных)
        sudo sed -i 's/^#*ALGO=.*/ALGO=zstd/' "$ZRAM_CONF"
        sudo sed -i 's/^#*PERCENT=.*/PERCENT=50/' "$ZRAM_CONF"
        sudo sed -i 's/^#*ALLOCATION=.*/ALLOCATION=512/' "$ZRAM_CONF"

        # swappiness=10 → swap используется только при нехватке RAM
        SYSCTL_FILE="/etc/sysctl.d/99-zram-tune.conf"
        if [[ ! -f "$SYSCTL_FILE" ]]; then
            sudo tee "$SYSCTL_FILE" > /dev/null << 'EOF'
# Тюнинг под travel-NAS / Pi 5 с zram
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
            sudo sysctl -p "$SYSCTL_FILE" >/dev/null
        fi
        log "ZRAM настроен (zstd, swappiness=10)"
    else
        warn "zramswap не установлен, пропускаю тюнинг"
    fi
fi

# =============================================================================
# 12. Скрипт еженедельного бэкапа конфига Pi
# =============================================================================
# Сохраняет важные файлы конфигурации в /media/nvme_target/pi-config-backups/
# Раз в неделю, через cron. Хранит последние 4 копии (~месяц).

if [[ -n "$DO_PIBACKUP" ]]; then
    info "=== Pi config backup ==="

    BACKUP_SCRIPT="/usr/local/bin/backup-pi-config.sh"

    sudo tee "$BACKUP_SCRIPT" > /dev/null << 'BACKEOF'
#!/bin/bash
# Еженедельный бэкап важных файлов конфигурации Pi.
# Запускается через cron, см. /etc/cron.weekly/

set -e

BACKUP_ROOT="/media/nvme_target/pi-config-backups"
DATE=$(date +%Y-%m-%d_%H-%M)
BACKUP_DIR="$BACKUP_ROOT/$DATE"

# Если NVMe не примонтирован — пишем в /home
if ! mountpoint -q /media/nvme_target; then
    BACKUP_ROOT="/home/$(logname 2>/dev/null || echo pi)/pi-config-backups"
    BACKUP_DIR="$BACKUP_ROOT/$DATE"
fi

mkdir -p "$BACKUP_DIR"

# Системные файлы
cp -r /etc/fstab          "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/samba          "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/network        "$BACKUP_DIR/" 2>/dev/null || true
cp -r /boot/firmware/cmdline.txt "$BACKUP_DIR/" 2>/dev/null || true
cp -r /boot/firmware/config.txt  "$BACKUP_DIR/" 2>/dev/null || true

# Конфиг lbb (если есть)
if [[ -d /var/www/little-backup-box ]]; then
    cp /var/www/little-backup-box/config.cfg "$BACKUP_DIR/lbb-config.cfg" 2>/dev/null || true
fi

# Список установленных пакетов
dpkg --get-selections > "$BACKUP_DIR/installed-packages.txt"

# Список docker-контейнеров CasaOS (если есть)
if command -v docker &>/dev/null; then
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
fi

# Cron jobs
crontab -l > "$BACKUP_DIR/crontab-$(whoami).txt" 2>/dev/null || true
sudo crontab -l > "$BACKUP_DIR/crontab-root.txt" 2>/dev/null || true

# Чистка старых бэкапов — оставляем 4 последних
cd "$BACKUP_ROOT"
ls -1t | tail -n +5 | xargs -r rm -rf

echo "Backup completed: $BACKUP_DIR"
BACKEOF

    sudo chmod +x "$BACKUP_SCRIPT"
    log "Создан $BACKUP_SCRIPT"

    # Cron — раз в неделю по воскресеньям в 03:00
    CRON_LINE="0 3 * * 0 $BACKUP_SCRIPT"
    if ! sudo crontab -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT"; then
        (sudo crontab -l 2>/dev/null; echo "$CRON_LINE") | sudo crontab -
        log "Cron-задача добавлена (воскресенье 03:00)"
    fi

    info "Чтобы запустить вручную: sudo $BACKUP_SCRIPT"
fi

# =============================================================================
# 13. 3.5" MHS35 экран
# =============================================================================

if [[ -n "$DO_LCD" ]]; then
    info "=== 3.5\" экран MHS35 ==="

    if [[ -d ~/LCD-show ]]; then
        warn "~/LCD-show уже существует. Переустановить? (y/N)"
        read -r ans
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            sudo rm -rf ~/LCD-show
        else
            DO_LCD=""
        fi
    fi

    if [[ -n "$DO_LCD" ]]; then
        ROTATION=$(whiptail \
            --title "Поворот экрана" \
            --menu "Угол поворота:" \
            15 60 4 \
            "0"   "Портрет" \
            "90"  "Ландшафт, USB справа" \
            "180" "Портрет, перевёрнутый" \
            "270" "Ландшафт, USB слева" \
            3>&1 1>&2 2>&3) || ROTATION="0"

        cd ~
        git clone https://github.com/goodtft/LCD-show.git
        chmod -R 755 LCD-show
        cd LCD-show

        warn "ВНИМАНИЕ: после установки система автоматически перезагрузится!"
        warn "Enter для продолжения, Ctrl+C для отмены..."
        read -r

        sudo "./MHS35-show" "$ROTATION"
        # Сюда не дойдём — ребут
    fi
fi

# =============================================================================
# Финал
# =============================================================================

echo ""
echo "================================================================"
log "Установка завершена!"
echo "================================================================"
echo ""

[[ -n "$DO_LBB" ]]     && info "Little Backup Box: http://lbb.local:8080"
[[ -n "$DO_CASAOS" ]]  && info "CasaOS:            http://lbb.local:100"
[[ -n "$DO_SAMBA" ]]   && info "Samba шара:        smb://lbb.local/travel-nas"
[[ -n "$DO_PCIE" ]]    && warn "PCIe/NVMe применятся ПОСЛЕ ребута"

echo ""
warn "Для применения всех изменений рекомендуется перезагрузка:"
warn "  sudo reboot"
echo ""
echo "Повторный запуск: bash setup-lbb.sh"
echo "Установить всё:   bash setup-lbb.sh --all"
echo ""