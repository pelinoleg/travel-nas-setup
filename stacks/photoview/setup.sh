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

    # CPU-лимит скана/тумбнейлинга, адаптивно под модель Pi. .env подхватывает
    # docker compose (${PV_CPU_LIMIT}/${PV_WORKERS}). Тюнинг: правь .env + up -d.
    local model; model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "")
    local pv_cpu pv_workers
    case "$model" in
        *"Pi 5"*) pv_cpu="2.5"; pv_workers="3" ;;
        *"Pi 4"*) pv_cpu="2.0"; pv_workers="2" ;;
        *)        pv_cpu="1.5"; pv_workers="2" ;;
    esac
    printf 'PV_CPU_LIMIT=%s\nPV_WORKERS=%s\n' "$pv_cpu" "$pv_workers" | sudo tee "$STACK_DIR/.env" >/dev/null
}
