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

# rsync --info=progress2 output форматы (зависит от -h/--human-readable):
#   без -h: "      234,567,890   34%   12.34MB/s    0:01:23 (xfr#42, to-chk=10/100)"
#   с  -h:  "        603.60M    8%   54.03MB/s    0:00:08 (xfr#30, to-chk=395/425)"
# Поэтому байты — это либо [0-9,]+ либо [0-9.]+ с опциональным KMGT суффиксом.
PROGRESS_RE = re.compile(
    r"(?P<bytes>[\d.,]+[KMGT]?)\s+(?P<pct>\d+)%\s+(?P<speed>\S+)\s+(?P<eta>\d+:\d+:\d+)"
    r"(?:.*?xfr#(?P<xfr>\d+))?"
)

WRITE_INTERVAL = 1.0  # секунд между записями JSON

# rsync ETA скачет: 20 мин → 16 ч → 8 мин, потому что:
#  - --no-inc-recursive сканирует список параллельно (total bytes растёт)
#  - speed зависит от типа файлов (мелкие = много syscall'ов = медленнее)
# Сглаживаем median'ом по последним SMOOTH_WINDOW значениям.
SMOOTH_WINDOW = 15


def _parse_eta(s):
    """rsync ETA вид '0:01:23' или '16:33:37' → секунды. None если не парсится."""
    if not s: return None
    parts = s.split(":")
    if len(parts) != 3: return None
    try:
        h, m, sec = (int(p) for p in parts)
        return h * 3600 + m * 60 + sec
    except ValueError:
        return None


def _format_eta(seconds):
    """Секунды → 'Xh Ym' или 'Xm Ys' для компактного отображения."""
    if seconds is None or seconds < 0:
        return "?"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    h = seconds // 3600
    m = (seconds % 3600) // 60
    return f"{h}h {m}m"


def _parse_speed(s):
    """'12.34MB/s' → bytes/sec. None если не парсится."""
    if not s: return None
    m = re.match(r"([\d.]+)\s*([KMGT]?)B?/s", s, re.I)
    if not m: return None
    units = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
    try:
        return float(m.group(1)) * units.get(m.group(2).upper(), 1)
    except (ValueError, KeyError):
        return None


def _format_speed(bytes_per_sec):
    if bytes_per_sec is None or bytes_per_sec < 0:
        return "?"
    for u in ("B", "K", "M", "G"):
        if bytes_per_sec < 1024:
            return f"{bytes_per_sec:.1f}{u}/s" if u != "B" else f"{int(bytes_per_sec)}B/s"
        bytes_per_sec /= 1024
    return f"{bytes_per_sec:.1f}T/s"

# Debug log — позволяет понять что приходит от rsync и почему JSON не движется.
# Если установлена env BACKUP_WRITER_DEBUG=1 — пишем каждую распарсенную строку.
DEBUG_LOG = Path("/tmp/backup-progress-writer.debug.log")
DEBUG = bool(os.environ.get("BACKUP_WRITER_DEBUG"))


def debug(msg):
    if not DEBUG:
        return
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


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
    # Rolling buffers — median сглаживает jitter от rsync (см. SMOOTH_WINDOW)
    eta_buf   = []
    speed_buf = []

    # Сразу пишем "0%" чтобы dashboard переключился на progress-страницу
    atomic_write({**base, "percent": 0, "files_done": 0,
                  "size_done": "0B", "speed": "?", "eta": "?",
                  "updated": int(time.time())})

    def process_line(line):
        nonlocal last_write, last_data
        m = PROGRESS_RE.search(line)
        if not m:
            debug(f"NO_MATCH: {line!r}")
            return
        now = time.time()
        if now - last_write < WRITE_INTERVAL:
            debug(f"THROTTLE: {line.strip()}")
            return
        last_write = now
        raw_bytes = m.group("bytes")
        if raw_bytes and raw_bytes[-1] in "KMGT":
            size_done = raw_bytes
        else:
            try:
                bd = int(raw_bytes.replace(",", "").rstrip("."))
                size_done = human_bytes(bd)
            except ValueError:
                size_done = raw_bytes

        # === Smoothing: median последних SMOOTH_WINDOW значений ===
        raw_eta_s = _parse_eta(m.group("eta"))
        if raw_eta_s is not None:
            eta_buf.append(raw_eta_s)
            if len(eta_buf) > SMOOTH_WINDOW: eta_buf.pop(0)
        raw_spd = _parse_speed(m.group("speed"))
        if raw_spd is not None:
            speed_buf.append(raw_spd)
            if len(speed_buf) > SMOOTH_WINDOW: speed_buf.pop(0)

        # Median — устойчивее к выбросам чем mean. "calculating…" пока буфер
        # маленький (< 3 — слишком мало данных чтобы доверять).
        if len(eta_buf) >= 3:
            sorted_eta = sorted(eta_buf)
            eta_str = _format_eta(sorted_eta[len(sorted_eta) // 2])
        else:
            eta_str = "calculating…"
        if len(speed_buf) >= 3:
            sorted_spd = sorted(speed_buf)
            speed_str = _format_speed(sorted_spd[len(sorted_spd) // 2])
        else:
            speed_str = m.group("speed")  # сырое значение пока не накопили

        last_data = {
            **base,
            "percent":    int(m.group("pct")),
            "files_done": int(m.group("xfr") or 0),
            "size_done":  size_done,
            "speed":      speed_str,
            "eta":        eta_str,
            "updated":    int(now),
        }
        atomic_write(last_data)
        debug(f"WROTE: pct={last_data['percent']} eta={eta_str} (raw {m.group('eta')}, buf {len(eta_buf)})")

    # rsync --info=progress2 обновляет процент через \r (без \n) —
    # text-mode `for line in sys.stdin` буферится и отдаёт только финальную
    # строку. Читаем сырые байты и сами режем по \r или \n.
    stdin_fd  = sys.stdin.buffer
    stdout_fd = sys.stdout.buffer
    buf = bytearray()
    bytes_seen = 0
    last_heartbeat = time.time()
    debug(f"writer started: source={args.source} device={args.device}")
    try:
        while True:
            chunk = stdin_fd.read(1)
            if not chunk:
                break
            stdout_fd.write(chunk)
            bytes_seen += 1
            if chunk in (b"\r", b"\n"):
                stdout_fd.flush()
                if buf:
                    try:
                        process_line(bytes(buf).decode("utf-8", errors="replace"))
                    except Exception as e:
                        debug(f"EXC: {e}")
                    buf.clear()
            else:
                buf += chunk
            # Heartbeat в debug каждые 3 сек — показать что writer жив и сколько байт прочитано
            now = time.time()
            if now - last_heartbeat > 3:
                debug(f"alive: bytes_seen={bytes_seen} buf_len={len(buf)} last_pct={(last_data or {}).get('percent','?')}")
                last_heartbeat = now
        if buf:
            try:
                process_line(bytes(buf).decode("utf-8", errors="replace"))
            except Exception:
                pass
    finally:
        try: stdout_fd.flush()
        except Exception: pass
        # Финальный кадр: 100% done — dashboard покажет ~8 секунд и спрячет
        final = dict(last_data) if last_data else dict(base)
        final["percent"] = 100
        final["done"] = True
        final["updated"] = int(time.time())
        atomic_write(final)


if __name__ == "__main__":
    main()
