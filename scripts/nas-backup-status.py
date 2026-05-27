#!/usr/bin/env python3
# =============================================================================
# nas-backup-status.py
# =============================================================================
# Сканирует /mnt/t7/nas-backup/ и пишет JSON статус для dashboard.
# Запускается:
#  1. systemd timer'ом раз в час (фоновое обновление размеров)
#  2. из nas-backup.sh в конце успешного бэкапа (сразу обновить)
#  3. dashboard'ом по кнопке "Refresh" (через sudo)
#
# Output: /var/lib/travel-nas/nas-backup-status.json (world-readable)
# =============================================================================

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CONFIG_PATH  = Path("/etc/travel-nas/nas-backup.conf")
STATUS_FILE  = Path("/var/lib/travel-nas/nas-backup-status.json")
DEFAULT_DEST = "/mnt/t7/nas-backup"


def read_modules_from_config():
    """Парсит DEST и MODULES из bash-конфига регулярками (без source/dev).
    Конфиг 600 → читать только root."""
    dest = DEFAULT_DEST
    modules = []
    if not CONFIG_PATH.exists():
        return dest, modules
    try:
        text = CONFIG_PATH.read_text()
    except Exception:
        return dest, modules
    m = re.search(r'^\s*DEST=["\']?([^"\'\n]+)', text, re.M)
    if m:
        dest = m.group(1).strip().rstrip('"').rstrip("'")
    arr = re.search(r"MODULES=\((.*?)\)", text, re.S)
    if arr:
        for line in arr.group(1).splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            tokens = re.findall(r'"([^"]+)"', line) or [line]
            for tok in tokens:
                tok = tok.strip()
                if "|" in tok:
                    modules.append(tok.split("|", 1)[1])
    return dest, modules


def scan_subdirs(dest):
    """Fallback: показываем подпапки если конфиг недоступен."""
    out = []
    try:
        for d in sorted(Path(dest).iterdir(), key=lambda p: p.name):
            if d.is_dir() and not d.name.startswith("_"):
                out.append(d.name)
    except Exception:
        pass
    return out


def folder_size(path):
    """du -sh — потенциально медленно (минуты на больших папках).
    Используем --apparent-size для детерминированности."""
    try:
        out = subprocess.check_output(
            ["du", "-sh", "--apparent-size", str(path)],
            timeout=900, stderr=subprocess.DEVNULL,
        ).decode().split()
        return out[0] if out else None
    except Exception:
        return None


def latest_log(log_dir, module_name):
    try:
        files = sorted(
            log_dir.glob(f"*_{module_name}.log"),
            key=lambda p: p.stat().st_mtime, reverse=True,
        )
        return files[0] if files else None
    except Exception:
        return None


def parse_log_status(path):
    """OK / WARN / FAIL по последним строкам лога."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 8192))
            tail = f.read().decode("utf-8", errors="replace")
    except Exception:
        return None
    low = tail.lower()
    if "rsync error" in low or "[err]" in low or "failed" in low:
        return "fail"
    if "[warn]" in low or "vanished" in low or "warnings" in low:
        return "warn"
    return "ok"


def disk_info(dest):
    try:
        out = subprocess.check_output(
            ["df", "-h", "--output=used,avail,size,pcent", dest],
            timeout=5,
        ).decode().splitlines()
        if len(out) < 2:
            return None
        p = out[1].split()
        return {"used": p[0], "avail": p[1], "total": p[2],
                "pct":  int(p[3].rstrip("%"))}
    except Exception:
        return None


def main():
    dest, modules = read_modules_from_config()
    if not modules:
        modules = scan_subdirs(dest)

    log_dir = Path(dest) / "_logs"
    out_modules = []
    for name in modules:
        path = Path(dest) / name
        entry = {"name": name, "exists": path.exists()}
        if entry["exists"]:
            entry["size"] = folder_size(path)
            log = latest_log(log_dir, name)
            if log is not None:
                entry["last_run"] = int(log.stat().st_mtime)
                entry["status"]   = parse_log_status(log)
            else:
                entry["last_run"] = None
                entry["status"]   = None
        out_modules.append(entry)

    data = {
        "updated": int(time.time()),
        "dest":    dest,
        "modules": out_modules,
    }
    di = disk_info(dest)
    if di:
        data["disk"] = di

    STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATUS_FILE.with_suffix(".json.tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, STATUS_FILE)
    try:
        os.chmod(STATUS_FILE, 0o644)
    except Exception:
        pass
    print(f"wrote {STATUS_FILE}: {len(out_modules)} modules")


if __name__ == "__main__":
    sys.exit(main() or 0)
