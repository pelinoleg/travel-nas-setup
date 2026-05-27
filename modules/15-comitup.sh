[[ -n "${DO_COMITUP:-}" ]] || return 0

info "=== Comitup (field WiFi) ==="
if (
    set -e
    if ! dpkg -l | grep -q "^ii.*comitup "; then
        # Чистим старые подходы которые не работают на Trixie
        sudo rm -f /etc/apt/sources.list.d/comitup.list 2>/dev/null || true
        sudo rm -f /etc/apt/trusted.gpg.d/davesteele-comitup-archive-keyring.gpg 2>/dev/null || true

        TMPDEB=$(mktemp --suffix=.deb)
        wget -qO "$TMPDEB" "https://davesteele.github.io/comitup/deb/davesteele-comitup-apt-source_1.3_all.deb"
        wait_for_apt
        sudo dpkg -i "$TMPDEB"
        rm -f "$TMPDEB"
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get update
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y comitup
    fi
); then
    mark_ok "COMITUP"
else
    mark_fail "COMITUP" "deb install failed"
fi
