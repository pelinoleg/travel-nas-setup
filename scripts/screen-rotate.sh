#!/bin/bash
# =============================================================================
# screen-rotate.sh — переключает MHS35 (ili9486 SPI) rotation с правильной
# калибровкой touch'а под него. Без этого touch перестаёт совпадать с
# изображением (классический баг с goodtft/MHS35-show где скрипт жёстко
# захардкожен под 90°).
#
# Использование:
#   sudo screen-rotate.sh 0     # USB-разъёмы сверху, портрет
#   sudo screen-rotate.sh 90    # USB справа, ландшафт
#   sudo screen-rotate.sh 180   # USB снизу, портрет вверх ногами
#   sudo screen-rotate.sh 270   # USB слева, ландшафт зеркальный
#
# Требует reboot — kernel dtoverlay подхватывается только при загрузке.
# =============================================================================

set -e

ROTATION="${1:-}"
case "$ROTATION" in
    0|90|180|270) ;;
    *)
        echo "Usage: $0 {0|90|180|270}" >&2
        exit 2
        ;;
esac

if [[ "$EUID" -ne 0 ]]; then
    exec sudo -- "$0" "$@"
fi

BOOT_CFG="/boot/firmware/config.txt"
CAL_FILE="/etc/X11/xorg.conf.d/99-calibration.conf"

# ── 1) /boot/firmware/config.txt: dtoverlay=mhs35:rotate=N ─────────────────
if grep -q "^dtoverlay=mhs35" "$BOOT_CFG"; then
    sed -i "s/^dtoverlay=mhs35.*/dtoverlay=mhs35:rotate=$ROTATION/" "$BOOT_CFG"
    echo "✓ $BOOT_CFG: dtoverlay=mhs35:rotate=$ROTATION"
else
    echo "dtoverlay=mhs35:rotate=$ROTATION" >> "$BOOT_CFG"
    echo "✓ $BOOT_CFG: добавил dtoverlay=mhs35:rotate=$ROTATION"
fi

# ── 2) /etc/X11/xorg.conf.d/99-calibration.conf ─────────────────────────────
# Бэкап старой калибровки на случай если она была откалибрована xinput'ом.
if [[ -f "$CAL_FILE" ]]; then
    cp "$CAL_FILE" "${CAL_FILE}.bak.$(date +%s)"
fi

# Каноничные значения из goodtft/LCD-show под каждый rotation. Это «грубая»
# калибровка — попадает в кнопку, но возможна точечная погрешность 3-5px на
# углах. Тонкая подстройка: после reboot запустить sudo touch-calibrate.sh.
case "$ROTATION" in
    0)
        CAL='268 3880 227 3936';  SWAP=0 ;;
    90)
        CAL='3936 227 268 3880';  SWAP=1 ;;
    180)
        CAL='3880 268 3936 227';  SWAP=0 ;;
    270)
        CAL='227 3936 3880 268';  SWAP=1 ;;
esac

cat > "$CAL_FILE" << EOF
Section "InputClass"
    Identifier   "calibration"
    MatchProduct "ADS7846 Touchscreen"
    Option       "Calibration"   "$CAL"
    Option       "SwapAxes"      "$SWAP"
EndSection
EOF
echo "✓ $CAL_FILE: Calibration=\"$CAL\" SwapAxes=$SWAP"

# ── 3) Удаляем legacy конфликты ─────────────────────────────────────────────
# goodtft иногда оставляет 99-fbturbo.conf и 99-fbcp-mhs35.conf — на Trixie
# с KMS/vc4-kms-v3d они вызывают X-краш. Если они есть и под нашим
# контролем — НЕ трогаем; user может ставить руками. Но логируем для info.
for f in /etc/X11/xorg.conf.d/99-fbturbo.conf /etc/X11/xorg.conf.d/99-fbcp-mhs35.conf; do
    if [[ -f "$f" ]]; then
        echo "  ⚠ присутствует $f (legacy goodtft — если будут проблемы с X, удали)"
    fi
done

echo
echo "Готово. Для применения нужно ребутнуть Pi:"
echo "    sudo reboot"
echo
echo "После reboot тест touch'a:"
echo "    1. Тапни четыре угла экрана — попадание должно совпадать."
echo "    2. Если кривовато — sudo touch-calibrate.sh (запустит xinput_calibrator,"
echo "       результат запишет в $CAL_FILE и попросит снова reboot)."
