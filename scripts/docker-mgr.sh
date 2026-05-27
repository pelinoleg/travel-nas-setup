#!/bin/bash
# =============================================================================
# docker-mgr.sh — обёртка docker compose для tg-listener и dashboard
# =============================================================================
# Зачем wrapper: NOPASSWD: docker compose ... сложно прописать в sudoers
# из-за длинных аргументов. Через один short-path easier.
#
# Команды:
#   docker-mgr.sh list             — JSON со списком compose-проектов
#   docker-mgr.sh status           — то же что list (alias)
#   docker-mgr.sh start <name>     — docker compose up -d
#   docker-mgr.sh stop <name>      — docker compose stop
#   docker-mgr.sh restart <name>   — docker compose restart
# =============================================================================

set -u

ACTION="${1:-list}"

case "$ACTION" in
    list|status)
        # docker compose ls возвращает JSON с Name, Status, ConfigFiles
        docker compose ls --all --format json 2>/dev/null || echo "[]"
        ;;
    start|stop|restart)
        NAME="${2:-}"
        [[ -z "$NAME" ]] && { echo "Usage: $0 $ACTION <project-name>" >&2; exit 1; }
        # Найти compose-файл проекта
        CF=$(docker compose ls --all --format json 2>/dev/null \
            | jq -r --arg n "$NAME" '.[] | select(.Name==$n) | .ConfigFiles' \
            | head -1)
        if [[ -z "$CF" ]]; then
            echo "Project '$NAME' not found" >&2
            exit 1
        fi
        case "$ACTION" in
            start)   docker compose -f "$CF" up -d ;;
            stop)    docker compose -f "$CF" stop ;;
            restart) docker compose -f "$CF" restart ;;
        esac
        ;;
    *)
        echo "Usage: $0 [list|status|start|stop|restart] [name]" >&2
        exit 1
        ;;
esac
