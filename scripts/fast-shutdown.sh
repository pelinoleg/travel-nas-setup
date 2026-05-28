#!/bin/bash
# =============================================================================
# fast-shutdown.sh — canonical Pi 5 shutdown с pre-stop docker
# =============================================================================
# Урок: Pi 5 poweroff занимает ~10-30 сек штатно — ждёт NVMe/hardware
# power-down. Это by design, не баг. Попытки использовать --force --force
# дают halt syscall но плата остаётся в standby (красная LED активна).
#
# Правильно:
# 1. Pre-stop docker чтобы не висел 90s в TimeoutStopSec
# 2. systemctl poweroff (без --force) = canonical Pi shutdown
# 3. POWER_OFF_ON_HALT=1 в /boot/firmware/config.txt → красная LED тоже
#    гаснет, плата полностью обесточивается. Это ставит setup-модуль.
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# 1) Pre-stop docker контейнеров (parallel, best-effort) — главная причина
# 90-сек задержки systemctl poweroff если их не остановить заранее
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 5 docker stop -t 3 2>/dev/null &
fi

# 2) Стоп длительных backup'ов — rsync через samba может висеть до 90s
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

# Маленькая пауза чтоб docker stop успел дойти
sleep 2

# 3) Canonical Pi shutdown. Не --force — он не помогает на Pi 5 и
# рискует data loss. По умолчанию ~10-15 сек после docker pre-stop.
exec systemctl poweroff
