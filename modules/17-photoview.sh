[[ -n "${DO_PHOTOVIEW:-}" ]] || return 0

# В UI Photoview добавляй пути /t7/usb-imports или /t7/media — это пути ВНУТРИ
# контейнера. Mount только read-only — гарантия что галерея ничего не сотрёт.
info "=== Photoview ==="
if ! command -v docker &>/dev/null; then
    mark_fail "PHOTOVIEW" "Docker не установлен (сначала CASAOS)"
elif (
    set -e
    sudo mkdir -p /opt/photoview

    # Photoview контейнер работает от UID 999 (photoview user). mariadb
    # внутри тоже drops to UID 999 (mysql user). Если host-папки cache/db
    # не принадлежат 999:999 — контейнер не может писать туда →
    # 'mkdir /app/cache/15: permission denied' → thumbnails не генерятся
    # → UI выдаёт 'record not found at (media)' при попытке открыть фото.
    #
    # Решение: явный chown перед docker compose up. install -d создаёт
    # папку (если нет) с указанным владельцем и режимом.
    sudo install -d -o 999 -g 999 -m 0755 /opt/photoview/cache
    sudo install -d -o 999 -g 999 -m 0755 /opt/photoview/db

    sudo tee /opt/photoview/docker-compose.yml > /dev/null << EOF
# Photoview app + MariaDB
# В UI Photoview добавляй путь /t7/usb-imports или /t7/media — это пути
# ВНУТРИ контейнера (мы монтируем /mnt/t7 как /t7:ro). Указать /mnt/t7/...
# не получится — внутри контейнера такого пути не существует.
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
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 20
      start_period: 30s

  photoview:
    image: viktorstrate/photoview:latest
    restart: unless-stopped
    ports:
      - "8000:80"
    # Ждём пока MariaDB реально ответит — иначе первый GraphQL initialSetup
    # фейлится с "internal system error" на медленной SD-карте.
    depends_on:
      db:
        condition: service_healthy
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
    mark_ok "PHOTOVIEW" "http://pi.local:8000 (UI path: /t7/usb-imports)"
else
    mark_fail "PHOTOVIEW" "docker compose failed"
fi
