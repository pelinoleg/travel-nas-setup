#!/usr/bin/env python3
# =============================================================================
# backup-progress-writer.py
# =============================================================================
# Парсит вывод `rsync --info=progress2 --no-inc-recursive` со stdin,
# пишет JSON в /var/run/travel-nas/backup-progress.json — dashboard читает.
# Stdin → stdout проходит без изменений (можно ставить в любую pipe).
#
# Использование (внутри backup-скриптов):
#   rsync --info=progress2 --no-inc-recursive ... 2>&1 \
#     | backup-progress-writer.py \
#         --source photo \
#         --device "$DEVICE" \
#         --label "$LABEL" \
#         --target "$TARGET" \
#         --files-total "$N" \
#         --size-total "$SIZE_HUMAN" \
#     | tee "$log_file"
# =============================================================================

import os
import sys
import re
import json
import time
import argparse
from pathlib import Path

STATE_DIR = Path("/var/run/travel-nas")
PROGRESS_FILE = STATE_DIR / "backup-progress.json"
TMP_FILE = STATE_DIR / "backup-progress.json.tmp"

# rsync --info=progress2 output example:
#      234,567,890   34%   12.34MB/s    0:01:23 (xfr#42, to-chk=10/100)
PROGRESS_RE = re.compile(
    r"(?P<bytes>[\d,]+)\s+(?P<pct>\d+)%\s+(?P<speed>\S+)\s+(?P<eta>\d+:\d+:\d+)"
    r"(?:.*?xfr#(?P<xfr>\d+))?"
)

WRITE_INTERVAL = 1.0  # секунд между записями JSON


def human_bytes(n):
    n = float(n)
    for u in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return f"{int(n)}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"


def atomic_write(data):
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(TMP_FILE, "w") as f:
            json.dump(data, f)
        os.replace(TMP_FILE, PROGRESS_FILE)
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source",      default="backup")  # photo | nas
    ap.add_argument("--device",      default="")
    ap.add_argument("--label",       default="")
    ap.add_argument("--target",      default="")
    ap.add_argument("--files-total", type=int, default=0)
    ap.add_argument("--size-total",  default="")
    args = ap.parse_args()

    base = {
        "source":      args.source,
        "device":      args.device,
        "label":       args.label,
        "target":      args.target,
        "files_total": args.files_total,
        "size_total":  args.size_total,
    }

    last_write = 0.0
    last_data = None

    # Сразу пишем "0%" чтобы dashboard переключился на progress-страницу
    atomic_write({**base, "percent": 0, "files_done": 0,
                  "size_done": "0B", "speed": "?", "eta": "?",
                  "updated": int(time.time())})

    try:
        for raw in sys.stdin:
            sys.stdout.write(raw)
            sys.stdout.flush()
            line = raw.rstrip("\r\n")
            m = PROGRESS_RE.search(line)
            if not m:
                continue
            now = time.time()
            if now - last_write < WRITE_INTERVAL:
                continue
            last_write = now

            try:
                bd = int(m.group("bytes").replace(",", ""))
                size_done = human_bytes(bd)
            except ValueError:
                size_done = "?"
            last_data = {
                **base,
                "percent":    int(m.group("pct")),
                "files_done": int(m.group("xfr") or 0),
                "size_done":  size_done,
                "speed":      m.group("speed"),
                "eta":        m.group("eta"),
                "updated":    int(now),
            }
            atomic_write(last_data)
    finally:
        # Финальный кадр: 100% done — dashboard покажет ~8 секунд и спрячет
        final = dict(last_data) if last_data else dict(base)
        final["percent"] = 100
        final["done"] = True
        final["updated"] = int(time.time())
        atomic_write(final)


if __name__ == "__main__":
    main()
