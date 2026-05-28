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
#   docker-mgr.sh audit            — диагностика UID-mismatch в bind mounts
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
    audit)
        # Текстовый отчёт mismatches между container UID и host owner для
        # bind mount'ов. Только rw mode + non-root container внутри.
        # ro и root-внутри пропускаем (не могут привести к 'permission denied').
        ISSUES=0
        for C in $(docker ps --format '{{.Names}}'); do
            UID_IN=$(docker exec "$C" id -u 2>/dev/null || echo "")
            [[ -z "$UID_IN" || "$UID_IN" == "0" ]] && continue
            while IFS='|' read -r SRC DST MODE; do
                [[ -z "$SRC" ]] && continue
                [[ "$MODE" == "ro" || "$MODE" == *",ro"* ]] && continue
                HOST_UID=$(stat -c "%u" "$SRC" 2>/dev/null || echo "?")
                [[ "$UID_IN" == "$HOST_UID" ]] && continue
                ISSUES=$((ISSUES + 1))
                echo "⚠️  $C (uid=$UID_IN) cannot write to $SRC (owner=$HOST_UID)"
                echo "   fix:  sudo chown -R $UID_IN:$UID_IN $SRC"
                echo ""
            done < <(docker inspect "$C" --format \
                '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}|{{.Mode}}{{println}}{{end}}{{end}}' \
                2>/dev/null)
        done
        if (( ISSUES == 0 )); then
            echo "✓ Все running-контейнеры have matching bind-mount permissions."
        else
            echo "Найдено проблем: $ISSUES"
        fi
        ;;
    *)
        echo "Usage: $0 [list|status|start|stop|restart|audit] [name]" >&2
        exit 1
        ;;
esac
