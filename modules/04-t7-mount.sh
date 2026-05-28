[[ -n "${DO_T7_MOUNT:-}" ]] || return 0

info "=== T7 Mount ==="

# 1. Уже есть диск с нашим label? (повторный запуск setup)
T7_DEV=$(sudo blkid -L "$T7_LABEL" 2>/dev/null || echo "")

# 2. Если нет — интерактивный wizard: выбор диска + формат в ext4.
if [[ -z "$T7_DEV" ]]; then
    # Корневой диск (где OS) — НЕ предлагаем для форматирования
    SYS_SRC=$(findmnt -n -o SOURCE / 2>/dev/null)
    # /dev/mmcblk0p2 → /dev/mmcblk0;  /dev/sda1 → /dev/sda
    SYS_DISK=$(echo "$SYS_SRC" | sed -E 's|p?[0-9]+$||')

    CANDIDATES=()
    while IFS=$'\t' read -r NAME SIZE MODEL TYPE; do
        [[ "$TYPE" != "disk" ]] && continue
        DEV="/dev/$NAME"
        [[ "$DEV" == "$SYS_DISK" ]] && continue
        SIZE_BYTES=$(lsblk -bdn -o SIZE "$DEV" 2>/dev/null | head -1)
        (( ${SIZE_BYTES:-0} < 32000000000 )) && continue   # <32GB
        LABEL_INFO="${MODEL:-unknown}"
        CANDIDATES+=("$DEV" "$SIZE — $LABEL_INFO")
    done < <(lsblk -dn -o NAME,SIZE,MODEL,TYPE 2>/dev/null)

    if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        mark_fail "T7_MOUNT" "не найдено подходящих дисков (нужен ≥32GB, не системный)"
        warn "Подключи внешний SSD/HDD и перезапусти setup.sh"
    else
        warn "ВНИМАНИЕ: выбранный диск БУДЕТ ОТФОРМАТИРОВАН в ext4!"
        warn "Все данные на нём ПРОПАДУТ. Скопируй их куда-нибудь ДО продолжения."
        echo ""
        SEL_DEV=$(whiptail --title "Disk for travel-NAS storage" \
            --menu "Выбери диск (БУДЕТ ОТФОРМАТИРОВАН в ext4!):" \
            20 76 10 "${CANDIDATES[@]}" 3>&1 1>&2 2>&3) || SEL_DEV=""

        if [[ -z "$SEL_DEV" ]]; then
            mark_fail "T7_MOUNT" "отмена пользователем"
        else
            SEL_INFO=$(lsblk -dn -o SIZE,MODEL,SERIAL "$SEL_DEV" 2>/dev/null | head -1)
            if whiptail --title "Confirm format" --yesno \
                "Я СЕЙЧАС ОТФОРМАТИРУЮ:\n\n  $SEL_DEV\n  $SEL_INFO\n\nВСЕ ДАННЫЕ на нём БУДУТ УДАЛЕНЫ.\nВсе скопировал? Точно продолжить?" \
                14 70; then
                if (
                    set -e
                    info "Размонтирую любые существующие партиции на $SEL_DEV..."
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
                    info "Форматирую $PART в ext4 (label='$T7_LABEL', reserved=0%)..."
                    sudo mkfs.ext4 -F -L "$T7_LABEL" -m 0 "$PART"
                    T7_DEV="$PART"
                ); then
                    T7_DEV=$(sudo blkid -L "$T7_LABEL" 2>/dev/null || echo "")
                else
                    mark_fail "T7_MOUNT" "format failed"
                fi
            else
                mark_fail "T7_MOUNT" "отмена форматирования"
            fi
        fi
    fi
fi

if [[ -n "$T7_DEV" ]]; then
    if (
        set -e
        T7_UUID=$(sudo blkid -s UUID -o value "$T7_DEV")
        sudo mkdir -p "$T7_MOUNT" "$CONFIG_DIR"

        # Pi 5 USB power: без флага usb_max_current_enable=1 kernel зажимает
        # суммарный USB ток до 600mA (пока PSU не сообщит 5V/5A profile, что
        # делает только официальный Pi 27W PSU). T7 SSD при rsync-пиках
        # упирается в лимит → дисконнект / throttling. С нормальной 30W+ PD
        # зарядкой риска под-вольтажа нет (kernel сам поймает через
        # vcgencmd get_throttled и переключится в saver-mode).
        BOOT_CFG=/boot/firmware/config.txt
        if [[ -f "$BOOT_CFG" ]] && ! grep -qE '^usb_max_current_enable=1' "$BOOT_CFG"; then
            echo "" | sudo tee -a "$BOOT_CFG" >/dev/null
            echo "# travel-nas-setup: разрешить полный USB ток для T7 SSD" | sudo tee -a "$BOOT_CFG" >/dev/null
            echo "usb_max_current_enable=1" | sudo tee -a "$BOOT_CFG" >/dev/null
            info "usb_max_current_enable=1 добавлен в $BOOT_CFG (применится после reboot)"
        fi
        if ! grep -q "$T7_UUID" /etc/fstab; then
            echo "UUID=$T7_UUID $T7_MOUNT ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab > /dev/null
        fi
        if ! mountpoint -q "$T7_MOUNT"; then
            sudo mount "$T7_MOUNT"
        fi
        echo "T7_UUID=\"$T7_UUID\"" | sudo tee "$CONFIG_DIR/t7-info.conf" > /dev/null
        sudo chmod 644 "$CONFIG_DIR/t7-info.conf"
        sudo mkdir -p "$T7_MOUNT/nas-backup/"{_deleted,_logs}
        sudo mkdir -p "$T7_MOUNT/usb-imports" "$T7_MOUNT/pi-config-backups" \
                      "$T7_MOUNT/media" "$T7_MOUNT/sync" "$T7_MOUNT/_logs"
        # T7 — single-user device. Владелец = $(whoami), lost+found остаётся root.
        sudo chown -R "$(whoami):$(whoami)" "$T7_MOUNT"/[!l]* 2>/dev/null || true
        sudo chown    "$(whoami):$(whoami)" "$T7_MOUNT" 2>/dev/null || true
    ); then
        mark_ok "T7_MOUNT" "$T7_DEV → $T7_MOUNT"
    else
        mark_fail "T7_MOUNT" "ошибка монтирования"
    fi
fi
