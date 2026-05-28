#!/bin/bash
# =============================================================================
# fast-shutdown.sh — то что делает LXDE Shutdown menu, без эзотерики
# =============================================================================
# Юзер прямо сказал: 'в системе же есть пункты меню по вырубанию.
# мы не можем их вызвать просто?'
#
# LXDE Shutdown через menu вызывает logind через DBus, который дёргает
# systemd poweroff.target. То же самое что `systemctl poweroff`.
#
# Стратегия:
# 1. Pre-stop docker (главный тормоз 90s default TimeoutStopSec)
# 2. systemctl poweroff — canonical Pi путь, точно как LXDE
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# Pre-stop docker (parallel, не блокирует)
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 5 docker stop -t 3 2>/dev/null &
fi

# Стоп текущих rsync (T7 umount иначе виснет)
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

sleep 2
exec systemctl poweroff
