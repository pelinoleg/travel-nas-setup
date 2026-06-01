[[ -n "${DO_STORAGE_MOUNT:-}" ]] || return 0

info "=== Storage Mount ==="

# =============================================================================
# Pi 5 USB power — ОБЯЗАТЕЛЬНО ПЕРВЫМ, до детекта диска
# =============================================================================
# Без usb_max_current_enable=1 ядро Pi 5 зажимает суммарный USB-ток до 600mA
# (пока PSU не сообщит 5V/5A — это только офиц. Pi 27W PSU). USB-SSD под
# нагрузкой/при споте браунит → `device offline` / I/O error → диск исчезает
# из lsblk, и wizard говорит «дисков не найдено» вместо «форматировать?».
# Ставим РАНО и безусловно (не в mount-блоке) — иначе chicken-and-egg: диск
# отваливается до того как успеем смонтировать и выставить флаг. Нужен REBOOT.
# Pi 4 — другая USB-архитектура, флаг игнорируется (не ставим).
STORAGE_USB_FLAG_ADDED=""
PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
if [[ "$PI_MODEL" == *"Pi 5"* ]]; then
    BOOT_CFG=/boot/firmware/config.txt
    if [[ -f "$BOOT_CFG" ]] && ! grep -qE '^usb_max_current_enable=1' "$BOOT_CFG"; then
        echo "" | sudo tee -a "$BOOT_CFG" >/dev/null
        echo "# travel-nas-setup: полный USB-ток для внешнего SSD (Pi 5)" | sudo tee -a "$BOOT_CFG" >/dev/null
        echo "usb_max_current_enable=1" | sudo tee -a "$BOOT_CFG" >/dev/null
        STORAGE_USB_FLAG_ADDED=1
        warn "Pi 5: добавил usb_max_current_enable=1 — нужен REBOOT, иначе USB-SSD отваливается под нагрузкой."
    fi
fi

# =============================================================================
# Helpers
# =============================================================================

# Эхо "<data-part>\t<fstype>\t<label>" для диска.
# Логика выбора «основной» партиции: предпочитаем ext4, иначе первую партицию,
# иначе сам диск (ФС может лежать прямо на устройстве без таблицы разделов).
_storage_data_part() {
    local disk="$1"
    local first="" first_fs="" first_label=""
    local name type dev fs label
    while read -r name type; do
        [[ "$type" == part ]] || continue
        dev="/dev/$name"
        fs=$(sudo blkid -s TYPE  -o value "$dev" 2>/dev/null)
        label=$(sudo blkid -s LABEL -o value "$dev" 2>/dev/null)
        [[ -z "$first" ]] && { first="$dev"; first_fs="$fs"; first_label="$label"; }
        if [[ "$fs" == ext4 ]]; then
            printf '%s\t%s\t%s\n' "$dev" "$fs" "$label"
            return
        fi
    done < <(lsblk -lno NAME,TYPE "$disk" 2>/dev/null)
    if [[ -n "$first" ]]; then
        printf '%s\t%s\t%s\n' "$first" "$first_fs" "$first_label"
        return
    fi
    fs=$(sudo blkid -s TYPE  -o value "$disk" 2>/dev/null)
    label=$(sudo blkid -s LABEL -o value "$disk" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$disk" "$fs" "$label"
}

# Размонтировать устройство откуда бы оно ни было смонтировано (кроме нашей
# целевой точки $STORAGE_MOUNT — её не трогаем, чтобы не оторвать рабочий маунт).
_storage_umount_elsewhere() {
    local dev="$1" mp
    while read -r mp; do
        [[ -n "$mp" && "$mp" != "$STORAGE_MOUNT" ]] && sudo umount "$mp" 2>/dev/null || true
    done < <(findmnt -nro TARGET "$dev" 2>/dev/null)
}

# Есть ли на партиции наш файл-маркер? (опознаём «свой» диск независимо от
# label и пути). Если уже смонтирована — смотрим в текущей точке, иначе
# временно монтируем read-only.
_storage_has_marker() {
    local part="$1" mp rc=1 tmp
    mp=$(findmnt -nro TARGET "$part" 2>/dev/null | head -1)
    if [[ -n "$mp" ]]; then
        [[ -e "$mp/$STORAGE_MARKER" ]] && rc=0
    else
        tmp=$(mktemp -d)
        if sudo mount -o ro "$part" "$tmp" 2>/dev/null; then
            [[ -e "$tmp/$STORAGE_MARKER" ]] && rc=0
            sudo umount "$tmp" 2>/dev/null || true
        fi
        rmdir "$tmp" 2>/dev/null || true
    fi
    return $rc
}

# Найти первую ext4-партицию с нашим маркером (кроме системного диска).
_storage_find_marked() {
    local sysdisk="$1" name type dev fs
    while read -r name type; do
        [[ "$type" == part ]] || continue
        dev="/dev/$name"
        [[ -n "$sysdisk" && "$dev" == "$sysdisk"* ]] && continue
        fs=$(sudo blkid -s TYPE -o value "$dev" 2>/dev/null)
        [[ "$fs" == ext4 ]] || continue
        if _storage_has_marker "$dev"; then echo "$dev"; return; fi
    done < <(lsblk -lno NAME,TYPE 2>/dev/null)
}

# Корневой диск (где OS) — его НИКОГДА не трогаем и не предлагаем.
SYS_SRC=$(findmnt -n -o SOURCE / 2>/dev/null)
SYS_DISK=$(echo "$SYS_SRC" | sed -E 's|p?[0-9]+$||')

# =============================================================================
# Поиск уже подготовленного диска (без wizard'а) — универсально, без привязки
# к конкретному имени. Порядок: conf-UUID → файл-маркер → legacy-label.
# =============================================================================
STORAGE_DEV=""
DO_FORMAT=""
CHOSEN_LABEL="$STORAGE_LABEL"

# 1. Знаем UUID с прошлого запуска (тот же OS-инстанс) → тихо берём.
if [[ -f "$CONFIG_DIR/storage-info.conf" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/storage-info.conf" 2>/dev/null || true
    if [[ -n "${STORAGE_UUID:-}" ]]; then
        CAND=$(sudo blkid -U "$STORAGE_UUID" 2>/dev/null || echo "")
        [[ -n "$CAND" ]] && STORAGE_DEV="$CAND"
    fi
fi

# 2. Скан по файлу-маркеру — опознаёт наш диск с ЛЮБЫМ label, переживает
#    переустановку OS. Это и есть «тот же диск, новая система».
if [[ -z "$STORAGE_DEV" ]]; then
    MARKED=$(_storage_find_marked "$SYS_DISK")
    if [[ -n "$MARKED" ]]; then
        STORAGE_DEV="$MARKED"
        info "Найден ранее подготовленный диск (по маркеру): $STORAGE_DEV — использую как есть (данные сохранены)"
    fi
fi

# 3. Legacy: диск со старым label 't7' (установка до перехода на маркер).
#    Подхватываем как есть; маркер допишется ниже при монтировании.
if [[ -z "$STORAGE_DEV" ]]; then
    STORAGE_DEV=$(sudo blkid -L "$STORAGE_LEGACY_LABEL" 2>/dev/null || echo "")
    [[ -n "$STORAGE_DEV" ]] && \
        info "Найден legacy-диск (label '$STORAGE_LEGACY_LABEL'): $STORAGE_DEV — мигрирую как есть (данные сохранены)"
fi

# =============================================================================
# Wizard: показать подключённые диски, выбрать, адаптировать или отформатировать
# =============================================================================
if [[ -z "$STORAGE_DEV" ]]; then
    MENU=()
    declare -A PART_OF FS_OF LABEL_OF
    while read -r NAME SIZE TYPE MODEL; do
        [[ "$TYPE" != "disk" ]] && continue
        DEV="/dev/$NAME"
        [[ "$DEV" == "$SYS_DISK" ]] && continue
        SIZE_BYTES=$(lsblk -bdn -o SIZE "$DEV" 2>/dev/null | head -1)
        (( ${SIZE_BYTES:-0} < 32000000000 )) && continue   # <32GB — мимо

        IFS=$'\t' read -r DPART DFS DLABEL < <(_storage_data_part "$DEV")
        PART_OF[$DEV]="$DPART"; FS_OF[$DEV]="$DFS"; LABEL_OF[$DEV]="$DLABEL"

        DESC="$SIZE"
        [[ -n "$DFS" ]]    && DESC+="  fs=$DFS" || DESC+="  fs=—"
        [[ -n "$DLABEL" ]] && DESC+="  '$DLABEL'"
        [[ -n "$MODEL" ]]  && DESC+="  $MODEL"
        MENU+=("$DEV" "$DESC")
    done < <(lsblk -drno NAME,SIZE,TYPE,MODEL 2>/dev/null)

    if [[ ${#MENU[@]} -eq 0 ]]; then
        mark_fail "STORAGE_MOUNT" "не найдено подходящих дисков (нужен ≥32GB, не системный)"
        if [[ -n "$STORAGE_USB_FLAG_ADDED" ]]; then
            warn "Похоже диск отвалился по USB-power (Pi 5). Флаг usb_max_current_enable=1 ТОЛЬКО ЧТО добавлен — СДЕЛАЙ REBOOT и запусти setup.sh снова, диск станет стабильным."
        else
            warn "Подключи внешний SSD/HDD и перезапусти setup.sh. Если Pi 5 и диск мигает — проверь dmesg на 'device offline' (USB-power) и что стоит usb_max_current_enable=1 + был reboot."
        fi
    else
        SEL_DEV=$(whiptail --title "Travel-NAS storage" \
            --menu "Подключённые диски — выбери для хранилища:\n(размер · файловая система · метка · модель)" \
            20 78 10 "${MENU[@]}" 3>&1 1>&2 2>&3) || SEL_DEV=""

        if [[ -z "$SEL_DEV" ]]; then
            mark_fail "STORAGE_MOUNT" "отмена пользователем"
        else
            SEL_PART="${PART_OF[$SEL_DEV]}"
            SEL_FS="${FS_OF[$SEL_DEV]}"
            SEL_LABEL="${LABEL_OF[$SEL_DEV]}"
            SEL_INFO=$(lsblk -dn -o SIZE,MODEL,SERIAL "$SEL_DEV" 2>/dev/null | head -1)

            # Десктоп мог авто-смонтировать в /media/... — снимем перед fsck/работой.
            _storage_umount_elsewhere "$SEL_PART"

            if [[ "$SEL_FS" == ext4 ]]; then
                # Уже ext4 → проверим целостность read-only и предложим оставить как есть.
                info "Проверяю ext4 на $SEL_PART (e2fsck -fn)..."
                if sudo e2fsck -fn "$SEL_PART" >/tmp/storage-fsck.log 2>&1; then
                    HEALTH="ФС чистая, ошибок нет"
                else
                    HEALTH="e2fsck нашёл проблемы — см. /tmp/storage-fsck.log"
                fi

                if whiptail --title "Диск уже ext4" \
                    --yes-button "Использовать" --no-button "Форматировать" --yesno \
"Диск $SEL_DEV ($SEL_PART):

  $SEL_INFO
  файловая система: ext4${SEL_LABEL:+   метка '$SEL_LABEL'}
  проверка: $HEALTH

Похоже на ранее подготовленный диск с данными.

  <Использовать>  — взять как есть, НИЧЕГО не стирать
  <Форматировать> — пересоздать ext4 (ВСЕ ДАННЫЕ удалятся)" 18 74; then
                    STORAGE_DEV="$SEL_PART"
                    info "Адаптирую существующий ext4 как есть — данные сохранены"
                else
                    DO_FORMAT=1
                fi
            else
                # Чужая или пустая ФС — без форматирования не обойтись.
                whiptail --title "Нужно отформатировать" --msgbox \
"Диск $SEL_DEV
  $SEL_INFO
  файловая система: ${SEL_FS:-нет/неизвестна}

Для travel-NAS нужен ext4. Диск будет ОТФОРМАТИРОВАН —
все данные на нём удалятся. Если там есть нужные файлы,
скопируй их сначала." 16 72
                DO_FORMAT=1
            fi

            # --- Форматирование (если выбрали/нужно) ---
            if [[ -n "$DO_FORMAT" ]]; then
                CHOSEN_LABEL=$(whiptail --title "Имя диска" --inputbox \
"Какую метку (label) поставить диску?

≤16 символов, без пробелов. По умолчанию '$STORAGE_LABEL'." \
                    12 64 "$STORAGE_LABEL" 3>&1 1>&2 2>&3) || CHOSEN_LABEL=""
                CHOSEN_LABEL="${CHOSEN_LABEL// /_}"
                CHOSEN_LABEL="${CHOSEN_LABEL:0:16}"
                [[ -z "$CHOSEN_LABEL" ]] && CHOSEN_LABEL="$STORAGE_LABEL"

                if whiptail --title "Подтверди форматирование" --yesno \
"СЕЙЧАС БУДЕТ ОТФОРМАТИРОВАНО:

  $SEL_DEV
  $SEL_INFO
  → ext4, метка '$CHOSEN_LABEL'

ВСЕ ДАННЫЕ на диске будут УДАЛЕНЫ. Точно продолжить?" 16 70; then
                    if (
                        set -e
                        # Desktop udisks2/pcmanfm АСИНХРОННО авто-монтит свежую
                        # партицию → mkfs падает "is mounted". Глушим udisks2 на
                        # время формата; trap вернёт его при любом выходе.
                        sudo systemctl stop udisks2.service 2>/dev/null || true
                        trap 'sudo systemctl start udisks2.service 2>/dev/null || true' EXIT
                        info "Размонтирую партиции на $SEL_DEV..."
                        for part in "${SEL_DEV}"?*; do
                            sudo umount "$part" 2>/dev/null || true
                        done
                        info "Стираю старые подписи (wipefs)..."
                        sudo wipefs -a "$SEL_DEV"
                        info "Создаю GPT + ext4 партицию..."
                        sudo parted -s "$SEL_DEV" mklabel gpt
                        sudo parted -s "$SEL_DEV" mkpart primary ext4 0% 100%
                        sudo partprobe "$SEL_DEV" 2>/dev/null || true
                        sleep 2
                        # NVMe / mmcblk используют ${dev}p1, SATA/USB — ${dev}1
                        if [[ "$SEL_DEV" =~ (nvme|mmcblk) ]]; then
                            PART="${SEL_DEV}p1"
                        else
                            PART="${SEL_DEV}1"
                        fi
                        # devmon/udisks (ставит CasaOS) авто-монтирует свежую
                        # партицию между partprobe и mkfs → mkfs падает "is
                        # mounted; will not make a filesystem". Снимаем маунт
                        # отовсюду прямо перед форматом.
                        udevadm settle 2>/dev/null || true
                        _storage_umount_elsewhere "$PART"
                        sudo umount "$PART" 2>/dev/null || true
                        # Стереть ФС-подпись ВНУТРИ партиции (флэшки идут с FAT/
                        # exFAT) — wipefs диска её не трогает, а авто-монтер по ней
                        # монтит обратно. Без этого mkfs снова падает "is mounted".
                        sudo wipefs -a "$PART" 2>/dev/null || true
                        info "Форматирую $PART в ext4 (label='$CHOSEN_LABEL', reserved=0%)..."
                        sudo mkfs.ext4 -F -L "$CHOSEN_LABEL" -m 0 "$PART"
                    ); then
                        STORAGE_DEV=$(sudo blkid -L "$CHOSEN_LABEL" 2>/dev/null || echo "")
                    else
                        mark_fail "STORAGE_MOUNT" "format failed"
                    fi
                else
                    mark_fail "STORAGE_MOUNT" "отмена форматирования"
                fi
            fi
        fi
    fi
fi

# =============================================================================
# Монтирование (общее для adopt / format / fast-path / legacy-миграции)
# =============================================================================
if [[ -n "$STORAGE_DEV" ]]; then
    if (
        set -e
        # Снять авто-маунт, если диск висит не там где надо (/media/..., legacy /mnt/t7).
        _storage_umount_elsewhere "$STORAGE_DEV"

        # Legacy-миграция: убрать старую fstab-запись /mnt/t7 (если была).
        if grep -qE "[[:space:]]${STORAGE_LEGACY_MOUNT}[[:space:]]" /etc/fstab 2>/dev/null; then
            sudo sed -i.travel-nas-bak -E "\#[[:space:]]${STORAGE_LEGACY_MOUNT}[[:space:]]#d" /etc/fstab
            info "Удалил старую fstab-запись $STORAGE_LEGACY_MOUNT (миграция на $STORAGE_MOUNT)"
        fi
        if mountpoint -q "$STORAGE_LEGACY_MOUNT" 2>/dev/null; then
            sudo umount "$STORAGE_LEGACY_MOUNT" 2>/dev/null || sudo umount -l "$STORAGE_LEGACY_MOUNT" 2>/dev/null || true
        fi
        sudo rmdir "$STORAGE_LEGACY_MOUNT" 2>/dev/null || true

        # Legacy-миграция путей в конфигах юзера. /etc/travel-nas/*.conf миграция
        # обычно НЕ трогает, но DEST="/mnt/t7/..." после смены пути ломает
        # nas-backup / photo-backup (пишут/сканируют мёртвый путь). Чиним один раз.
        for cf in "$CONFIG_DIR"/*.conf; do
            [[ -f "$cf" ]] || continue
            if grep -q "$STORAGE_LEGACY_MOUNT/" "$cf" 2>/dev/null; then
                sudo sed -i "s#${STORAGE_LEGACY_MOUNT}/#${STORAGE_MOUNT}/#g" "$cf"
                info "Мигрировал путь в $(basename "$cf"): $STORAGE_LEGACY_MOUNT → $STORAGE_MOUNT"
            fi
        done
        # Сирота старой схемы: t7-info.conf заменён на storage-info.conf.
        sudo rm -f "$CONFIG_DIR/t7-info.conf"

        STORAGE_UUID=$(sudo blkid -s UUID -o value "$STORAGE_DEV")
        sudo mkdir -p "$STORAGE_MOUNT" "$CONFIG_DIR"
        # (usb_max_current_enable для Pi 5 уже выставлен в начале модуля)

        if ! grep -q "$STORAGE_UUID" /etc/fstab; then
            echo "UUID=$STORAGE_UUID $STORAGE_MOUNT ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab > /dev/null
        fi
        # fstab меняли (выше — legacy-чистка, тут — UUID). systemd кеширует fstab
        # как mount-юниты → mount ворчит "fstab modified, daemon-reload". Перечитаем.
        sudo systemctl daemon-reload 2>/dev/null || true
        if ! mountpoint -q "$STORAGE_MOUNT"; then
            sudo mount "$STORAGE_MOUNT"
        fi

        # Файл-маркер — по нему диск опознаётся при следующих запусках (любой label).
        echo "travel-nas storage; uuid=$STORAGE_UUID" | sudo tee "$STORAGE_MOUNT/$STORAGE_MARKER" >/dev/null

        echo "STORAGE_UUID=\"$STORAGE_UUID\"" | sudo tee "$CONFIG_DIR/storage-info.conf" > /dev/null
        sudo chmod 644 "$CONFIG_DIR/storage-info.conf"
        sudo mkdir -p "$STORAGE_MOUNT/nas-backup/"{_deleted,_logs}
        sudo mkdir -p "$STORAGE_MOUNT/usb-imports" "$STORAGE_MOUNT/pi-config-backups" \
                      "$STORAGE_MOUNT/media" "$STORAGE_MOUNT/sync" "$STORAGE_MOUNT/_logs"

        # Single-user device. Владелец корня + наших служебных папок = $(whoami).
        sudo chown "$(whoami):$(whoami)" "$STORAGE_MOUNT" 2>/dev/null || true
        sudo chown -R "$(whoami):$(whoami)" \
            "$STORAGE_MOUNT/nas-backup" "$STORAGE_MOUNT/usb-imports" "$STORAGE_MOUNT/pi-config-backups" \
            "$STORAGE_MOUNT/media" "$STORAGE_MOUNT/sync" "$STORAGE_MOUNT/_logs" 2>/dev/null || true
        # Только свежеотформатированный диск пуст — там безопасно выставить
        # владельца на весь корень. На adopt-диске с данными НЕ трогаем чужой owner.
        if [[ -n "$DO_FORMAT" ]]; then
            sudo chown -R "$(whoami):$(whoami)" "$STORAGE_MOUNT"/[!l]* 2>/dev/null || true
        fi
    ); then
        mark_ok "STORAGE_MOUNT" "$STORAGE_DEV → $STORAGE_MOUNT"
    else
        mark_fail "STORAGE_MOUNT" "ошибка монтирования"
    fi
fi
