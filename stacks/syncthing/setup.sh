# Syncthing pre-setup: папки данных/конфига (PUID 1000), TZ в .env.
stack_pre() {
    sudo install -d -o 1000 -g 1000 /mnt/storage/sync
    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/syncthing
    printf 'TZ=%s\n' "$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)" | sudo tee "$STACK_DIR/.env" >/dev/null
}
