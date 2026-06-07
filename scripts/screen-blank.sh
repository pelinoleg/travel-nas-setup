#!/bin/bash
# screen-blank.sh — полное гашение экрана.
# На Waveshare 4.3" DSI brightness=0 / bl_power=4 НЕ глушат подсветку до конца —
# гасим сам вывод компоновщика (DPMS) через wlopm, плюс на всякий случай brightness=0.
#   screen-blank.sh off | on
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
sock="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)"
[[ -n "$sock" ]] && export WAYLAND_DISPLAY="$(basename "$sock")"
OUT="$(wlr-randr 2>/dev/null | awk 'NR==1{print $1}')"; [[ -z "$OUT" ]] && OUT=DSI-1

case "${1:-}" in
  off) wlopm --off "$OUT" 2>/dev/null; /usr/local/bin/dsi-backlight.sh off >/dev/null 2>&1 ;;
  on)  wlopm --on "$OUT" 2>/dev/null; /usr/local/bin/dsi-backlight.sh on  >/dev/null 2>&1 ;;
  *)   echo "usage: $0 on|off" >&2; exit 1 ;;
esac
echo "screen $1 ($OUT)"
