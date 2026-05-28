#!/bin/bash
# =============================================================================
# fast-reboot.sh — canonical reboot, как LXDE menu
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
exec systemctl reboot
