# Scrutiny pre: appdata + резолв блок-устройства диска хранилища для SMART.
# Передаём в контейнер РОДИТЕЛЬСКОЕ устройство (sda), не партицию (sda1) —
# smartctl читает диск целиком. T7 по USB обычно отдаёт SMART через SAT-bridge.
stack_pre() {
    sudo install -d /mnt/storage/_appdata/scrutiny/config
    sudo install -d /mnt/storage/_appdata/scrutiny/influxdb

    local src dev
    src="$(findmnt -no SOURCE /mnt/storage 2>/dev/null)"
    dev="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
    [[ -n "$dev" ]] && dev="/dev/$dev" || dev="/dev/sda"
    printf 'SCRUTINY_DEV=%s\n' "$dev" | sudo tee "$STACK_DIR/.env" >/dev/null
    info "Scrutiny следит за $dev (диск хранилища)"
}
