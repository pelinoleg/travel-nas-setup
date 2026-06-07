#!/bin/bash
# screen-blank.sh — полное гашение/включение DSI-экрана.
# brightness=0/bl_power на Waveshare 4.3" DSI НЕ гасят подсветку (заводской минимум
# видим — по их вики нужен хардварный мод резистора). Единственный софт-способ —
# отключить вывод компоновщика: официальный метод Waveshare = wlr-randr --off/--on.
#   screen-blank.sh off | on
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
sock="$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v lock | head -1)"
[[ -n "$sock" ]] && export WAYLAND_DISPLAY="$(basename "$sock")"
OUT="$(wlopm 2>/dev/null | awk 'NR==1{print $1}')"; [[ -z "$OUT" ]] && OUT=DSI-1

case "${1:-}" in
  off) wlr-randr --output "$OUT" --off 2>/dev/null ;;
  on)  wlr-randr --output "$OUT" --on  2>/dev/null ;;
  *)   echo "usage: $0 on|off" >&2; exit 1 ;;
esac
echo "screen $1 ($OUT)"
