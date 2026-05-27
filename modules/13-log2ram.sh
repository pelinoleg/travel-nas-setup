[[ -n "${DO_LOG2RAM:-}" ]] || return 0

info "=== Log2ram ==="
if (
    set -e
    if ! dpkg -l | grep -q log2ram; then
        # Auto-detect distro codename (trixie / bookworm / bullseye)
        CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
        [[ -z "$CODENAME" ]] && CODENAME="trixie"
        echo "deb http://packages.azlux.fr/debian/ $CODENAME main" | \
            sudo tee /etc/apt/sources.list.d/azlux.list
        sudo wget -qO /etc/apt/trusted.gpg.d/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
        apt_get update
        apt_install log2ram
    fi
); then
    mark_ok "LOG2RAM"
else
    mark_fail "LOG2RAM" "install failed"
fi
