#!/bin/bash
# =============================================================================
# fast-reboot.sh — canonical Pi 5 reboot + SysRq kernel fallback
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

# SysRq fallback через 20 сек — kernel emergency reboot
(
    sleep 20
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null    # sync
    sleep 1
    echo u > /proc/sysrq-trigger 2>/dev/null    # remount RO
    sleep 1
    echo b > /proc/sysrq-trigger 2>/dev/null    # b = reboot (kernel)
) &

sleep 2
exec systemctl reboot
