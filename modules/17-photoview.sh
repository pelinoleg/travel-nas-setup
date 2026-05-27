[[ -n "${DO_PHOTOVIEW:-}" ]] || return 0

# В UI Photoview добавляй пути /t7/usb-imports или /t7/media — это пути ВНУТРИ
# контейнера. Mount только read-only — гарантия что галерея ничего не сотрёт.
info "=== Photoview ==="
if ! command -v docker &>/dev/null; then
    mark_fail "PHOTOVIEW" "Docker не установлен (сначала CASAOS)"
elif (
    set -e
    sudo mkdir -p /opt/photoview
    sudo tee /opt/photoview/docker-compose.yml > /dev/null << EOF
version: "3"
services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      - MYSQL_DATABASE=photoview
      - MYSQL_USER=photoview
      - MYSQL_PASSWORD=photoview
      - MYSQL_RANDOM_ROOT_PASSWORD=1
    volumes:
      - /opt/photoview/db:/var/lib/mysql

  photoview:
    image: viktorstrate/photoview:latest
    restart: unless-stopped
    ports:
      - "8000:80"
    depends_on:
      - db
    environment:
      - PHOTOVIEW_DATABASE_DRIVER=mysql
      - PHOTOVIEW_MYSQL_URL=photoview:photoview@tcp(db)/photoview
      - PHOTOVIEW_LISTEN_IP=0.0.0.0
      - PHOTOVIEW_LISTEN_PORT=80
      - PHOTOVIEW_MEDIA_CACHE=/app/cache
    volumes:
      - /opt/photoview/cache:/app/cache
      # Весь T7 как read-only — в UI указывай /t7/usb-imports, /t7/media и т.п.
      - $T7_MOUNT:/t7:ro
EOF
    cd /opt/photoview
    sudo docker compose up -d
); then
    mark_ok "PHOTOVIEW" "http://travel-nas.local:8000 (UI path: /t7/usb-imports)"
else
    mark_fail "PHOTOVIEW" "docker compose failed"
fi
