#!/bin/bash
# =============================================================================
# fast-reboot.sh — то же что fast-shutdown но reboot вместо poweroff
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 5 docker stop -t 3 2>/dev/null &
fi
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null
sleep 2

(
    sleep 20
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null
    sleep 1
    echo u > /proc/sysrq-trigger 2>/dev/null
    sleep 1
    echo b > /proc/sysrq-trigger 2>/dev/null  # b = reboot
) &

exec systemctl reboot --force --no-wall
