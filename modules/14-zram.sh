[[ -n "${DO_ZRAM:-}" ]] || return 0

info "=== ZRAM ==="
if ! dpkg -l | grep -q zram-tools; then
    wait_for_apt
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools || warn "zram-tools install failed"
fi
sudo sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null || true
sudo sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null || true

if sudo systemctl restart zramswap 2>/dev/null; then
    mark_ok "ZRAM" "zstd, 50%"
else
    warn "zramswap не запустился (PiOS уже использует встроенный zram — это норма)"
    mark_ok "ZRAM" "уже работает (встроенный)"
fi

if [[ -f /etc/sysctl.conf ]] && ! grep -q "vm.swappiness" /etc/sysctl.conf; then
    echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf > /dev/null
    sudo sysctl -p > /dev/null 2>&1 || true
fi
