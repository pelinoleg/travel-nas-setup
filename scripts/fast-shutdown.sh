#!/bin/bash
# =============================================================================
# fast-shutdown.sh — гарантированный shutdown с hard-fallback
# =============================================================================
# Юзер: 'когда пытался вырубить, начал потом остановился на терминале и
# затряс. пришлось выдернуть шнур. хочу чтоб если нажал — вырубить.'
#
# Проблема: `systemctl poweroff` ждёт graceful stop всех сервисов
# (Docker, Samba, NM с дефолтным TimeoutStopSec=90s каждый). Если что-то
# висит — застревает.
#
# Стратегия:
# 1. Параллельно: docker stop с timeout 5s (быстро прибить контейнеры)
# 2. systemctl poweroff в фоне
# 3. Hard-fallback через 20 сек: SysRq O — kernel-level power-off, гарантированно
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# 1) Прибиваем docker'ы (если есть) с коротким timeout'ом — Docker stop с 90s
# дефолтом основная причина зависаний.
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 5 docker stop -t 3 2>/dev/null &
fi

# 2) Хард-стоп rsync/backup (если активны) — иначе T7 unmount висит
pkill -TERM rsync 2>/dev/null
systemctl stop nas-backup-runtime 2>/dev/null

# Маленькая пауза чтобы docker stop успел дойти до большинства контейнеров
sleep 2

# 3) Hard-fallback арм: SysRq через 20 сек если ещё живы.
# Это RAW kernel power-off — не даёт ни fsck'у ни сервисам время.
# Acceptable trade-off: юзер сказал "хочу гарантированно выключить".
(
    sleep 20
    # Если мы досюда дошли — graceful poweroff не сработал. Forcing.
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null     # sync filesystems
    sleep 1
    echo u > /proc/sysrq-trigger 2>/dev/null     # remount RO
    sleep 1
    echo o > /proc/sysrq-trigger 2>/dev/null     # power off
) &

# 4) Основной путь — graceful poweroff
# --force = skip stopping units gracefully (быстрее), --no-wall = не флудить
exec systemctl poweroff --force --no-wall
