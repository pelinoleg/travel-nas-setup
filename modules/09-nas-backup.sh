[[ -n "${DO_NAS_BACKUP:-}" ]] || return 0

info "=== NAS backup ==="
if (
    set -e
    sudo mkdir -p "$CONFIG_DIR"
    if ! command -v sshpass &>/dev/null; then
        apt_install sshpass
    fi
    fetch_script "nas-backup.sh"        "$SCRIPT_DIR/nas-backup.sh"
    fetch_script "nas-backup-status.py" "$SCRIPT_DIR/nas-backup-status.py"

    # /var/lib/travel-nas (status JSONs) — oleg-owned для tg-listener offset etc
    sudo install -d -o "$(whoami)" -g "$(whoami)" -m 0755 /var/lib/travel-nas

    write_systemd_unit nas-backup-status.service << 'EOF'
[Unit]
Description=Refresh NAS-backup folder sizes/status
After=network.target

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/python3 /usr/local/bin/nas-backup-status.py
EOF
    write_systemd_unit nas-backup-status.timer << 'EOF'
[Unit]
Description=Hourly NAS-backup status refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Unit=nas-backup-status.service

[Install]
WantedBy=timers.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now nas-backup-status.timer

    if [[ ! -f "$CONFIG_DIR/nas-backup.conf" ]]; then
        # Дефолты для retry-loop'а
        NAS_HOST="192.168.1.95"; NAS_USER="oleg"; NAS_PASS=""
        while true; do
            NAS_HOST=$(whiptail --inputbox "NAS IP:" 10 60 "$NAS_HOST" 3>&1 1>&2 2>&3) || break
            NAS_USER=$(whiptail --inputbox "NAS user:" 10 60 "$NAS_USER" 3>&1 1>&2 2>&3) || break
            NAS_PASS=$(whiptail --passwordbox "NAS password:" 10 60 3>&1 1>&2 2>&3) || break

            # === Validate ===
            # 1) Reachability через ping (3 сек тайм-аут)
            if ! ping -c 1 -W 3 "$NAS_HOST" &>/dev/null; then
                if whiptail --yesno "Не отвечает $NAS_HOST.\nПопробовать другой адрес?" 10 60; then
                    continue
                fi
                break
            fi
            # 2) rsync daemon — sshpass + перечисление модулей. Если ошибка
            # аутентификации, видно из stderr ('auth failed' / '@ERROR: auth').
            AVAIL=$(sshpass -p "$NAS_PASS" rsync "$NAS_USER@$NAS_HOST::" 2>&1 || true)
            if echo "$AVAIL" | grep -qE "auth failed|@ERROR"; then
                if whiptail --yesno "❌ Авторизация на NAS не прошла:\n\n$AVAIL\n\nПопробовать снова?" 14 70; then
                    continue
                fi
                break
            fi
            # 3) OK — показываем доступные модули чтобы юзер сверил с MODULES в конфиге
            MODULES_LIST=$(echo "$AVAIL" | awk '{print $1}' | grep -vE '^$|^msg=' | head -10 | tr '\n' ' ')
            whiptail --msgbox \
"✓ NAS доступен. Доступные rsync-модули:

  $MODULES_LIST

В конфиге MODULES записаны как src|target (src — слева, имя на NAS).
Если у тебя другие шары — поправь /etc/travel-nas/nas-backup.conf после установки." \
                14 72
            break
        done
        sudo tee "$CONFIG_DIR/nas-backup.conf" > /dev/null << EOF
NAS_HOST="$NAS_HOST"
NAS_USER="$NAS_USER"
NAS_PASS="$NAS_PASS"
DEST="$STORAGE_MOUNT/nas-backup"

# Модули для бэкапа (формат: "rsync_module|local_folder")
#
# Список доступных модулей: sshpass -p "\$NAS_PASS" rsync "\$NAS_USER@\$NAS_HOST::"
#
# Можно бэкапить subpath внутри модуля (если папка существует на NAS):
#   "HDD6TB/Photos|Photos-Other"      ← подпапка модуля HDD6TB
#   "HDD6TB/Media/Movies|Movies"      ← глубокий путь
#   "home/Pictures|MyPictures"        ← подпапка home
#
# НЕ работает (rsync daemon отвергает):
#   "/volume1/Backup|Backup"          ← абсолютные пути запрещены
#   "volume1/Backup|Backup"           ← volume1 не модуль
#
# Тест перед commit'ом: sudo nas-backup --diff (кривой subpath → error)
MODULES=(
    "home|Personal"
    "docker|Docker"
    "Backup|Backup"
    "PMedia|PMedia"
    "Music|Music"
)
EXCLUDES=(
    "_gsdata_" ".DS_Store" "Thumbs.db" "@eaDir/" "#recycle/"
    ".Trash*" "*.tmp" ".cache/" "node_modules/" "__pycache__/"
    "vendor/" ".next/" ".nuxt/" "dist/" "build/" ".git/" ".svn/"
)
EOF
        sudo chmod 600 "$CONFIG_DIR/nas-backup.conf"
    fi

    # --- Авто-расписание (опционально) ---
    # Спрашиваем только если конфиг есть (иначе бэкапить нечем).
    if [[ -f "$CONFIG_DIR/nas-backup.conf" ]]; then
        # Текущее состояние → дефолт в меню (чтобы re-run показывал что выбрано).
        CUR="off"
        if systemctl is-enabled nas-backup-auto.timer >/dev/null 2>&1; then
            if grep -q 'Sun' /etc/systemd/system/nas-backup-auto.timer 2>/dev/null; then
                CUR="weekly"
            else
                CUR="daily"
            fi
        fi
        SCHED=$(whiptail --title "NAS авто-бэкап" --default-item "$CUR" --menu \
"Запускать бэкап с NAS автоматически?
Когда NAS недоступен (в поездке) — тихо пропускается, без алёртов." 15 72 3 \
            "off"    "Только вручную (дашборд / бот)" \
            "daily"  "Каждую ночь в 03:00" \
            "weekly" "Раз в неделю — воскресенье 03:00" \
            3>&1 1>&2 2>&3) || SCHED="$CUR"

        case "$SCHED" in
            daily)  CAL="*-*-* 03:00:00" ;;
            weekly) CAL="Sun *-*-* 03:00:00" ;;
            *)      CAL="" ;;
        esac

        if [[ -n "$CAL" ]]; then
            write_systemd_unit nas-backup-auto.service << 'EOF'
[Unit]
Description=Automatic NAS backup (scheduled)
After=network-online.target mnt-storage.mount
Wants=network-online.target

[Service]
Type=oneshot
Environment=NAS_BACKUP_DETACHED=1
Nice=15
IOSchedulingClass=idle
# Тихо пропустить если NAS недоступен (в поездке) — без фейла/алёрта.
# NAS_BACKUP_DETACHED=1 → nas-backup.sh бежит прямо в этом oneshot, без re-exec.
ExecStart=/bin/bash -c 'source /etc/travel-nas/nas-backup.conf 2>/dev/null; ping -c1 -W3 "$NAS_HOST" >/dev/null 2>&1 && exec /usr/local/bin/nas-backup.sh --run'
EOF
            write_systemd_unit nas-backup-auto.timer << EOF
[Unit]
Description=Scheduled NAS backup

[Timer]
OnCalendar=$CAL
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now nas-backup-auto.timer
            info "NAS авто-бэкап: $SCHED ($CAL)"
        else
            sudo systemctl disable --now nas-backup-auto.timer 2>/dev/null || true
            sudo rm -f /etc/systemd/system/nas-backup-auto.timer \
                       /etc/systemd/system/nas-backup-auto.service
            sudo systemctl daemon-reload
            info "NAS авто-бэкап: выключен (только вручную)"
        fi
    fi
); then
    mark_ok "NAS_BACKUP"
else
    mark_fail "NAS_BACKUP" "config failed"
fi
