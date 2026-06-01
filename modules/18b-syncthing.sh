[[ -n "${DO_SYNCTHING:-}" ]] || return 0

# Syncthing — P2P-синхронизация папок. Web UI :8384. Данные на /mnt/storage/sync,
# конфиг БД на /mnt/storage/_appdata/syncthing (переустановка системы не теряет).
# PUID/PGID=1000 — синканные файлы принадлежат человеку-юзеру (как Samba/photo).
info "=== Syncthing ==="
if ! command -v docker &>/dev/null; then
    mark_fail "SYNCTHING" "Docker не установлен (сначала DOCKER)"
elif (
    set -e
    sudo install -d -o 1000 -g 1000 /mnt/storage/sync
    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/syncthing
    TZ_VAL=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")

    sudo mkdir -p /opt/stacks/syncthing
    sudo tee /opt/stacks/syncthing/compose.yaml >/dev/null << EOF
name: syncthing
services:
  syncthing:
    image: lscr.io/linuxserver/syncthing:latest
    container_name: syncthing
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=$TZ_VAL
    ports:
      - "8384:8384"        # Web UI
      - "22000:22000/tcp"  # sync protocol
      - "22000:22000/udp"
      - "21027:21027/udp"  # local discovery
    volumes:
      - /mnt/storage/_appdata/syncthing:/config
      - /mnt/storage/sync:/data
EOF
    cd /opt/stacks/syncthing
    sudo docker compose up -d
); then
    mark_ok "SYNCTHING" "http://$(hostname).local:8384"
else
    mark_fail "SYNCTHING" "docker compose failed"
fi
