#!/bin/bash
# =============================================================================
# fast-reboot.sh — то же что fast-shutdown но reboot
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 3 docker stop -t 1 2>/dev/null &
fi

# Fallback SysRq через 8 сек
(
    sleep 8
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
    sleep 1
    echo u > /proc/sysrq-trigger 2>/dev/null
    sleep 1
    echo b > /proc/sysrq-trigger 2>/dev/null   # b = reboot
) &

exec systemctl reboot --force --force
