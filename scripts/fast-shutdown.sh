#!/bin/bash
# =============================================================================
# fast-shutdown.sh — canonical Pi 5 shutdown с pre-umount T7
# =============================================================================
# Известная проблема: Pi 5 + USB-SSD (T7) hangs на "Reached target system
# power off" — USB-bridge долго отключается, kernel ждёт.
#
# Workaround: lazy umount T7 + kill процессов держащих его ДО systemctl
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

# 3) Жёстко прибить процессы на T7 — иначе umount не сработает
fuser -km /mnt/t7 2>/dev/null || true

# 4) Lazy umount T7 — освобождает USB-bridge для firmware power-down
sync
umount -l /mnt/t7 2>/dev/null || true

# 5) systemctl poweroff — теперь без T7-hang'а
exec systemctl poweroff
