[[ -n "${DO_LOG2RAM:-}" ]] || return 0

info "=== Log2ram ==="
if (
    set -e
    if ! dpkg -l | grep -q log2ram; then
        echo "deb http://packages.azlux.fr/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/azlux.list
        sudo wget -qO /etc/apt/trusted.gpg.d/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get update
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y log2ram
    fi
); then
    mark_ok "LOG2RAM"
else
    mark_fail "LOG2RAM" "install failed"
fi
