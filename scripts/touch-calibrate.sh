#!/bin/bash
# =============================================================================
# touch-calibrate.sh — интерактивная калибровка резистивного touch'а MHS35
# =============================================================================
# Что делает:
#  1. Останавливает dashboard (он fullscreen — мешает калибратору)
#  2. Запускает xinput_calibrator от oleg в его X-сессии
#  3. Юзер тапает 4 креста по углам
#  4. Output (xorg.conf.d snippet) сохраняем в /etc/X11/xorg.conf.d/99-calibration.conf
#  5. Поднимаем dashboard обратно
#  6. (Опционально) reboot чтоб X точно перечитал config
#
# Запуск (с tty/Terminal — нужен DISPLAY:0):
#   sudo /usr/local/bin/touch-calibrate.sh
# Через десктоп-ярлык — Travel-NAS-Calibrate.desktop.
# =============================================================================

set -u

CALIB_FILE="/etc/X11/xorg.conf.d/99-calibration.conf"
USER_LOGIN="${SUDO_USER:-$(logname 2>/dev/null || echo oleg)}"
USER_HOME="/home/$USER_LOGIN"

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

if ! command -v xinput_calibrator >/dev/null 2>&1; then
    echo "[ERR] xinput-calibrator не установлен. Установка:"
    echo "      sudo apt install -y xinput-calibrator"
    exit 1
fi

echo "[INFO] Останавливаю dashboard…"
systemctl stop travel-nas-display-runtime 2>/dev/null || true
pkill -9 -f /usr/local/bin/travel-nas-display.py 2>/dev/null || true
sleep 1

echo "[INFO] Запускаю калибратор. ТАПНИ КАЖДЫЙ ИЗ 4 КРЕСТОВ ПО УГЛАМ ЭКРАНА."
echo "[INFO] (если ничего не происходит — проверь что курсор отображается)"
echo

TMP_OUT=$(mktemp)
sudo -u "$USER_LOGIN" -H \
    env DISPLAY=:0 XAUTHORITY="$USER_HOME/.Xauthority" \
    xinput_calibrator --output-type xorg.conf.d 2>&1 | tee "$TMP_OUT"

if ! grep -q "Section.*InputClass" "$TMP_OUT"; then
    echo
    echo "[ERR] Калибратор не сгенерил xorg snippet. Не сохраняю — старая калибровка остаётся."
    rm -f "$TMP_OUT"
    # Поднять dashboard обратно
    systemctl reset-failed travel-nas-display-runtime 2>/dev/null || true
    systemd-run --unit=travel-nas-display-runtime --uid="$USER_LOGIN" \
        --setenv=DISPLAY=:0 --setenv=XAUTHORITY="$USER_HOME/.Xauthority" \
        --setenv=HOME="$USER_HOME" \
        /usr/bin/python3 /usr/local/bin/travel-nas-display.py
    exit 1
fi

echo
echo "[INFO] Сохраняю новую калибровку в $CALIB_FILE…"
# Backup старой на случай если новая хуже
[[ -f "$CALIB_FILE" ]] && cp "$CALIB_FILE" "${CALIB_FILE}.bak.$(date +%s)"

# Извлекаем только Section "InputClass" блок (xinput_calibrator печатает
# ещё инструкции в конце). awk забирает с "Section" до "EndSection".
awk '/^Section "InputClass"/,/^EndSection/' "$TMP_OUT" > "$CALIB_FILE"
chmod 0644 "$CALIB_FILE"
rm -f "$TMP_OUT"

echo "[OK] Готово. Перезагружаюсь через 5 сек чтобы применить (X должен"
echo "     перечитать xorg.conf.d). Никаких клавиш — touch-only OK."
sleep 5
reboot
