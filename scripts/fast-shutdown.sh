#!/bin/bash
# =============================================================================
# fast-shutdown.sh — canonical Pi 5 shutdown с pre-umount диска
# =============================================================================
# Известная проблема: Pi 5 + USB-SSD hangs на "Reached target system
# power off" — USB-bridge долго отключается, kernel ждёт.
#
# Workaround: lazy umount диска + kill процессов держащих его ДО systemctl
# poweroff. systemd-shutdown тогда не упрётся в "невозможно отмонтировать".
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# 1) Pre-stop docker (parallel)
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 5 docker stop -t 3 2>/dev/null &
fi

# 2) Прибиваем длинные rsync
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

# Дать docker пару секунд
sleep 2

# 3) Жёстко прибить процессы на диска — иначе umount не сработает
fuser -km /mnt/storage 2>/dev/null || true

# 4) Lazy umount диска — освобождает USB-bridge для firmware power-down
sync
umount -l /mnt/storage 2>/dev/null || true

# 5) systemctl poweroff — теперь без SSD-hang'а
exec systemctl poweroff
