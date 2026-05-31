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
    # nas-schedule.sh нужен ДО создания конфига (path-unit дёрнет его apply).
    fetch_script "nas-schedule.sh"      "$SCRIPT_DIR/nas-schedule.sh"

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

    # Path-unit: правка AUTO_BACKUP* в nas-backup.conf → авто-применение таймера
    # (чтобы расписание менялось через конфиг, как все остальные настройки).
    write_systemd_unit nas-schedule-apply.service << 'EOF'
[Unit]
Description=Apply NAS auto-backup schedule from nas-backup.conf

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-schedule.sh apply
EOF
    write_systemd_unit nas-schedule-apply.path << 'EOF'
[Unit]
Description=Watch nas-backup.conf for schedule changes

[Path]
PathChanged=/etc/travel-nas/nas-backup.conf
Unit=nas-schedule-apply.service

[Install]
WantedBy=paths.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now nas-schedule-apply.path

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

# --- Авто-бэкап по расписанию ---
# Меняешь тут руками → применяется автоматически (path-unit nas-schedule-apply).
# Или через дашборд: NAS status → кнопка Auto. Или: nas-schedule.sh set daily 04:30
AUTO_BACKUP="off"          # on | off
AUTO_BACKUP_FREQ="daily"   # daily | weekly (воскресенье)
AUTO_BACKUP_TIME="03:00"   # HH:MM, 24ч

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
    # Логика в nas-schedule.sh (его дёргают дашборд и path-unit). Источник правды —
    # ключи AUTO_BACKUP* в nas-backup.conf; wizard просто их записывает.
    # Спрашиваем только если конфиг есть (иначе бэкапить нечем).
    if [[ -f "$CONFIG_DIR/nas-backup.conf" ]]; then
        # Текущее состояние → дефолт в меню (чтобы re-run показывал что выбрано).
        CUR_STATUS=$("$SCRIPT_DIR/nas-schedule.sh" status 2>/dev/null)
        CUR_FREQ=$(echo "$CUR_STATUS" | awk '{print $1}')
        CUR_TIME=$(echo "$CUR_STATUS" | awk '{print $2}')
        [[ "$CUR_FREQ" == daily || "$CUR_FREQ" == weekly ]] || CUR_FREQ="off"

        SCHED=$(whiptail --title "NAS авто-бэкап" --default-item "$CUR_FREQ" --menu \
"Запускать бэкап с NAS автоматически?
Когда NAS недоступен (в поездке) — тихо пропускается, без алёртов." 15 72 3 \
            "off"    "Только вручную (дашборд / бот)" \
            "daily"  "Каждый день в выбранное время" \
            "weekly" "Раз в неделю (воскресенье) в выбранное время" \
            3>&1 1>&2 2>&3) || SCHED="$CUR_FREQ"

        if [[ "$SCHED" == "off" ]]; then
            sudo "$SCRIPT_DIR/nas-schedule.sh" off >/dev/null
            info "NAS авто-бэкап: выключен (только вручную)"
        else
            # Кастомное время — спрашиваем HH:MM, валидируем, по умолчанию текущее/03:00.
            DEF_TIME="${CUR_TIME:-03:00}"
            [[ "$DEF_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || DEF_TIME="03:00"
            while true; do
                TIME=$(whiptail --title "Время бэкапа" --inputbox \
"Во сколько запускать ($SCHED)?  Формат HH:MM (24ч).
Совет: ночь/раннее утро — меньше мешает." 11 64 "$DEF_TIME" 3>&1 1>&2 2>&3) || TIME="$DEF_TIME"
                if [[ "$TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    break
                fi
                whiptail --msgbox "Неверный формат: '$TIME'. Нужно HH:MM, напр. 03:00 или 23:30." 9 60
            done
            sudo "$SCRIPT_DIR/nas-schedule.sh" set "$SCHED" "$TIME" >/dev/null
            info "NAS авто-бэкап: $SCHED $TIME"
        fi
    fi
); then
    mark_ok "NAS_BACKUP"
else
    mark_fail "NAS_BACKUP" "config failed"
fi
