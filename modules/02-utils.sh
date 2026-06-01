[[ -n "${DO_UTILS:-}" ]] || return 0

info "=== Utilities ==="
if (
    set -e
    apt_install \
        htop ncdu tmux git tree jq curl wget \
        smartmontools nvme-cli rsync sshpass \
        libimage-exiftool-perl \
        whiptail dialog \
        ifupdown net-tools wireless-tools \
        python3-pip python3-pygame python3-evdev \
        wmctrl \
        chrony \
        avahi-daemon
); then
    # `travel-nas-setup` — перезапуск wizard'а без curl-paste
    fetch_script "travel-nas-setup.sh"  "$SCRIPT_DIR/travel-nas-setup"
    # `travel-nas-update` — быстро обновить только скрипты в /usr/local/bin
    # без переустановки сервисов (для повседневного итерирования)
    fetch_script "travel-nas-update.sh" "$SCRIPT_DIR/travel-nas-update"
    # set-led — управление встроенным power-LED Pi из других скриптов
    fetch_script "set-led.sh"           "$SCRIPT_DIR/set-led.sh"

    # chrony — единственный NTP-демон. Дефолтный конфиг уже рабочий (NTP-пул +
    # makestep на старте + rtcsync). Явно гасим systemd-timesyncd чтобы два
    # клиента времени не дрались. Настройка не нужна — синхронит при наличии сети.
    sudo systemctl disable --now systemd-timesyncd 2>/dev/null || true
    sudo systemctl enable --now chrony 2>/dev/null || sudo systemctl enable --now chronyd 2>/dev/null || true

    # /etc/motd — что увидит юзер при логине. Hostname берётся живой (перепрошивка
    # с новым именем не отстаёт). Узкий, без рамки — влезает на вертикальный
    # MHS35-консоль (320px ≈ 40 колонок); рамка-бокс ломалась по горизонтали.
    HOST_LOCAL="$(hostname).local"
    sudo tee /etc/motd >/dev/null << EOF

 Travel-NAS · ${HOST_LOCAL}
 ─────────────────────────
 Dashboard  http://${HOST_LOCAL}
 Re-config  travel-nas-setup
 Update     travel-nas-update
 Logs       /mnt/storage/_logs/
 Backups    /mnt/storage/

EOF
    mark_ok "UTILS"
else
    mark_fail "UTILS" "apt install failed"
fi
