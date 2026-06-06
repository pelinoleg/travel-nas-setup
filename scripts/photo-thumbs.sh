#!/bin/bash
# photo-thumbs.sh — прогрев кэша тумбнейлов для сессии через дашборд (DRY: один путь
# генерации). Вызывается после импорта (photo-backup.sh) или вручную.
#   photo-thumbs.sh <session-relpath|abs-dir>
PORT="${WEBDASH_PORT:-8090}"
ROOT="/mnt/storage/usb-imports"
sess="${1:-}"
[[ -d "$sess" ]] || sess="$ROOT/$sess"
[[ -d "$sess" ]] || { echo "no session: $1" >&2; exit 0; }

n=0
while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  curl -s -m 30 -G --data-urlencode "f=$rel" "http://localhost:$PORT/api/photos/img?s=400" -o /dev/null || true
  n=$((n + 1))
done < <(find "$sess" -type f \( -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null)
echo "warmed $n thumbnails for $(basename "$sess")"
