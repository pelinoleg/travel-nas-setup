#!/bin/bash
# =============================================================================
# fast-shutdown.sh — canonical Pi 5 shutdown + SysRq kernel fallback
# =============================================================================
# Стратегия:
# 1. Pre-stop docker — главная причина 90s TimeoutStopSec ожиданий
# 2. systemctl poweroff — canonical Pi путь (~10-15 сек после pre-stop)
# 3. SysRq O fallback через 20 сек: kernel emergency power-off если
#    systemd-shutdown завис на финальной стадии ('Reached target
#    system power off' но не halt'нулась)
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# 1) Pre-stop docker (parallel, best-effort)
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 5 docker stop -t 3 2>/dev/null &
fi

# 2) Стоп долгих backup'ов
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

# 3) SysRq emergency fallback в фоне (через 20 сек):
# Если систем штатно за это время не вырубилась — кернел делает hard
# power-off. Subprocess независим от main script, переживёт exec ниже.
# Если main path сработает быстрее — Pi уже off, SysRq subshell умрёт
# вместе с системой.
(
    sleep 20
    # Enable SysRq на всякий случай (на default уже разрешено)
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    # sync filesystems (защита от corruption)
    echo s > /proc/sysrq-trigger 2>/dev/null
    sleep 1
    # remount RO
    echo u > /proc/sysrq-trigger 2>/dev/null
    sleep 1
    # power off — emergency kernel halt
    echo o > /proc/sysrq-trigger 2>/dev/null
) &

# Маленькая пауза для docker stop
sleep 2

# 4) Canonical Pi shutdown. Без --force — он рискует data loss.
exec systemctl poweroff
