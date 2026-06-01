#!/bin/bash
# =============================================================================
# fix-conf-perms.sh — восстанавливает owner/mode конфигов в /etc/travel-nas/
# =============================================================================
# Триггерится systemd path-unit'ом при любом изменении файла в директории.
# Когда юзер правит через Filebrowser (контейнер пишет от своего uid, оставляет
# чужие owner/mode), скрипт возвращает корректные права чтобы:
#   - dashboard мог писать обратно (Mode toggle на странице Thermal)
#   - конфиги с секретами (tg-notify, nas-backup) оставались 600
#
# Запускается как root через systemd (path-unit). Сам по себе ничего не
# делает кроме лога если все права уже правильные.
# =============================================================================

set -u

CONF_DIR="/etc/travel-nas"
LOG="/var/lib/travel-nas/fix-conf-perms.log"
# Юзер = первый человек, созданный Pi Imager'ом (uid 1000). Не хардкодим имя —
# скрипт работает при любом имени, заданном при прошивке.
TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
[[ -z "$TARGET_USER" ]] && TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null)}"
[[ -z "$TARGET_USER" ]] && TARGET_USER="root"

# Кто должен быть owner и какие права. Формат "owner:group mode".
# Файлы с секретами (passwords/tokens) → 600. Остальные 644.
declare -A SPECS=(
    [tg-notify.conf]="$TARGET_USER:$TARGET_USER 600"
    [nas-backup.conf]="$TARGET_USER:$TARGET_USER 600"
    [filebrowser.conf]="$TARGET_USER:$TARGET_USER 600"
    [services.conf]="$TARGET_USER:$TARGET_USER 644"
    [thermal-guard.conf]="$TARGET_USER:$TARGET_USER 644"
    [photo-backup.conf]="$TARGET_USER:$TARGET_USER 644"
    [yt-archiver.conf]="$TARGET_USER:$TARGET_USER 644"
    [cpu-boost.conf]="$TARGET_USER:$TARGET_USER 644"
    [storage-info.conf]="$TARGET_USER:$TARGET_USER 644"
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
