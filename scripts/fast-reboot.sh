#!/bin/bash
# =============================================================================
# fast-reboot.sh — то же что fast-shutdown но reboot (≤5 сек)
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 4 docker stop -t 2 2>/dev/null &
fi
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null     # sync
sleep 1
echo u > /proc/sysrq-trigger 2>/dev/null     # remount RO

# Backup-fallback на 10 сек если основной путь не сработает
( sleep 10; echo b > /proc/sysrq-trigger 2>/dev/null ) &

# --force --force = bypass systemd, immediate reboot syscall
exec systemctl reboot --force --force --no-wall
