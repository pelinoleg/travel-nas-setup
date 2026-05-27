[[ -n "${DO_HOSTNAME:-}" ]] || return 0

info "=== Hostname ==="
if (
    set -e
    CURRENT_HOST=$(hostname)
    if [[ "$CURRENT_HOST" != "travel-nas" ]]; then
        sudo hostnamectl set-hostname travel-nas
        sudo sed -i "s/127.0.1.1\s*$CURRENT_HOST/127.0.1.1\ttravel-nas/" /etc/hosts
    fi
); then
    mark_ok "HOSTNAME" "travel-nas"
else
    mark_fail "HOSTNAME" "hostnamectl failed"
fi
