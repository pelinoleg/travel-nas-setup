#!/bin/bash
# photo-cull.sh — отбор фото из дашборда (запускается root через sudo).
#   delete <file>      → переместить в usb-imports/_rejected/ (обратимо)
#   save   <file> [tg] → копия в usb-imports/_selects/ (+ опц. отправить в Telegram)
# Путь обязан быть внутри usb-imports (защита от traversal).
set -euo pipefail

ROOT="/mnt/storage/usb-imports"
act="${1:-}"; src="${2:-}"; tg="${3:-}"

case "$src" in "$ROOT"/*) ;; *) echo "bad path" >&2; exit 1 ;; esac
[[ -f "$src" ]] || { echo "no file" >&2; exit 1; }
base="$(basename "$src")"

case "$act" in
  delete)
    dst="$ROOT/_rejected"; mkdir -p "$dst"
    mv -f "$src" "$dst/$base"; echo "rejected $base" ;;
  save)
    dst="$ROOT/_selects"; mkdir -p "$dst"
    cp -f "$src" "$dst/$base"; echo "saved $base"
    if [[ "$tg" == "tg" ]]; then
      cf=/etc/travel-nas/tg-notify.conf
      tok=$(grep -m1 '^TG_BOT_TOKEN=' "$cf" 2>/dev/null | cut -d= -f2- | tr -d '"' | xargs || true)
      chat=$(grep -m1 '^TG_CHAT_ID=' "$cf" 2>/dev/null | cut -d= -f2- | tr -d '"' | xargs || true)
      if [[ -n "$tok" && -n "$chat" ]]; then
        curl -s -F chat_id="$chat" -F photo=@"$src" \
          "https://api.telegram.org/bot$tok/sendPhoto" >/dev/null && echo "+telegram" || true
      fi
    fi ;;
  *) echo "bad action" >&2; exit 1 ;;
esac
