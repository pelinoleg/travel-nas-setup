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


def latest_log_with_stats(log_dir, module_name, max_check=5):
    """Возвращает самый свежий лог где есть `Total file size` (rsync --stats).
    Прерванный Stop'ом backup такого блока не пишет — берём предыдущий.
    Смотрим максимум max_check логов, чтобы не сканировать историю годами."""
    try:
        files = sorted(
            log_dir.glob(f"*_{module_name}.log"),
            key=lambda p: p.stat().st_mtime, reverse=True,
        )[:max_check]
        for f in files:
            if TOTAL_SIZE_RE.search(_read_log_tail(f, 32768)):
                return f
    except Exception:
        pass
    return None


def _read_log_tail(path, n_bytes=32768):
    """Читает последние n_bytes лога. Rsync пишет --stats блоком в конце,
    поэтому tail обычно содержит всё интересное. 32KB — с запасом под
    цветные ESC-коды и многомодульные логи."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - n_bytes))
            return f.read().decode("utf-8", errors="replace")
    except Exception:
        return ""


def parse_log_status(path):
    """OK / WARN / FAIL / PARTIAL по последним строкам лога.

    PARTIAL = backup был запущен но не завершился (нет rsync --stats блока
    в конце). Бывает когда юзер сделал Stop, или процесс прибили cgroup'ом.
    Это важный сигнал: status='ok' раньше показывался даже для прерванных
    backup'ов потому что в логе нет error/warn keywords."""
    tail = _read_log_tail(path, 32768)
    if not tail:
        return None
    low = tail.lower()
    if "rsync error" in low or "[err]" in low or "failed" in low:
        return "fail"
    if "[warn]" in low or "vanished" in low or "warnings" in low:
        return "warn"
    # Маркер успешного завершения rsync'а: блок --stats с "Total file size"
    if TOTAL_SIZE_RE.search(tail):
        return "ok"
    return "partial"


# rsync --stats output ищем "Total file size: 1,234,567,890 bytes" или
# "Total file size: 1.23G bytes" (зависит от -h). Возвращаем human-readable.
TOTAL_SIZE_RE = re.compile(
    r"Total file size:\s+([\d,.]+\s*[KMGT]?)\s*bytes",
    re.I,
)


def _humanize(n_bytes):
    n = float(n_bytes)
    for u in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return f"{int(n)}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"


def parse_source_size(path):
    """Из rsync --stats блока в логе вытягиваем 'Total file size' —
    объём данных на источнике (NAS) на момент последнего завершённого
    rsync'а. Юзер сравнит с local size и поймёт что ещё не докопировалось.

    Returns: human-readable string ('1.23G') или None если в логе нет stats
    (например бэкап был прерван stop'ом)."""
    tail = _read_log_tail(path, 32768)
    if not tail:
        return None
    m = TOTAL_SIZE_RE.search(tail)
    if not m:
        return None
    raw = m.group(1).strip()
    # Если уже human (1.23G) — возвращаем как есть, добавляя только B если нет суффикса
    if raw and raw[-1] in "KMGT":
        return raw
    # Иначе чистые байты с запятыми
    try:
        n = int(raw.replace(",", "").rstrip("."))
        return _humanize(n)
    except ValueError:
        return raw


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
                # nas_size — ищем последний лог где есть rsync --stats блок
                # (прерванные Stop'ом логи такого блока не имеют). Так юзер
                # видит source size даже если последний run был прерван.
                stats_log = latest_log_with_stats(log_dir, name)
                entry["nas_size"] = parse_source_size(stats_log) if stats_log else None
            else:
                entry["last_run"] = None
                entry["status"]   = None
                entry["nas_size"] = None
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
