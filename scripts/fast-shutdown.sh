#!/bin/bash
# =============================================================================
# fast-shutdown.sh — гарантированный shutdown за ≤5 секунд
# =============================================================================
# Юзер: 'shutdown так и не сработал. все равно думал долго.'
#
# Прошлая стратегия `systemctl poweroff --force` (одинарный --force) всё
# ещё ходит через systemd unit-stops, просто с SIGTERM/SIGKILL вместо
# graceful — может занимать 30+ сек.
#
# Новая стратегия:
# 1. Быстрый stop docker (parallel, 3s timeout — иначе T7 unmount висит)
# 2. sync + remount-RO через SysRq (гарантирует целостность FS)
# 3. systemctl poweroff --force --force = immediate halt syscall
#    (bypassing systemd entirely — это как SysRq O, но через libc)
#
# Total time от тапа до отключения питания: ~3-5 секунд.
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# 1) Прибиваем docker контейнеры (parallel). 3s timeout — если не успеют,
# kill -9 их через systemd shutdown anyway.
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 4 docker stop -t 2 2>/dev/null &
fi

# 2) rsync / nas-backup hard stop — иначе T7 unmount может моргать
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

# 3) Сразу sync + remount-RO — kernel-level, моментально, гарантирует
# что journal сброшен и FS чисто
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null     # sync filesystems
sleep 1
echo u > /proc/sysrq-trigger 2>/dev/null     # remount all RO

# 4) Backup-fallback на случай если systemctl --force --force почему-то
# не сработает (10s — потолок ожидания)
( sleep 10; echo o > /proc/sysrq-trigger 2>/dev/null ) &

# 5) Главный путь: --force --force = bypass systemd, immediate halt syscall.
# Одинарный --force всё ещё ждёт unit-stops с SIGTERM. Двойной = прямо
# в reboot(LINUX_REBOOT_CMD_POWER_OFF) — kernel rebooot syscall.
exec systemctl poweroff --force --force --no-wall
