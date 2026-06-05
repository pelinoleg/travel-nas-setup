[[ -n "${DO_DESKTOP:-}" ]] || return 0

info "=== Desktop shortcuts ==="

# Набор ярлыков зависит от экрана:
#  MHS35 — Dashboard + Calibrate Touch (+ Update), мелкие иконки под 320×480.
#  DSI43 — дашборда и калибровки НЕТ (на DSI они не ставятся: экран другой,
#          тач ёмкостный driver-free). Вместо них — ярлыки на наши docker-сервисы:
#          на 800×480 удобно открыть веб-UI прямо в браузере. (+ Update).
BOOT_CFG=/boot/firmware/config.txt
[[ -f "$BOOT_CFG" ]] || BOOT_CFG=/boot/config.txt
SCREEN_TYPE=""
if grep -qE '^[[:space:]]*dtoverlay=vc4-kms-dsi(-7inch|-waveshare-800x480)' "$BOOT_CFG" 2>/dev/null; then
    SCREEN_TYPE=dsi43
elif grep -qE '^[[:space:]]*dtoverlay=mhs35' "$BOOT_CFG" 2>/dev/null; then
    SCREEN_TYPE=mhs35
elif [[ -f "$CONFIG_DIR/display.conf" ]]; then
    source "$CONFIG_DIR/display.conf" 2>/dev/null || true
fi
[[ -n "${SCREEN_TYPE:-}" ]] || SCREEN_TYPE=mhs35   # legacy default

if (
    set -e
    USER_HOME="/home/$(whoami)"
    # На свежей системе ~/Desktop может не существовать (xdg-user-dirs-update
    # ещё не сработал — он триггерится на первом GUI-логине). Создаём сами.
    DESKTOP_DIR="$USER_HOME/Desktop"
    if [[ ! -d "$DESKTOP_DIR" ]]; then
        mkdir -p "$DESKTOP_DIR"
        if command -v xdg-user-dirs-update &>/dev/null; then
            xdg-user-dirs-update --set DESKTOP "$DESKTOP_DIR" 2>/dev/null || true
        fi
    fi

    # Update — нужен на любом экране.
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

    if [[ "$SCREEN_TYPE" == "dsi43" ]]; then
        # На DSI дашборда/калибровки нет — чистим их ярлыки (если остались).
        rm -f "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop" \
              "$DESKTOP_DIR/Travel-NAS-Calibrate.desktop" \
              "$DESKTOP_DIR"/Service-*.desktop 2>/dev/null

        # Ярлыки на установленные docker-сервисы. «Установлен» = выбран сейчас
        # (DO_STACK_<NAME>) ИЛИ есть /opt/stacks/<name> (стоит с прошлого раза).
        # LABEL/PORT — из meta.conf в репо. Открываем localhost:PORT в браузере.
        STACKS_SRC="${SETUP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/stacks"
        if [[ -f "$STACKS_SRC/index.txt" ]]; then
            while read -r sname; do
                sname="${sname%%#*}"; sname="$(echo "$sname" | xargs)"
                [[ -n "$sname" ]] || continue
                flag="DO_STACK_$(echo "$sname" | tr '[:lower:]-' '[:upper:]_')"
                [[ -n "${!flag:-}" || -d "/opt/stacks/$sname" ]] || continue
                LABEL="$sname"; PORT=""
                # shellcheck source=/dev/null
                source "$STACKS_SRC/$sname/meta.conf" 2>/dev/null || true
                [[ -n "$PORT" ]] || continue
                disp="${LABEL%% —*}"   # короткое имя до « —»
                cat > "$DESKTOP_DIR/Service-$sname.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$disp
Comment=$LABEL
Exec=xdg-open http://localhost:$PORT
Icon=web-browser
Terminal=false
Categories=Network;
EOF
            done < "$STACKS_SRC/index.txt"
        fi
        # Dockge — менеджер стеков (если установлен).
        if [[ -d /opt/dockge ]]; then
            cat > "$DESKTOP_DIR/Service-dockge.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Dockge
Comment=Docker stacks manager
Exec=xdg-open http://localhost:5001
Icon=web-browser
Terminal=false
Categories=Network;
EOF
        fi
    else
        # MHS35: дашборд + калибровка (как было). Сервис-ярлыки убираем.
        rm -f "$DESKTOP_DIR"/Service-*.desktop 2>/dev/null

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

        cat > "$DESKTOP_DIR/Travel-NAS-Calibrate.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Calibrate Touch
Comment=Resistive touchscreen calibration (tap 4 corners, auto-reboot)
Exec=sudo -n /usr/local/bin/touch-calibrate.sh
Icon=preferences-desktop-display
Terminal=false
Categories=System;
EOF

        # Уменьшаем иконки в pcmanfm-desktop (320×480 → дефолтные ~80px не лезут).
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
    fi

    chmod +x "$DESKTOP_DIR"/*.desktop 2>/dev/null || true
    # Удаляем устаревшие ярлыки (с прошлых установок).
    rm -f "$DESKTOP_DIR/NAS-Backup.desktop" \
          "$DESKTOP_DIR/View-Logs.desktop" \
          "$DESKTOP_DIR/Travel-NAS-Logs.desktop" \
          "$DESKTOP_DIR/Travel-NAS-Setup.desktop" \
          "$DESKTOP_DIR/T7-Files.desktop" \
          "$DESKTOP_DIR/Edit-Services.desktop" 2>/dev/null

    # Пинаем pcmanfm-desktop чтобы подхватил новые .desktop без релогина.
    if pgrep -x pcmanfm >/dev/null 2>&1; then
        pcmanfm --reconfigure 2>/dev/null || true
    fi
); then
    if [[ "$SCREEN_TYPE" == "dsi43" ]]; then
        mark_ok "DESKTOP" "DSI: ярлыки на docker-сервисы + Update (без дашборда/калибровки)"
    else
        mark_ok "DESKTOP" "MHS35: dashboard + calibrate + update, icon size 36"
    fi
else
    mark_fail "DESKTOP" "Desktop folder не найден (не Desktop PiOS?)"
fi
