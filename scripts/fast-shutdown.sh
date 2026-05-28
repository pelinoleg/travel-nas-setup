#!/bin/bash
# =============================================================================
# fast-shutdown.sh — гарантированный shutdown за ~5 секунд
# =============================================================================
# Юзер: 'нажал shutdown и всё зависло' (предыдущая версия делала
# SysRq remount-RO ПЕРЕД systemctl — после этого systemd не мог
# нормально завершиться).
#
# Новая стратегия — НЕ трогаем FS до halt'а:
# 1. docker stop в фоне (best-effort, не блокируем)
# 2. exec systemctl poweroff --force --force = immediate halt syscall
# 3. Если за 8 секунд не halt — SysRq emergency (sync → power off)
# =============================================================================

set -u

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

# 1) Best-effort docker stop — параллельно, не блокируем
if command -v docker >/dev/null 2>&1; then
    docker ps -q 2>/dev/null | xargs -r timeout 3 docker stop -t 1 2>/dev/null &
fi

# 2) Fallback: SysRq emergency через 8 сек если halt не сработал.
# Здесь делаем remount-RO потому что halt syscall уже не выполнился —
# нужен kernel-level хард.
(
    sleep 8
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    echo s > /proc/sysrq-trigger 2>/dev/null     # sync
    sleep 1
    echo u > /proc/sysrq-trigger 2>/dev/null     # remount RO
    sleep 1
    echo o > /proc/sysrq-trigger 2>/dev/null     # power off
) &

# 3) Основной путь: --force --force = halt syscall напрямую.
# Не трогаем FS заранее — systemd сам делает sync через halt(2) syscall.
exec systemctl poweroff --force --force
