# Generic docker-стек установщик. Стеки — файлы в stacks/<name>/:
#   compose.yaml  — сам compose (Dockge редактирует его в /opt/stacks/<name>/)
#   meta.conf     — LABEL="..." PORT=NNNN  (для wizard + mark_ok)
#   setup.sh      — опц. хуки stack_pre()/stack_post() (папки/права/конфиг/.env/units)
#
# Деплоит выбранные (DO_STACK_<NAME>) в /opt/stacks/<name>/ → docker compose up -d.
# Dockge (/opt/dockge, :5001) видит их автоматически. Добавить приложение =
# папка в stacks/ + строка в stacks/index.txt — НОВЫЙ МОДУЛЬ НЕ НУЖЕН.

STACKS_SRC="${SETUP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/stacks"
[[ -f "$STACKS_SRC/index.txt" ]] || return 0

while read -r name; do
    name="${name%%#*}"; name="$(echo "$name" | xargs)"
    [[ -n "$name" ]] || continue
    flag="DO_STACK_$(echo "$name" | tr '[:lower:]-' '[:upper:]_')"
    [[ -n "${!flag:-}" ]] || continue   # не выбран в wizard'е

    src="$STACKS_SRC/$name"
    if [[ ! -f "$src/compose.yaml" ]]; then
        mark_fail "STACK:$name" "нет compose.yaml"; continue
    fi
    LABEL="$name"; PORT=""
    # shellcheck source=/dev/null
    source "$src/meta.conf" 2>/dev/null || true

    info "=== Stack: $LABEL ==="
    if ! command -v docker &>/dev/null; then
        mark_fail "STACK:$name" "Docker не установлен (отметь DOCKER)"; continue
    fi

    if (
        set -e
        STACK_DIR="/opt/stacks/$name"
        sudo mkdir -p "$STACK_DIR"
        # Дефолтные пустые хуки; setup.sh переопределит при наличии.
        stack_pre()  { :; }
        stack_post() { :; }
        # shellcheck source=/dev/null
        [[ -f "$src/setup.sh" ]] && source "$src/setup.sh"
        stack_pre                                  # папки/права/конфиг/.env
        sudo cp "$src/compose.yaml" "$STACK_DIR/compose.yaml"
        cd "$STACK_DIR"
        sudo docker compose up -d                  # .env подхватится автоматически
        stack_post                                 # docker exec / systemd units
    ); then
        mark_ok "STACK:$name" "http://$(hostname).local${PORT:+:$PORT}"
    else
        mark_fail "STACK:$name" "deploy failed"
    fi
done < "$STACKS_SRC/index.txt"
