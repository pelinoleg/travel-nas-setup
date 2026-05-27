[[ -n "${DO_UPDATE:-}" ]] || return 0

info "=== Update ==="
if (
    set -e
    # apt-daily.service / unattended-upgrades могут уже бегать на свежем
    # PiOS — ждём их без падения.
    wait_for_apt
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    wait_for_apt
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
); then
    mark_ok "UPDATE" "apt upgrade OK"
else
    mark_fail "UPDATE" "apt update/upgrade failed"
fi
