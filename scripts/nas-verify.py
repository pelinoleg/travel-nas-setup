#!/usr/bin/env python3
# =============================================================================
# nas-verify.py — bit-rot / disk-error scrub для T7
# =============================================================================
# Что делает (раз в месяц по systemd-timer):
#   1. Идёт по всем файлам в /mnt/t7/usb-imports + /mnt/t7/nas-backup
#   2. Читает каждый байт → считает sha256. Чтение всех байт заставляет
#      SSD пройти все сектора → bad-sector ошибки в dmesg видно сразу.
#   3. Сохраняет манифест: hash mtime size path. Сравнивает с прошлым:
#      - hash отличается + mtime/size те же → BIT-ROT (тихая коррупция).
#      - hash + mtime + size отличаются → нормальное обновление (rsync).
#      - в старом нет, в новом есть → новый файл.
#      - в старом есть, в новом нет → удалён.
#   4. Считает I/O-ошибки в dmesg с момента старта.
#   5. Пишет JSON-статус в /var/lib/travel-nas/verify-status.json для дашборда.
#   6. Если есть bit-rot или I/O-ошибки — алёрт в Telegram.
#
# Хранится 6 последних манифестов (= 6 месяцев истории при месячной частоте).
#
# Использование:
#   nas-verify.py                  — полный scrub
#   nas-verify.py --status         — печать /var/lib/.../verify-status.json
#   nas-verify.py --target DIR     — конкретная папка вместо дефолтных
# =============================================================================

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path

T7_MOUNT = Path("/mnt/t7")
LOG_FILE = T7_MOUNT / "_logs" / "verify.log"
MANIFEST_DIR = T7_MOUNT / "_logs" / "verify-manifests"
STATUS_JSON = Path("/var/lib/travel-nas/verify-status.json")
TG_NOTIFY = Path("/usr/local/bin/tg-notify.sh")

# По умолчанию сканируем: usb-imports (фото-копии, не меняются) и
# nas-backup (там rsync периодически перезаписывает — bit-rot ловится по
# mtime/size: если те же, а хэш сменился — это коррупция).
DEFAULT_TARGETS = ["usb-imports", "nas-backup"]

# Пропуск .incomplete (прерванные backup'ы) и системных файлов
SKIP_PATTERNS = (".incomplete", "/_logs/", "/.cache/", "/.git/", "@eaDir")

# Чанк для чтения файла (4 MiB — оптимум для SSD без перегруза RAM)
CHUNK = 4 * 1024 * 1024

MAX_MANIFESTS = 6


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def sha256_file(path):
    """sha256 файла; None если файл не читается (включая I/O ошибки)."""
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def iter_files(targets):
    """Все обычные файлы в targets, пропуская SKIP_PATTERNS и не-regular."""
    for t in targets:
        base = T7_MOUNT / t
        if not base.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            # skip directories matching skip patterns
            if any(p in dirpath for p in SKIP_PATTERNS):
                dirnames[:] = []
                continue
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                if any(p in full for p in SKIP_PATTERNS):
                    continue
                # symlinks мимо — не следуем (могут уйти за T7)
                try:
                    st = os.lstat(full)
                    if not st.st_mode & 0o170000 == 0o100000:  # regular file
                        continue
                except OSError:
                    continue
                yield full, st


def latest_manifest():
    if not MANIFEST_DIR.exists():
        return None
    files = sorted(MANIFEST_DIR.glob("*.tsv"), reverse=True)
    return files[0] if files else None


def load_manifest(path):
    """TSV → dict: path → (sha, mtime, size)."""
    out = {}
    if not path or not path.exists():
        return out
    try:
        with open(path) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) != 4:
                    continue
                sha, mtime, size, p = parts
                out[p] = (sha, int(mtime), int(size))
    except Exception as e:
        log(f"warn: load_manifest({path}) failed: {e}")
    return out


def dmesg_io_errors():
    """Кол-во I/O / EXT4-fs error в dmesg за всё доступное окно ring buffer."""
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "dmesg"], timeout=5,
            stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
        keywords = ("I/O error", "Buffer I/O error", "EXT4-fs error",
                    "Medium Error", "blk_update_request")
        return sum(1 for ln in out.splitlines() if any(k in ln for k in keywords))
    except Exception:
        return 0


def tg_alert(title, body):
    if not TG_NOTIFY.exists():
        return
    try:
        subprocess.run(
            ["sudo", "-n", str(TG_NOTIFY), "-l", "warning", title, body],
            timeout=15, check=False,
        )
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true",
                    help="Печатает JSON прошлого запуска и выходит")
    ap.add_argument("--target", action="append",
                    help="Подпапка(и) T7 вместо дефолтных")
    args = ap.parse_args()

    if args.status:
        if STATUS_JSON.exists():
            print(STATUS_JSON.read_text())
        else:
            print("{}")
        return 0

    targets = args.target or DEFAULT_TARGETS
    log(f"=== verify start, targets={targets} ===")
    start = time.time()

    MANIFEST_DIR.mkdir(parents=True, exist_ok=True)
    ts_label = time.strftime("%Y%m%d-%H%M%S")
    new_manifest = MANIFEST_DIR / f"{ts_label}.tsv"

    prev = load_manifest(latest_manifest())
    new = {}

    total_files = 0
    read_errors = 0  # файлы которые не смогли прочитать (вероятно bad sector)
    bytes_read = 0

    with open(new_manifest, "w") as out:
        for full, st in iter_files(targets):
            sha = sha256_file(full)
            if sha is None:
                read_errors += 1
                continue
            mtime = int(st.st_mtime)
            size = st.st_size
            new[full] = (sha, mtime, size)
            out.write(f"{sha}\t{mtime}\t{size}\t{full}\n")
            total_files += 1
            bytes_read += size
            # Лёгкий heartbeat в лог каждые 10000 файлов
            if total_files % 10000 == 0:
                log(f"  ... {total_files} files, {bytes_read >> 30} GiB read")

    # Сравнение с прошлым манифестом
    added = []
    deleted = []
    changed_normal = []      # hash ≠, но mtime или size тоже изменились → норм
    changed_bitrot = []      # hash ≠, при этом mtime+size совпадают → коррупция

    all_paths = set(prev) | set(new)
    for p in all_paths:
        was = prev.get(p)
        is_ = new.get(p)
        if was is None:
            added.append(p)
            continue
        if is_ is None:
            deleted.append(p)
            continue
        if was[0] != is_[0]:
            if was[1] == is_[1] and was[2] == is_[2]:
                changed_bitrot.append(p)
            else:
                changed_normal.append(p)

    io_errors = dmesg_io_errors()
    elapsed = int(time.time() - start)

    log(f"Files:         {total_files} ({bytes_read >> 30} GiB)")
    log(f"Read failures: {read_errors}")
    log(f"New:           {len(added)}")
    log(f"Deleted:       {len(deleted)}")
    log(f"Changed (ok):  {len(changed_normal)}")
    log(f"BIT-ROT:       {len(changed_bitrot)}  ← hash сменился без mtime/size")
    log(f"dmesg I/O:     {io_errors}")
    log(f"Elapsed:       {elapsed}s")

    if changed_bitrot:
        log("First 10 BIT-ROT suspects:")
        for p in changed_bitrot[:10]:
            log(f"  ! {p}")

    status_ok = (len(changed_bitrot) == 0 and io_errors == 0 and read_errors == 0)
    status = {
        "last_run":       ts_label,
        "elapsed_sec":    elapsed,
        "total_files":    total_files,
        "bytes_read":     bytes_read,
        "read_failures":  read_errors,
        "added":          len(added),
        "deleted":        len(deleted),
        "changed_normal": len(changed_normal),
        "bitrot":         len(changed_bitrot),
        "io_errors":      io_errors,
        "status":         "ok" if status_ok else "alert",
        "bitrot_sample":  changed_bitrot[:5],
    }
    STATUS_JSON.parent.mkdir(parents=True, exist_ok=True)
    STATUS_JSON.write_text(json.dumps(status, indent=2))

    # Чистим старые манифесты (оставляем MAX_MANIFESTS свежих)
    olds = sorted(MANIFEST_DIR.glob("*.tsv"), reverse=True)
    for old in olds[MAX_MANIFESTS:]:
        try:
            old.unlink()
        except Exception:
            pass

    # Telegram alert если плохо
    if not status_ok:
        sample = "\n".join(f"• {p}" for p in changed_bitrot[:5]) or "_(none)_"
        tg_alert(
            "T7 verify alert",
            f"""Verify нашёл проблемы на T7:

• BIT-ROT (hash сменился без mtime): {len(changed_bitrot)}
• Read failures (bad sector?): {read_errors}
• dmesg I/O errors: {io_errors}

Подозрительные:
{sample}

Лог: {LOG_FILE}
Manifest: {new_manifest}""",
        )

    log(f"=== verify done in {elapsed}s, status={status['status']} ===")
    return 0 if status_ok else 1


if __name__ == "__main__":
    sys.exit(main())
