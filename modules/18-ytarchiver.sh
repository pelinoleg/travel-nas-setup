[[ -n "${DO_YTARCHIVER:-}" ]] || return 0

# Compose-файл кладётся в /var/lib/casaos/apps/ytarchiver/ — CasaOS подхватывает
# его автоматически благодаря x-casaos метаданным.
# Backend в исходном compose публиковал порт 8000 (как Photoview). Это вызвало
# бы конфликт → выкинули из ports. Frontend (8081) ходит к backend через
# docker network ytarchiver_net.
info "=== YT-Archiver ==="
if ! command -v docker &>/dev/null; then
    mark_fail "YTARCHIVER" "Docker не установлен (сначала CASAOS)"
elif (
    set -e
    # Папки данных на T7 — bind mount внутрь контейнера. Владелец $(whoami)
    # чтобы yt-dlp процессы могли писать.
    sudo install -d -o "$(whoami)" -g "$(whoami)" /mnt/t7/media/YT-Archiver/data
    sudo install -d -o "$(whoami)" -g "$(whoami)" /mnt/t7/media/YT-Archiver/video

    APP_DIR=/var/lib/casaos/apps/ytarchiver
    sudo mkdir -p "$APP_DIR"
    sudo tee "$APP_DIR/docker-compose.yml" >/dev/null << 'EOF'
name: ytarchiver
services:
  backend:
    image: ghcr.io/pelinoleg/ytarchiver-backend:latest
    container_name: ytarchiver-backend
    hostname: ytarchiver-backend
    restart: unless-stopped
    cpu_shares: 90
    deploy:
      resources:
        limits:
          memory: "8453619712"
    environment:
      BETWEEN_DOWNLOADS_MAX_SECONDS: "15"
      BETWEEN_DOWNLOADS_MIN_SECONDS: "5"
      CORS_ORIGINS: "[*]"
      DATA_DIR: /data
      DB_PATH: /data/ytarchiver.db
      DEFAULT_PLAYBACK_RATE: "1.0"
      DEFAULT_QUALITY: "1080"
      DEFAULT_RETENTION_DAYS: "0"
      DELETE_AFTER_WATCHED_PERCENT: "0"
      DOWNLOAD_DIR: /downloads
      INITIAL_BACKFILL_HARD_CAP: "500"
      LOG_LEVEL: INFO
      MAX_VIDEOS_PER_CHANNEL_SCAN: "50"
      MINI_PLAYER_ENABLED: "true"
      MUSIC_PLAYBACK_RATE: "1.0"
      MUSIC_QUEUE_PANEL_SIZE: "100"
      PREVIEW_CRF: "27"
      PREVIEW_SEGMENTS: "12"
      PREVIEW_WIDTH: "480"
      SPONSORBLOCK_API: https://sponsor.ajay.app
      SPONSORBLOCK_REFRESH_DAYS: "7"
      SYNC_INTERVAL_MINUTES: "240"
      SYNC_JITTER_MINUTES: "60"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks:
      - ytarchiver_net
    labels:
      icon: https://upload.wikimedia.org/wikipedia/commons/0/09/YouTube_full-color_icon_%282017%29.svg
    volumes:
      - type: bind
        source: /mnt/t7/media/YT-Archiver/data
        target: /data
      - type: bind
        source: /mnt/t7/media/YT-Archiver/video
        target: /downloads
  frontend:
    image: ghcr.io/pelinoleg/ytarchiver-frontend:latest
    container_name: ytarchiver-frontend
    hostname: ytarchiver-frontend
    restart: unless-stopped
    cpu_shares: 90
    deploy:
      resources:
        limits:
          memory: "8453619712"
    depends_on:
      backend:
        condition: service_started
        required: true
    networks:
      - ytarchiver_net
    ports:
      - target: 80
        published: "8081"
        protocol: tcp
    labels:
      icon: https://raw.githubusercontent.com/pelinoleg/ytarchiver/main/icon.png

networks:
  ytarchiver_net:
    name: ytarchiver_ytarchiver_net
    driver: bridge

x-casaos:
  architectures: [amd64, arm64]
  author: pelinoleg
  category: Media
  description:
    en_us: Self-hosted YouTube video archiver (yt-dlp + FastAPI + React)
  developer: pelinoleg
  icon: https://raw.githubusercontent.com/pelinoleg/ytarchiver/main/icon.png
  index: /
  main: frontend
  port_map: "8081"
  scheme: http
  store_app_id: ytarchiver
  tagline:
    en_us: YouTube Archiver
  title:
    en_us: YT Archiver
EOF
    cd "$APP_DIR"
    sudo docker compose pull
    sudo docker compose up -d

    # Конфиг для дашборда — где брать stats. Юзер может менять URL если
    # переехал на другой порт/хост.
    sudo mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CONFIG_DIR/yt-archiver.conf" ]]; then
        fetch_conf_example "yt-archiver.conf.example" "$CONFIG_DIR/yt-archiver.conf"
    fi
    sudo chown "$(whoami):$(whoami)" "$CONFIG_DIR/yt-archiver.conf"
    sudo chmod 0644 "$CONFIG_DIR/yt-archiver.conf"
); then
    mark_ok "YTARCHIVER" "http://$(hostname).local:8081"
else
    mark_fail "YTARCHIVER" "docker compose failed"
fi
