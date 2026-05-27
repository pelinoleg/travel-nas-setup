[[ -n "${DO_PI_BACKUP:-}" ]] || return 0

info "=== Pi config backup ==="
if (
    set -e
    fetch_script "pi-config-backup.sh" "$SCRIPT_DIR/pi-config-backup.sh"
    CRON_LINE="0 3 * * 0 $SCRIPT_DIR/pi-config-backup.sh"
    if ! sudo crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/pi-config-backup.sh"; then
        (sudo crontab -l 2>/dev/null; echo "$CRON_LINE") | sudo crontab -
    fi
); then
    mark_ok "PI_BACKUP" "cron: воскр 03:00"
else
    mark_fail "PI_BACKUP" "cron failed"
fi
