[[ -n "${DO_PHOTOVIEW:-}" ]] || return 0

# В UI Photoview добавляй пути /storage/usb-imports или /storage/media — это пути ВНУТРИ
# контейнера. Mount только read-only — гарантия что галерея ничего не сотрёт.
info "=== Photoview ==="
if ! command -v docker &>/dev/null; then
    mark_fail "PHOTOVIEW" "Docker не установлен (сначала DOCKER)"
elif (
    set -e
    sudo mkdir -p /opt/stacks/photoview

    # cache+db живут на диске (а не /opt/) — переустановка системы не теряет
    # БД (1700+ scanned media, faces, favorites). Тяжёлые thumbnail-writes
    # тоже на SSD, а не убивают microSD.
    # UID 999 = mysql внутри mariadb / photoview user внутри photoview.
    APPDATA="$STORAGE_MOUNT/_appdata/photoview"
    sudo install -d -o 999 -g 999 -m 0755 "$APPDATA/cache"
    sudo install -d -o 999 -g 999 -m 0755 "$APPDATA/db"

    sudo tee /opt/stacks/photoview/compose.yaml > /dev/null << EOF
# Photoview app + MariaDB (Dockge-стек). name: обязателен — стабильное имя
# compose-проекта, чтобы docker-mgr/Dockge находили его независимо от каталога.
# В UI Photoview добавляй путь /storage/usb-imports или /storage/media — это пути
# ВНУТРИ контейнера (мы монтируем /mnt/storage как /storage:ro). Указать /mnt/storage/...
# не получится — внутри контейнера такого пути не существует.
name: photoview
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
      - $APPDATA/db:/var/lib/mysql
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
      - $APPDATA/cache:/app/cache
      # Весь диск как read-only — в UI указывай /storage/usb-imports, /storage/media и т.п.
      - $STORAGE_MOUNT:/storage:ro
EOF
    # .photoviewignore — Photoview-нативный механизм типа .gitignore. Кладём в
    # корень media-папки чтобы сканер игнорил RAW-форматы (на ARM darktable
    # thumbnail RAW = минуты CPU на файл, юзеру обычно нужно только JPG).
    sudo mkdir -p "$STORAGE_MOUNT/usb-imports"
    if [[ ! -f "$STORAGE_MOUNT/usb-imports/.photoviewignore" ]]; then
        fetch_conf_example "photoviewignore.example" "$STORAGE_MOUNT/usb-imports/.photoviewignore"
    fi
    sudo chmod 0644 "$STORAGE_MOUNT/usb-imports/.photoviewignore" 2>/dev/null || true

    cd /opt/stacks/photoview
    sudo docker compose up -d
    # Старый каталог CasaOS-эпохи. compose уже принят по name: photoview
    # (тот же проект + те же bind-mount данные) → можно убрать.
    sudo rm -rf /opt/photoview 2>/dev/null || true
); then
    mark_ok "PHOTOVIEW" "http://$(hostname).local:8000 (UI path: /storage/usb-imports)"
else
    mark_fail "PHOTOVIEW" "docker compose failed"
fi
