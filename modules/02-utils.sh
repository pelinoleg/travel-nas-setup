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
        avahi-daemon
); then
    # `travel-nas-setup` — перезапуск wizard'а без curl-paste
    fetch_script "travel-nas-setup.sh"  "$SCRIPT_DIR/travel-nas-setup"
    # `travel-nas-update` — быстро обновить только скрипты в /usr/local/bin
    # без переустановки сервисов (для повседневного итерирования)
    fetch_script "travel-nas-update.sh" "$SCRIPT_DIR/travel-nas-update"
    # set-led — управление встроенным power-LED Pi из других скриптов
    fetch_script "set-led.sh"           "$SCRIPT_DIR/set-led.sh"

    # /etc/motd — что увидит юзер при ssh-логине
    sudo tee /etc/motd >/dev/null << 'EOF'

  ╔══════════════════════════════════════════════════════════╗
  ║                      Travel-NAS                          ║
  ║                                                          ║
  ║   Dashboard:  http://travel-nas.local                    ║
  ║   Re-config:  travel-nas-setup                           ║
  ║   Logs:       tail -F /mnt/t7/_logs/*.log                ║
  ║   Backups:    /mnt/t7/{usb-imports,nas-backup}           ║
  ╚══════════════════════════════════════════════════════════╝

EOF
    mark_ok "UTILS"
else
    mark_fail "UTILS" "apt install failed"
fi
