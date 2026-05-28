[[ -n "${DO_DESKTOP:-}" ]] || return 0

info "=== Desktop shortcuts ==="
# На MHS35 320×480 пиктограммы LXDE дефолтного размера почти не помещаются
# в один экран. Кладём только две самых нужных:
#  - Travel-NAS Dashboard — вернуться в kiosk после Exit to desktop
#  - Travel-NAS Update    — pull свежих скриптов из GitHub
# Остальное (NAS backup, logs, files, edit services) доступно через
# Menu внутри dashboard.
if (
    set -e
    USER_HOME="/home/$(whoami)"
    # На свежей системе ~/Desktop может не существовать (xdg-user-dirs-update
    # ещё не сработал — он триггерится на первом GUI-логине). Раньше модуль
    # выкидывал ошибку и не создавал ярлыки → пользователь после reinstall'а
    # не получал кнопок. Создаём папку сами и идём дальше.
    DESKTOP_DIR="$USER_HOME/Desktop"
    if [[ ! -d "$DESKTOP_DIR" ]]; then
        mkdir -p "$DESKTOP_DIR"
        # На случай если xdg user-dirs выключен — пишем явно
        if command -v xdg-user-dirs-update &>/dev/null; then
            xdg-user-dirs-update --set DESKTOP "$DESKTOP_DIR" 2>/dev/null || true
        fi
    fi

    cat > "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Dashboard
Comment=Re-open the kiosk dashboard
Exec=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
Icon=display
Terminal=false
Categories=System;
EOF

    cat > "$DESKTOP_DIR/Travel-NAS-Update.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Update
Comment=Pull latest scripts from GitHub
Exec=lxterminal --geometry=100x30 -e bash -c "travel-nas-update; echo; echo 'Готово. Нажми Enter чтобы закрыть.'; read"
Icon=system-software-update
Terminal=false
Categories=System;
EOF

    cat > "$DESKTOP_DIR/Travel-NAS-Calibrate.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Calibrate Touch
Comment=Resistive touchscreen calibration (tap 4 corners)
Exec=lxterminal --geometry=80x20 -e bash -c "sudo /usr/local/bin/touch-calibrate.sh; echo; echo 'Нажми Enter'; read"
Icon=preferences-desktop-display
Terminal=false
Categories=System;
EOF

    chmod +x "$DESKTOP_DIR"/*.desktop
    # Удаляем устаревшие ярлыки (если остались с прошлых установок)
    rm -f "$DESKTOP_DIR/NAS-Backup.desktop" \
          "$DESKTOP_DIR/View-Logs.desktop" \
          "$DESKTOP_DIR/Travel-NAS-Logs.desktop" \
          "$DESKTOP_DIR/Travel-NAS-Setup.desktop" \
          "$DESKTOP_DIR/T7-Files.desktop" \
          "$DESKTOP_DIR/Edit-Services.desktop" 2>/dev/null

    # Уменьшаем размер иконок в pcmanfm-desktop (320×480 → дефолтные ~80px не лезут)
    DCFG="$USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf"
    mkdir -p "$(dirname "$DCFG")"
    if [[ ! -f "$DCFG" ]]; then
        cat > "$DCFG" << 'EOF'
[*]
wallpaper_mode=color
desktop_bg=#000000
desktop_fg=#ffffff
desktop_font=Sans 8
show_wm_menu=0
show_documents=0
show_trash=0
show_mounts=0
desktop_icon_size=36
EOF
    elif grep -q '^desktop_icon_size=' "$DCFG"; then
        sed -i 's/^desktop_icon_size=.*/desktop_icon_size=36/' "$DCFG"
    else
        echo "desktop_icon_size=36" >> "$DCFG"
    fi

    # Пинаем pcmanfm-desktop чтобы подхватил новые .desktop без релогина.
    # Без этого ярлыки появятся только после следующего входа в LXDE.
    if pgrep -x pcmanfm >/dev/null 2>&1; then
        pcmanfm --reconfigure 2>/dev/null || true
    fi
); then
    mark_ok "DESKTOP" "2 ярлыка, icon size 36"
else
    mark_fail "DESKTOP" "Desktop folder не найден (не Desktop PiOS?)"
fi
