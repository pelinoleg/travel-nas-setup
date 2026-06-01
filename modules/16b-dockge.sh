[[ -n "${DO_DOCKGE:-}" ]] || return 0

# Dockge — web-менеджер docker-compose стеков. Конвенция: стеки лежат в
# /opt/stacks/<name>/compose.yaml (наши модули кладут их туда + сами поднимают
# первый раз; Dockge подхватывает их в UI — тот же compose-проект). Сам Dockge
# живёт в /opt/dockge (НЕ в /opt/stacks, иначе пытался бы управлять собой).
# DOCKGE_STACKS_DIR обязан совпадать с host-путём bind-mount'а (Dockge
# перезапускает compose на хосте через docker.sock, пути должны быть идентичны).
info "=== Dockge ==="
if ! command -v docker &>/dev/null; then
    mark_fail "DOCKGE" "Docker не установлен (сначала DOCKER)"
elif (
    set -e
    sudo mkdir -p /opt/stacks /opt/dockge/data
    sudo tee /opt/dockge/compose.yaml >/dev/null << 'EOF'
name: dockge
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped
    ports:
      - "5001:5001"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/dockge/data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
EOF
    cd /opt/dockge
    sudo docker compose up -d
); then
    mark_ok "DOCKGE" "http://$(hostname).local:5001"
else
    mark_fail "DOCKGE" "docker compose failed"
fi
