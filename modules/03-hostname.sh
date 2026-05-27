[[ -n "${DO_HOSTNAME:-}" ]] || return 0

info "=== Hostname ==="
if (
    set -e
    CURRENT_HOST=$(hostname)
    if [[ "$CURRENT_HOST" != "travel-nas" ]]; then
        sudo hostnamectl set-hostname travel-nas
        # Заменяем строку со старым хостнеймом, если есть
        sudo sed -i "s/127.0.1.1\s*$CURRENT_HOST/127.0.1.1\ttravel-nas/" /etc/hosts
    fi
    # Гарантируем что travel-nas есть в /etc/hosts (иначе sudo жалуется
    # "unable to resolve host travel-nas")
    if ! grep -qE "^[[:space:]]*127\.0\.1\.1[[:space:]]+travel-nas\b" /etc/hosts; then
        echo "127.0.1.1	travel-nas" | sudo tee -a /etc/hosts >/dev/null
    fi
); then
    mark_ok "HOSTNAME" "travel-nas"
else
    mark_fail "HOSTNAME" "hostnamectl failed"
fi
