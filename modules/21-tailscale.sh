[[ -n "${DO_TAILSCALE:-}" ]] || return 0

info "=== Tailscale (zero-config VPN) ==="
if (
    set -e

    # --- 1) Установка пакета (idempotent) ----------------------------------
    if ! command -v tailscale &>/dev/null; then
        info "Подкачиваю Tailscale apt-repo и устанавливаю пакет..."
        # Официальный one-liner — сам определит дистрибутив (PiOS = debian-derived)
        # и поставит keyring + sources.list.d + apt install.
        if ! curl -fsSL https://tailscale.com/install.sh | sudo sh; then
            err "Tailscale install.sh упал. Проверь интернет / DNS."
            exit 1
        fi
    else
        info "tailscale уже установлен ($(tailscale version | head -1))"
    fi

    # --- 2) Демон ----------------------------------------------------------
    sudo systemctl enable --now tailscaled

    # --- 3) Авторизация (если ещё не залогинены) ---------------------------
    # `tailscale status` exit-code 0 если есть валидный логин, !=0 если NeedsLogin.
    if sudo tailscale status &>/dev/null; then
        info "Tailscale уже авторизован: $(sudo tailscale ip -4 2>/dev/null | head -1)"
    else
        warn "Сейчас откроется URL для авторизации."
        warn "Открой его на телефоне/ноутбуке → залогинься (Google/GitHub) → Approve."
        warn "Это окно закроется автоматически после Approve."
        echo ""
        # --ssh: разрешает SSH через tailnet без password/keys между своими девайсами
        # --hostname: имя в tailnet (видно в админке https://login.tailscale.com)
        # --operator: $USER может читать status/ip без sudo (нужно дашборду)
        TS_HOSTNAME="$(hostname)"
        if ! sudo tailscale up --ssh --hostname="$TS_HOSTNAME" \
                --operator="$(whoami)" --accept-routes; then
            warn "tailscale up отменён / не завершился. Запусти позже вручную:"
            warn "  sudo tailscale up --ssh --hostname=$TS_HOSTNAME"
        fi
    fi

    # --- 4) Финал ----------------------------------------------------------
    TS_IP=$(sudo tailscale ip -4 2>/dev/null | head -1 || echo "")
    TS_DNS=$(sudo tailscale status --json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || echo "")
    if [[ -n "$TS_IP" ]]; then
        info "Tailscale IP:  $TS_IP"
        [[ -n "$TS_DNS" ]] && info "Magic DNS:     $TS_DNS"
    fi
); then
    mark_ok "TAILSCALE" "${TS_IP:-not authenticated yet}"
else
    mark_fail "TAILSCALE" "setup failed"
fi
