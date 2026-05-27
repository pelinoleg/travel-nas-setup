[[ -n "${DO_CASAOS:-}" ]] || return 0

info "=== CasaOS ==="
if command -v casaos-cli &>/dev/null; then
    mark_ok "CASAOS" "уже установлен"
else
    warn "Установка CasaOS, ~10 минут..."
    if (
        set -e
        if ! command -v curl &>/dev/null; then
            wait_for_apt
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl
        fi
        # CasaOS installer внутри сам делает apt-операции — ждём lock первым
        wait_for_apt
        curl -fsSL https://get.casaos.io | sudo bash
    ); then
        mark_ok "CASAOS" "http://travel-nas.local"
    else
        mark_fail "CASAOS" "install script failed"
    fi
fi

# Защита fstab-устройств от перехвата devmon (CasaOS поставил devmon)
if [[ -f /etc/conf.d/devmon ]] && command -v findmnt &>/dev/null; then
    FSTAB_DEVS=$(awk '/^UUID=/ {print $2}' /etc/fstab | while read mp; do
        findmnt -n -o SOURCE "$mp" 2>/dev/null || true
    done | grep -E '^/dev/' | sort -u)

    for dev in $FSTAB_DEVS; do
        if ! grep -q "ignore-device $dev" /etc/conf.d/devmon; then
            sudo sed -i "s|ARGS=\"\(.*\)\"|ARGS=\"\1 --ignore-device $dev\"|" /etc/conf.d/devmon
        fi
    done
    sudo systemctl restart devmon@devmon.service 2>/dev/null || true
fi
