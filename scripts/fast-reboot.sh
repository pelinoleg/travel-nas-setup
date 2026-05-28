#!/bin/bash
# =============================================================================
# fast-reboot.sh — canonical reboot с pre-umount T7
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

# Pre-umount T7 (известный блокер на Pi 5)
fuser -km /mnt/t7 2>/dev/null || true
sync
umount -l /mnt/t7 2>/dev/null || true

exec systemctl reboot
