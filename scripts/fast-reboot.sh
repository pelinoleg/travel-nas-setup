#!/bin/bash
# =============================================================================
# fast-reboot.sh — canonical reboot с pre-umount диска
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

# Pre-umount диска (известный блокер на Pi 5)
fuser -km /mnt/storage 2>/dev/null || true
sync
umount -l /mnt/storage 2>/dev/null || true

exec systemctl reboot
