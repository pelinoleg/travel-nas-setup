#!/bin/bash
# =============================================================================
# travel-nas-setup — single-command launcher for the installer
# =============================================================================
# Скачивает последнюю версию setup.sh из репо и запускает.
# Лежит в /usr/local/bin/travel-nas-setup чтобы можно было набрать просто
# `travel-nas-setup` где угодно (включая первый SSH в свежеустановленную Pi
# после bootstrap'а).
# =============================================================================

set -eu

REPO_RAW="https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main"
TMP="/tmp/setup.sh.$$"

# Cache buster чтобы CDN не отдавал стейл версию
URL="$REPO_RAW/setup.sh?$(date +%s)"

echo "Fetching latest setup.sh..."
curl -fsSL "$URL" -o "$TMP"
chmod +x "$TMP"

# Передаём все аргументы (например --help, --all)
bash "$TMP" "$@"
rc=$?

rm -f "$TMP"
exit "$rc"
