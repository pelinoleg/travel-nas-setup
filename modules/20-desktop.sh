[[ -n "${DO_DESKTOP:-}" ]] || return 0

info "=== Desktop shortcuts ==="
if (
    set -e
    USER_HOME="/home/$(whoami)"
    DESKTOP_DIR="$USER_HOME/Desktop"
    if [[ ! -d "$DESKTOP_DIR" ]]; then
        echo "Desktop folder not found"
        exit 1
    fi
    cat > "$DESKTOP_DIR/NAS-Backup.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=NAS Backup
Comment=Backup files from home UGREEN NAS to T7
Exec=lxterminal -e "sudo /usr/local/bin/nas-backup.sh"
Icon=drive-harddisk
Terminal=false
Categories=System;
EOF
    cat > "$DESKTOP_DIR/View-Logs.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Travel-NAS Logs
Comment=View all logs
Exec=lxterminal -e "tail -F /mnt/t7/_logs/*.log"
Icon=utilities-log-viewer
Terminal=false
Categories=System;
EOF
    # Запуск/возврат dashboard'а после "Exit to desktop"
    cat > "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Travel-NAS Dashboard
Comment=Re-open the kiosk dashboard
Exec=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
Icon=display
Terminal=false
Categories=System;
EOF
    # Setup wizard — re-fetch и launch
    cat > "$DESKTOP_DIR/Travel-NAS-Setup.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Travel-NAS Setup
Comment=Re-run install wizard (fetches latest from GitHub)
Exec=lxterminal --geometry=100x30 -e bash -c "cd ~ && travel-nas-setup; echo; echo 'Готово. Нажми Enter чтобы закрыть.'; read"
Icon=system-software-install
Terminal=false
Categories=System;
EOF
    # File manager на T7
    cat > "$DESKTOP_DIR/T7-Files.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=T7 Files
Comment=Open /mnt/t7 in file manager
Exec=pcmanfm /mnt/t7
Icon=folder
Terminal=false
Categories=System;
EOF
    # Редактирование services.conf (oleg-owned, sudo не нужен)
    cat > "$DESKTOP_DIR/Edit-Services.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Edit Services
Comment=Edit dashboard services list (/etc/travel-nas/services.conf)
Exec=lxterminal -e nano /etc/travel-nas/services.conf
Icon=text-editor
Terminal=false
Categories=System;
EOF
    chmod +x "$DESKTOP_DIR"/*.desktop
); then
    mark_ok "DESKTOP" "ярлыки на десктопе"
else
    mark_fail "DESKTOP" "Desktop folder не найден (не Desktop PiOS?)"
fi
