# Photoview pre-setup: БД/кэш на диске (UID 999 = mysql/photoview), .photoviewignore.
# Данные на /mnt/storage чтобы переустановка системы не теряла БД (scanned media).
stack_pre() {
    sudo install -d -o 999 -g 999 -m 0755 /mnt/storage/_appdata/photoview/cache
    sudo install -d -o 999 -g 999 -m 0755 /mnt/storage/_appdata/photoview/db
    # .photoviewignore — скан игнорит RAW (на ARM thumbnail RAW = минуты CPU).
    sudo mkdir -p /mnt/storage/usb-imports
    if [[ ! -f /mnt/storage/usb-imports/.photoviewignore ]]; then
        fetch_conf_example "photoviewignore.example" /mnt/storage/usb-imports/.photoviewignore
    fi
    sudo chmod 0644 /mnt/storage/usb-imports/.photoviewignore 2>/dev/null || true
}
