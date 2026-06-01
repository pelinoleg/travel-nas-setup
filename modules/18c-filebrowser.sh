[[ -n "${DO_FILEBROWSER:-}" ]] || return 0

# Filebrowser — web файл-менеджер + редактор конфигов. :8082.
# Монтирует весь диск (/srv/storage) и /etc/travel-nas (/srv/config) для правки
# конфигов через веб. PUID/PGID=1000 — чтобы читать/писать 600-секреты (owner
# uid 1000). CONF_PERMS path-unit вернёт правильные права после правки.
# Креды (FB_USER/FB_PASS) — из /etc/travel-nas/filebrowser.conf (НЕ в репо).
info "=== Filebrowser ==="
if ! command -v docker &>/dev/null; then
    mark_fail "FILEBROWSER" "Docker не установлен (сначала DOCKER)"
elif (
    set -e
    sudo mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/filebrowser.conf" ]]; then
        fetch_conf_example "filebrowser.conf.example" "$CONFIG_DIR/filebrowser.conf"
    fi
    sudo chown "$(whoami):$(whoami)" "$CONFIG_DIR/filebrowser.conf"
    sudo chmod 0600 "$CONFIG_DIR/filebrowser.conf"
    FB_USER=""; FB_PASS=""
    # shellcheck source=/dev/null
    source "$CONFIG_DIR/filebrowser.conf" 2>/dev/null || true
    [[ -z "$FB_USER" ]] && FB_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
    [[ -z "$FB_USER" ]] && FB_USER="admin"
    [[ -z "$FB_PASS" ]] && FB_PASS="changeme"

    sudo install -d -o 1000 -g 1000 /mnt/storage/_appdata/filebrowser

    sudo mkdir -p /opt/stacks/filebrowser
    sudo tee /opt/stacks/filebrowser/compose.yaml >/dev/null << 'EOF'
name: filebrowser
services:
  filebrowser:
    image: filebrowser/filebrowser:s6
    container_name: filebrowser
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
    ports:
      - "8082:80"
    volumes:
      - /mnt/storage:/srv/storage          # файлы диска
      - /etc/travel-nas:/srv/config        # конфиги (правка через веб)
      - /mnt/storage/_appdata/filebrowser:/database
EOF
    cd /opt/stacks/filebrowser
    sudo docker compose up -d
    # Дождаться инициализации БД (дефолтный admin), затем выставить наши креды.
    for _ in 1 2 3 4 5 6 7 8; do
        sudo docker exec filebrowser filebrowser users ls >/dev/null 2>&1 && break
        sleep 2
    done
    sudo docker exec filebrowser filebrowser users add "$FB_USER" "$FB_PASS" --perm.admin 2>/dev/null \
        || sudo docker exec filebrowser filebrowser users update "$FB_USER" --password "$FB_PASS" 2>/dev/null || true
    # Снести дефолтного admin/admin если наш юзер другой.
    [[ "$FB_USER" != "admin" ]] && sudo docker exec filebrowser filebrowser users rm admin 2>/dev/null || true
); then
    mark_ok "FILEBROWSER" "http://$(hostname).local:8082"
else
    mark_fail "FILEBROWSER" "docker compose failed"
fi
