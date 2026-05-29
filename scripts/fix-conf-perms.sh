#!/bin/bash
# =============================================================================
# fix-conf-perms.sh — восстанавливает owner/mode конфигов в /etc/travel-nas/
# =============================================================================
# Триггерится systemd path-unit'ом при любом изменении файла в директории.
# Когда юзер правит через CasaOS Files (он бежит от root, оставляет файлы
# root:root 644), скрипт возвращает корректные права чтобы:
#   - dashboard мог писать обратно (Mode toggle на странице Thermal)
#   - конфиги с секретами (tg-notify, nas-backup) оставались 600
#
# Запускается как root через systemd (path-unit). Сам по себе ничего не
# делает кроме лога если все права уже правильные.
# =============================================================================

set -u

CONF_DIR="/etc/travel-nas"
LOG="/var/lib/travel-nas/fix-conf-perms.log"
TARGET_USER="oleg"

# Кто должен быть owner и какие права. Формат "owner:group mode".
# Файлы с секретами (passwords/tokens) → 600. Остальные 644.
declare -A SPECS=(
    [tg-notify.conf]="oleg:oleg 600"
    [nas-backup.conf]="oleg:oleg 600"
    [services.conf]="oleg:oleg 644"
    [thermal-guard.conf]="oleg:oleg 644"
    [photo-backup.conf]="oleg:oleg 644"
    [power-mode.conf]="oleg:oleg 644"
    [yt-archiver.conf]="oleg:oleg 644"
    [t7-info.conf]="oleg:oleg 644"
)

mkdir -p "$(dirname "$LOG")" 2>/dev/null
fixed=0
checked=0

for fname in "${!SPECS[@]}"; do
    p="$CONF_DIR/$fname"
    [[ -f "$p" ]] || continue
    checked=$((checked + 1))
    read -r want_owner want_mode <<<"${SPECS[$fname]}"
    cur=$(stat -c "%U:%G %a" "$p")
    want="$want_owner $want_mode"
    if [[ "$cur" != "$want" ]]; then
        if chown "$want_owner" "$p" 2>/dev/null && chmod "$want_mode" "$p" 2>/dev/null; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] fixed $fname: $cur → $want" >> "$LOG"
            fixed=$((fixed + 1))
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED $fname: chown/chmod error" >> "$LOG"
        fi
    fi
done

# Тихо если ничего не делали — иначе спамим лог при каждом изменении.
if (( fixed > 0 )); then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] summary: checked=$checked fixed=$fixed" >> "$LOG"
fi
