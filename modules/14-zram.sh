[[ -n "${DO_ZRAM:-}" ]] || return 0

info "=== ZRAM ==="
if ! dpkg -l | grep -q zram-tools; then
    apt_install zram-tools || warn "zram-tools install failed"
fi
sudo sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null || true
sudo sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null || true

if sudo systemctl restart zramswap 2>/dev/null; then
    mark_ok "ZRAM" "zstd, 50%"
else
    # На Trixie /dev/zram0 уже держит встроенный zram (systemd-zram-generator)
    # → zramswap падает с 'Device or resource busy' и висит failed-юнитом
    # (мозолит глаза в Failed-панели/алертах). Встроенный zram и так работает —
    # отключаем дублирующий zramswap и чистим failed-состояние.
    sudo systemctl disable --now zramswap 2>/dev/null || true
    sudo systemctl reset-failed zramswap 2>/dev/null || true
    warn "zramswap отключён — встроенный zram (zram0) уже активен"
    mark_ok "ZRAM" "встроенный zram (zramswap отключён)"
fi

if [[ -f /etc/sysctl.conf ]] && ! grep -q "vm.swappiness" /etc/sysctl.conf; then
    echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf > /dev/null
    sudo sysctl -p > /dev/null 2>&1 || true
fi
