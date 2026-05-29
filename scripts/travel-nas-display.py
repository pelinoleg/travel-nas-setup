#!/usr/bin/env python3
# =============================================================================
# travel-nas-display.py - Dashboard для MHS35 (320x480 touch, vertical)
# =============================================================================
# Pygame-based kiosk dashboard для travel-NAS. Всё внутри одного pygame-окна:
# статус, меню действий, viewer логов, AP-info, progress бэкапа.
# Никаких внешних терминалов — фокус никогда не уходит, тач работает всегда.
#
# Прогресс бэкапа читается из /var/run/travel-nas/backup-progress.json
# (туда пишут photo-backup.sh и nas-backup.sh через backup-progress-writer.py).
#
# Auto-sleep подсветки через 5 минут неактивности (xset dpms).
# =============================================================================

import os
import re
import sys
import json
import time
import socket
import subprocess
import urllib.request
import pygame
from pathlib import Path
from datetime import datetime

# =============================================================================
# Configuration
# =============================================================================
SCREEN_W, SCREEN_H = 320, 480
FPS = 15
REFRESH_INTERVAL = 1.5         # обычное обновление UI
FAST_REFRESH_INTERVAL = 0.05   # пока активны touch-flash / toast
SLEEP_AFTER_SEC = 300          # default — переопределяется /var/lib/travel-nas/sleep-timeout
SLEEP_TIMEOUT_FILE = Path("/var/lib/travel-nas/sleep-timeout")
TOAST_DURATION = 2.0
TOUCH_FLASH_DURATION = 0.25
TOUCH_DEDUP_WINDOW = 0.12      # игнорируем дубль touch+mouse в одно касание
FORCE_ABOVE_INTERVAL = 3       # cheap re-assert: ловит pcmanfm/udev попапы быстро

STATE_DIR = Path("/var/run/travel-nas")
PROGRESS_FILE   = STATE_DIR / "backup-progress.json"
SCREENSHOT_REQ  = STATE_DIR / "screenshot-req"  # touch = запросить снимок
SCREENSHOT_OUT  = STATE_DIR / "dashboard.png"   # дашборд сюда сохраняет
ERROR_LOG = Path("/tmp/travel-nas-display.error.log")

T7_MOUNT = "/mnt/t7"

SERVICES_CONF      = Path("/etc/travel-nas/services.conf")
YT_ARCHIVER_CONF   = Path("/etc/travel-nas/yt-archiver.conf")
NAS_STATUS_JSON    = Path("/var/lib/travel-nas/nas-backup-status.json")
DAILY_SUMMARY_JSON = Path("/var/lib/travel-nas/daily-summary.json")
POWER_MODE_FILE    = Path("/var/lib/travel-nas/power-mode.txt")
POWER_PREF_FILE    = Path("/var/lib/travel-nas/power-mode-pref")
SERVICES_DEFAULTS = [
    ("CasaOS",      "http://{host}"),
    ("Photoview",   "http://{host}:8000"),
    ("yt-archiver", "http://{host}:8081"),
    ("Samba",       "smb://{host}/travel-nas"),
    ("SSH",         "ssh oleg@{host}"),
]

LOG_OPTIONS = [
    ("Photo backup",   "/mnt/t7/_logs/photo-backup.log"),
    ("NAS backup",     "__nas_latest__"),
    ("Watchdog",       "/mnt/t7/_logs/disk-watchdog.log"),
    ("System monitor", "/mnt/t7/_logs/system-monitor.log"),
    ("Thermal guard",  "/mnt/t7/_logs/thermal-guard.log"),
    ("Display errors", str(ERROR_LOG)),
]

# Colors (Material Design dark)
BG            = (18, 18, 18)
PANEL         = (28, 28, 28)
PANEL_ACCENT  = (20, 42, 22)    # подложка для активного бэкапа (зелёный тинт)
PANEL_WARN    = (44, 32, 14)    # подложка для AP режима (оранжевый тинт)
FG            = (235, 235, 235)
ACCENT        = (76, 175, 80)   # green
WARN          = (255, 152, 0)   # orange
ERROR         = (244, 67, 54)   # red
INFO          = (33, 150, 243)  # blue
MUTED         = (110, 110, 110)
BTN_BG        = (42, 42, 42)
BAR_BG        = (40, 40, 40)

FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# =============================================================================
# Pygame setup
# =============================================================================
pygame.init()
pygame.mouse.set_visible(False)
pygame.display.set_caption("travel-nas-dashboard")

try:
    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H), pygame.NOFRAME)
except pygame.error:
    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H))


def force_above():
    """Прибиваем окно поверх LXDE-панели. Cheap: ~10ms, no-op если wmctrl нет."""
    for args in (
        ["wmctrl", "-r", "travel-nas-dashboard", "-b", "add,above,fullscreen"],
        ["wmctrl", "-r", "travel-nas-dashboard", "-e", "0,0,0,-1,-1"],
    ):
        try:
            subprocess.run(args, timeout=2, capture_output=True)
        except Exception:
            pass


# wmctrl видит окно только после первого flip
pygame.display.flip()
time.sleep(0.3)
force_above()

clock = pygame.time.Clock()
last_activity = time.time()
last_force_above = time.time()
last_touch_ts = 0.0
display_on = True
touch_flash = None   # (x, y, ts)


def load_font(size, bold=False):
    p = FONT_BOLD if bold else FONT_PATH
    if not Path(p).exists():
        return pygame.font.Font(None, size)
    return pygame.font.Font(p, size)


F_LARGE  = load_font(26, bold=True)
F_MED    = load_font(19, bold=True)
F_NORMAL = load_font(15)
F_SMALL  = load_font(13)
F_TINY   = load_font(11)
F_MONO   = pygame.font.SysFont("dejavusansmono,monospace", 11)


# =============================================================================
# System-info helpers (with simple TTL cache to keep redraws fast)
# =============================================================================
class Cached:
    """Вызывает fn не чаще interval секунд. Безопасен: исключения → старое значение."""
    def __init__(self, fn, interval):
        self.fn = fn
        self.interval = interval
        self.last = 0.0
        self.value = None
    def get(self):
        now = time.time()
        if now - self.last >= self.interval:
            try:
                self.value = self.fn()
            except Exception:
                pass
            self.last = now
        return self.value
    def invalidate(self):
        # Заставит следующий .get() перечитать. Нужно после действий, которые
        # меняют source-of-truth (нажали кнопку → переписали файл).
        self.last = 0.0


def _cpu_temp():
    out = subprocess.check_output(["vcgencmd", "measure_temp"], timeout=2).decode()
    return int(float(out.split("=")[1].split("'")[0]))


def _cpu_pct():
    """1-секундный измеритель загрузки через /proc/stat."""
    def snapshot():
        with open("/proc/stat") as f:
            parts = f.readline().split()
        # user nice system idle iowait irq softirq steal
        vals = list(map(int, parts[1:9]))
        idle = vals[3] + vals[4]
        total = sum(vals)
        return idle, total
    i1, t1 = snapshot()
    time.sleep(0.2)
    i2, t2 = snapshot()
    dt = t2 - t1
    if dt <= 0:
        return None
    return int(100 * (1 - (i2 - i1) / dt))


def _ram():
    with open("/proc/meminfo") as f:
        info = {}
        for line in f:
            k, _, rest = line.partition(":")
            info[k.strip()] = int(rest.strip().split()[0])  # KB
    total = info["MemTotal"]
    avail = info.get("MemAvailable", info["MemFree"])
    used = total - avail
    return {
        "total": total * 1024,
        "used":  used  * 1024,
        "pct":   int(used * 100 / total),
    }


def _swap():
    with open("/proc/meminfo") as f:
        info = {}
        for line in f:
            k, _, rest = line.partition(":")
            info[k.strip()] = int(rest.strip().split()[0])  # KB
    total = info.get("SwapTotal", 0)
    if total == 0:
        return None
    free = info.get("SwapFree", 0)
    used = total - free
    return {"total": total*1024, "used": used*1024, "pct": int(used*100/total)}


def _zram_ratio():
    for d in Path("/sys/block").glob("zram*"):
        try:
            stat = (d / "mm_stat").read_text().split()
            orig, compr = int(stat[0]), int(stat[1])
            if compr > 0:
                return orig / compr
        except Exception:
            continue
    return None


def _load():
    return os.getloadavg()[0]


def _throttled():
    """vcgencmd get_throttled → ('OK'|'NOW'|'past', color).

    Биты:
      0x1     under-voltage NOW
      0x2     arm freq capped NOW
      0x4     throttling NOW
      0x8     soft temp limit NOW (Pi 5)
      0x10000 under-voltage past
      0x20000 freq capped past
      0x40000 throttle past
      0x80000 soft temp past (Pi 5)

    NOW-биты могут мигать на доли секунды (Pi 5 быстро меняет состояние).
    Поллинг раз в 5 сек часто не ловит — но past-бит остаётся до reboot'а,
    так что в шапке всё равно видно что событие было."""
    out = subprocess.check_output(["vcgencmd", "get_throttled"], timeout=2).decode()
    val = int(out.strip().split("=")[1], 16)
    if val == 0:                return ("OK", ACCENT)
    if val & 0xF:               return ("NOW", ERROR)
    if val & 0xF0000:           return ("past", WARN)
    return ("OK", ACCENT)


_PMIC_RE = re.compile(r"\s*(\S+)_([AV])\s+\w+\(\d+\)=([\d.]+)[AV]")


def _watts():
    """Грубая оценка потребления Pi 5 через `vcgencmd pmic_read_adc`.
    Возвращает округлённое до целого число ватт (например 5) или None.
    Считаем сумму V*I по каждому rail у которого есть и V и A показания."""
    try:
        out = subprocess.check_output(
            ["vcgencmd", "pmic_read_adc"],
            timeout=3, stderr=subprocess.DEVNULL,
        ).decode()
    except Exception:
        return None
    rails = {}
    for line in out.splitlines():
        m = _PMIC_RE.match(line)
        if not m:
            continue
        rail, suffix, val = m.group(1), m.group(2), float(m.group(3))
        rails.setdefault(rail, {})[suffix] = val
    total = 0.0
    for d in rails.values():
        if "V" in d and "A" in d:
            total += d["V"] * d["A"]
    if total <= 0:
        return None
    return round(total)


def _t7_temp():
    device = subprocess.check_output(
        ["findmnt", "-n", "-o", "SOURCE", T7_MOUNT], timeout=2
    ).decode().strip()
    if not device:
        return None
    device = device.rstrip("0123456789")
    out = subprocess.check_output(
        ["sudo", "-n", "/usr/sbin/smartctl", "-a", "-d", "sat", device],
        timeout=5, stderr=subprocess.DEVNULL,
    ).decode()
    for line in out.splitlines():
        if "Temperature" in line:
            for p in line.split():
                if p.isdigit() and 10 < int(p) < 100:
                    return int(p)
    return None


def _disk_info():
    # Без проверки mountpoint df вернёт цифры корневого раздела (когда /mnt/t7
    # существует как пустой каталог без mount) — выглядело бы как «всё ОК».
    if not Path(T7_MOUNT).is_mount():
        return None
    # Hot-pull: mount остаётся прописан, df возвращает кэш metaданных, но
    # любая I/O операция фейлит. Делаем cheap listdir-probe чтобы поймать.
    try:
        os.listdir(T7_MOUNT)
    except OSError:
        return "io_error"
    try:
        out = subprocess.check_output(
            ["df", "-h", "--output=used,avail,size,pcent", T7_MOUNT], timeout=2
        ).decode().splitlines()
    except Exception:
        return "io_error"
    if len(out) < 2:
        return None
    p = out[1].split()
    return {"used": p[0], "avail": p[1], "total": p[2], "pct": int(p[3].rstrip("%"))}


def _ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        # Fallback: hostname -I first non-loopback
        try:
            out = subprocess.check_output(["hostname", "-I"], timeout=2).decode().split()
            return out[0] if out else None
        except Exception:
            return None


def _gateway():
    out = subprocess.check_output(["ip", "route", "show", "default"], timeout=2).decode()
    for line in out.splitlines():
        if line.startswith("default"):
            parts = line.split()
            if "via" in parts:
                return parts[parts.index("via") + 1]
    return None


def _wifi():
    """SSID + signal через iw."""
    try:
        out = subprocess.check_output(
            ["iw", "dev", "wlan0", "link"], timeout=2, stderr=subprocess.DEVNULL,
        ).decode()
    except Exception:
        return {"ssid": None, "signal": None}
    ssid, signal = None, None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("SSID:"):
            ssid = line.split(":", 1)[1].strip() or None
        elif line.startswith("signal:"):
            try:
                signal = int(line.split(":", 1)[1].strip().split()[0])
            except Exception:
                pass
    return {"ssid": ssid, "signal": signal}


def _smb_clients():
    """Считаем подключенных SMB-клиентов через smbstatus -b. 0 если не доступно."""
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/bin/smbstatus", "-b"],
            timeout=3, stderr=subprocess.DEVNULL,
        ).decode()
    except Exception:
        return 0
    count = 0
    for line in out.splitlines():
        s = line.strip()
        if s and s.split()[0].isdigit():
            count += 1
    return count


def _comitup_state():
    try:
        out = subprocess.check_output(
            ["comitup-cli", "i"], timeout=3, stderr=subprocess.DEVNULL,
        ).decode()
    except Exception:
        return None
    for line in out.splitlines():
        if "tate" in line:  # "State" / "state"
            return line.split(":", 1)[1].strip()
    return None


def _last_photo_backup():
    base = Path(T7_MOUNT) / "usb-imports"
    if not base.exists():
        return None
    dates = sorted([d for d in base.iterdir() if d.is_dir()], reverse=True)
    if not dates:
        return None
    latest_date = dates[0]
    backups = sorted([d for d in latest_date.iterdir() if d.is_dir()], reverse=True)
    if not backups:
        return None
    latest = backups[0]
    files = 0
    try:
        for _ in latest.rglob("*"):
            if _.is_file():
                files += 1
                if files > 9999:
                    break
    except Exception:
        pass
    return {"date": latest_date.name, "name": latest.name, "files": files}


def _uptime():
    with open("/proc/uptime") as f:
        secs = float(f.read().split()[0])
    d, secs = divmod(secs, 86400)
    h, secs = divmod(secs, 3600)
    m = secs // 60
    if d > 0: return f"{int(d)}d {int(h)}h"
    if h > 0: return f"{int(h)}h {int(m)}m"
    return f"{int(m)}m"


# Cache instances — interval подобран под стоимость каждой команды
c_cpu_temp = Cached(_cpu_temp,        2)
c_cpu_pct  = Cached(_cpu_pct,         3)
c_ram      = Cached(_ram,             2)
c_swap     = Cached(_swap,            4)
c_zram     = Cached(_zram_ratio,      5)
c_load     = Cached(_load,            2)
c_throttle = Cached(_throttled,       5)
c_watts    = Cached(_watts,           5)
c_t7_temp  = Cached(_t7_temp,        30)
c_disk     = Cached(_disk_info,       5)
c_ip       = Cached(_ip,              5)
c_gateway  = Cached(_gateway,        10)
c_wifi     = Cached(_wifi,            3)
c_smb      = Cached(_smb_clients,     5)
c_comitup  = Cached(_comitup_state,   8)
c_last     = Cached(_last_photo_backup, 15)
c_uptime   = Cached(_uptime,          5)


def _system_busy():
    """True если в системе бежит rsync/docker-build/etc — экран не гасим."""
    # pgrep вернёт >0 exit code если процессов нет → False
    try:
        subprocess.check_output(
            ["pgrep", "-x", "rsync"], timeout=2, stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        pass
    return False


c_busy     = Cached(_system_busy,     4)


def _nas_backup_active():
    """True если systemd-unit `nas-backup-runtime` сейчас живой (бэкап идёт).
    Используется на странице NAS чтоб показать кнопку Stop."""
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "--quiet", "nas-backup-runtime"],
            timeout=2,
        )
        return r.returncode == 0
    except Exception:
        return False


c_nas_run  = Cached(_nas_backup_active, 3)


def _parse_size(s):
    """'1.23G' / '500M' / '500K' / '1.2T' / '500B' → bytes. Возвращает None
    если не парсится. Поддерживает du-формат (без 'i'/'B' суффикса)."""
    if not s or not isinstance(s, str):
        return None
    s = s.strip()
    if not s:
        return None
    units = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3,
             "T": 1024**4, "P": 1024**5}
    suf = s[-1].upper()
    if suf in units:
        try: return float(s[:-1]) * units[suf]
        except ValueError: return None
    try: return float(s)
    except ValueError: return None


def _size_lt(a, b, tolerance=0.95):
    """True если a существенно меньше b. Tolerance 95% — 5% разницы между
    `du --apparent-size` локально и `Total file size` от rsync считаем за
    'совпадает' (округление, инодные накладные). Без tolerance любая микро-
    разница давала бы 'not fully copied'."""
    av = _parse_size(a)
    bv = _parse_size(b)
    if av is None or bv is None:
        return False
    return av < bv * tolerance


def human_bytes(n):
    if n is None: return "?"
    n = float(n)
    for u in ("B", "K", "M", "G", "T"):
        if n < 1024:
            return f"{int(n)}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}P"


def get_progress():
    if not PROGRESS_FILE.exists():
        return None
    try:
        with open(PROGRESS_FILE) as f:
            data = json.load(f)
    except Exception:
        return None
    age = time.time() - data.get("updated", 0)
    # Done — показываем ещё 8 секунд и убираем
    if data.get("done"):
        if age > 8:
            try: PROGRESS_FILE.unlink()
            except Exception: pass
            return None
        return data
    # JSON есть но source не active — backup умер не по-плохому (trap не
    # отработал). Удаляем stale JSON. Не дёргаем systemctl каждый раз —
    # используем кэш c_nas_run (3 сек интервал).
    if age > 5 and not c_nas_run.get():
        try: PROGRESS_FILE.unlink()
        except Exception: pass
        return None
    # Не done — rsync может сканировать большую карту минутами без обновлений.
    # Считаем "застрявшим" только после 5 минут тишины.
    if age > 300:
        try: PROGRESS_FILE.unlink()
        except Exception: pass
        return None
    return data


def is_ap_mode():
    ip = c_ip.get()
    return bool(ip and ip.startswith("10.41."))


def _yt_archiver_url():
    """URL из /etc/travel-nas/yt-archiver.conf или дефолт. Без trailing slash."""
    default = "http://localhost:8081"
    if not YT_ARCHIVER_CONF.exists():
        return default
    try:
        for line in YT_ARCHIVER_CONF.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^\s*URL\s*=\s*["\']?([^"\'\s]+)', line)
            if m:
                return m.group(1).rstrip("/")
    except Exception:
        pass
    return default


def _yt_stats():
    """Запрашивает у yt-archiver /api/stats + /api/queue. Возвращает dict с
    каналами/видео/размером/статусами очереди, или None при ошибке.

    Лёгкий вызов (быстрый ответ < 200ms), но всё равно кэшируем чтобы не
    долбить контейнер каждым рендером."""
    base = _yt_archiver_url()
    out = {}
    try:
        with urllib.request.urlopen(f"{base}/api/stats", timeout=4) as r:
            s = json.loads(r.read())
            out["channels"] = s.get("channels", 0)
            out["videos"]   = s.get("videos", 0)
            out["bytes"]    = s.get("total_bytes", 0)
    except Exception:
        return None
    try:
        with urllib.request.urlopen(f"{base}/api/queue", timeout=5) as r:
            q = json.loads(r.read())
        by_status = {}
        downloading = []
        for item in q:
            st = item.get("status") or "?"
            by_status[st] = by_status.get(st, 0) + 1
            if st == "downloading" and len(downloading) < 3:
                downloading.append({
                    "channel": item.get("channel_name") or "?",
                    "title":   item.get("title") or "?",
                    "progress": item.get("progress") or 0,
                })
        out["queue"]       = by_status
        out["downloading"] = downloading
    except Exception:
        out["queue"]       = {}
        out["downloading"] = []
    # /api/queue/status даёт paused flag — нужен для toggle-кнопки
    try:
        with urllib.request.urlopen(f"{base}/api/queue/status", timeout=3) as r:
            qs = json.loads(r.read())
            out["paused"] = bool(qs.get("paused"))
    except Exception:
        out["paused"] = False
    return out


c_yt = Cached(_yt_stats, 30)


def _yt_toggle_pause(currently_paused):
    """POST'ит pause или resume в зависимости от текущего состояния.
    Возвращает (ok, new_paused_state)."""
    base = _yt_archiver_url()
    endpoint = "resume" if currently_paused else "pause"
    try:
        req = urllib.request.Request(f"{base}/api/queue/{endpoint}",
                                     method="POST")
        with urllib.request.urlopen(req, timeout=4) as r:
            r.read()
        return True, not currently_paused
    except Exception:
        return False, currently_paused


def _parse_services_conf(text):
    """Расширенный парсер services.conf:
    - 'NAME=URL'     → новый сервис (имя над URL, две строки)
    - '>NAME=URL'    → inline: "NAME: URL" на одной строке (компактно)
    - '    notes'    → строка с отступом (4+ пробелов/таб) = заметка к
                       предыдущему сервису
    - '# comment'    → игнор
    - пустая         → игнор
    Возвращает [(name, url, [notes...], inline_bool), ...]"""
    out = []
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # Indented line — note к предыдущему сервису
        if line[0] in (" ", "\t") and out:
            out[-1][2].append(line.strip())
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            k = k.strip()
            inline = k.startswith(">")
            if inline:
                k = k[1:].strip()
            out.append((k, v.strip(), [], inline))
    return out


def load_services():
    """Возвращает [(name, url)] — из /etc/travel-nas/services.conf или дефолты.
    {host}/{ip} в URL подставляются текущими значениями."""
    items = SERVICES_DEFAULTS
    if SERVICES_CONF.exists():
        try:
            parsed = _parse_services_conf(SERVICES_CONF.read_text())
            if parsed:
                items = parsed
        except Exception:
            pass
    # Дефолты SERVICES_DEFAULTS — tuples (name, url). Дополняем notes=[],
    # inline=False чтобы единый формат с парсером (4-tuple).
    items = [
        (t[0], t[1],
         t[2] if len(t) > 2 else [],
         t[3] if len(t) > 3 else False)
        for t in items
    ]
    ip = c_ip.get() or "?"
    host = f"{socket.gethostname()}.local"
    return [
        (n,
         u.replace("{host}", host).replace("{ip}", ip),
         [note.replace("{host}", host).replace("{ip}", ip) for note in notes],
         inline)
        for n, u, notes, inline in items
    ]


def health_status():
    """Аггрегат "общего здоровья" — mount/SMART/temp/disk-fill.
    Throttling и питание оцениваются ОТДЕЛЬНО через ⚡-значок, не сюда."""
    bad, warn = False, False
    disk = c_disk.get()
    # disk: None (NOT MOUNTED) | "io_error" (mount висит, диск отвалился) | dict
    if not isinstance(disk, dict):
        bad = True   # любой не-dict — проблема
    else:
        if disk["pct"] >= 90:   bad = True
        elif disk["pct"] >= 80: warn = True
    t7t = c_t7_temp.get()
    if t7t and t7t >= 60: bad = True
    elif t7t and t7t >= 55: warn = True
    ct = c_cpu_temp.get()
    if ct and ct >= 75: bad = True
    elif ct and ct >= 65: warn = True
    if not c_ip.get(): warn = True
    if bad:  return ("ERR", ERROR)
    if warn: return ("WARN", WARN)
    return ("OK", ACCENT)


# =============================================================================
# Backlight (xset dpms)
# =============================================================================
def set_backlight(on):
    """Пытаемся реально выключить подсветку. На MHS35 (fb_ili9486) BL прибит
    к 5V напрямую — программно выключить нельзя без модификации железа.
    Тогда хотя бы заливаем экран чёрным (это делает main loop)."""
    global display_on
    if on == display_on:
        return
    val_off = "4"   # FB_BLANK_POWERDOWN
    val_on  = "0"   # FB_BLANK_UNBLANK
    # 1. Стандартный sysfs backlight (HDMI, DSI и нек. SPI)
    try:
        for p in Path("/sys/class/backlight").glob("*/bl_power"):
            try:
                p.write_text(val_on if on else val_off)
            except Exception:
                pass
    except Exception:
        pass
    # 2. X11 DPMS — для HDMI/DSI работает; для SPI-fbdev обычно no-op,
    #    но и не вредит. Параллельно делает framebuffer screensaver.
    try:
        subprocess.run(
            ["xset", "dpms", "force", "on" if on else "off"],
            timeout=2, capture_output=True,
        )
    except Exception:
        pass
    display_on = on


# =============================================================================
# Buttons / drawing primitives
# =============================================================================
class Btn:
    __slots__ = ("label", "action", "rect", "color", "primary")
    def __init__(self, label, action, rect, color=FG, primary=False):
        self.label, self.action, self.rect, self.color, self.primary = \
            label, action, rect, color, primary


def draw_button(b, font=None):
    f = font or F_NORMAL
    if b.primary:
        pygame.draw.rect(screen, b.color, b.rect, border_radius=8)
        text_color = BG
    else:
        pygame.draw.rect(screen, BTN_BG, b.rect, border_radius=8)
        pygame.draw.rect(screen, b.color, b.rect, 2, border_radius=8)
        text_color = FG
    text = f.render(b.label, True, text_color)
    screen.blit(text, text.get_rect(center=b.rect.center))


def draw_bar(x, y, w, h, pct, color):
    pygame.draw.rect(screen, BAR_BG, (x, y, w, h), border_radius=h // 2)
    fw = max(0, min(w, int(w * pct / 100)))
    if fw > 0:
        pygame.draw.rect(screen, color, (x, y, fw, h), border_radius=h // 2)


def _cpu_max_ghz():
    """Эффективный CPU-cap в GHz по текущему governor:
       powersave → scaling_min_freq (зажат на нижней),
       остальные (ondemand/performance/...) → scaling_max_freq."""
    base = "/sys/devices/system/cpu/cpu0/cpufreq"
    try:
        gov = Path(f"{base}/scaling_governor").read_text().strip()
        key = "scaling_min_freq" if gov == "powersave" else "scaling_max_freq"
        khz = int(Path(f"{base}/{key}").read_text().strip())
        return khz / 1_000_000
    except Exception:
        return None


c_cpu_max = Cached(_cpu_max_ghz, 8)


def _power_mode():
    """normal / saver / unknown — из /var/lib/travel-nas/power-mode.txt."""
    try:
        return POWER_MODE_FILE.read_text().strip() if POWER_MODE_FILE.exists() else "unknown"
    except Exception:
        return "unknown"


def _power_pref():
    """normal / saver / auto — выбор юзера (default auto)."""
    try:
        return POWER_PREF_FILE.read_text().strip() if POWER_PREF_FILE.exists() else "auto"
    except Exception:
        return "auto"


c_pmode = Cached(_power_mode, 5)
c_ppref = Cached(_power_pref, 5)


def _sleep_timeout():
    """Сколько секунд до auto-sleep. Читает SLEEP_TIMEOUT_FILE (юзер меняет
    через TG /sleep). 0 = никогда не гасить. Default = SLEEP_AFTER_SEC."""
    try:
        if SLEEP_TIMEOUT_FILE.exists():
            v = int(SLEEP_TIMEOUT_FILE.read_text().strip())
            if v >= 0:
                return v
    except Exception:
        pass
    return SLEEP_AFTER_SEC


c_sleep = Cached(_sleep_timeout, 5)


def _top_processes(n=5, sort="cpu"):
    """Top N процессов по CPU или MEM. ps без sudo — видит всех."""
    sort_key = "-pcpu" if sort == "cpu" else "-pmem"
    try:
        out = subprocess.check_output(
            ["ps", "-eo", "pcpu,pmem,comm",
             "--sort=" + sort_key, "--no-headers"],
            timeout=2,
        ).decode()
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        try:
            cpu = float(parts[0])
            mem = float(parts[1])
        except ValueError:
            continue
        # Игнорим idle процессы (ps включает и kthread'ы с 0% — не интересно)
        if sort == "cpu" and cpu < 0.5:
            continue
        if sort == "mem" and mem < 0.5:
            continue
        rows.append({"cpu": cpu, "mem": mem, "name": parts[2].strip()[:22]})
        if len(rows) >= n:
            break
    return rows


c_top_cpu = Cached(lambda: _top_processes(5, "cpu"), 3)
c_top_mem = Cached(lambda: _top_processes(5, "mem"), 3)


def _ensure_desktop_icons():
    """Создаёт/перезаписывает 2 .desktop в ~/Desktop. Идемпотентно: если уже
    есть — overwrite (никаких дублей). Дёргается при Exit to desktop, чтоб
    после reinstall ярлыки появлялись без отдельной команды."""
    try:
        desktop = Path.home() / "Desktop"
        desktop.mkdir(parents=True, exist_ok=True)
        dashboard_desktop = """[Desktop Entry]
Version=1.0
Type=Application
Name=Dashboard
Comment=Re-open the kiosk dashboard
Exec=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
Icon=display
Terminal=false
Categories=System;
"""
        update_desktop = """[Desktop Entry]
Version=1.0
Type=Application
Name=Update
Comment=Pull latest scripts from GitHub
Exec=lxterminal --geometry=100x30 -e bash -c "travel-nas-update; echo; echo 'Готово. Нажми Enter чтобы закрыть.'; read"
Icon=system-software-update
Terminal=false
Categories=System;
"""
        for name, content in (
            ("Travel-NAS-Dashboard.desktop", dashboard_desktop),
            ("Travel-NAS-Update.desktop",    update_desktop),
        ):
            p = desktop / name
            p.write_text(content)
            p.chmod(0o755)
        # Пинаем pcmanfm чтоб подхватил без релогина
        subprocess.Popen(
            ["pcmanfm", "--reconfigure"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception:
        # Не критично если что-то не получилось — иконки всё равно создаются
        # модулем 20-desktop и travel-nas-update'ом
        pass


def _shutdown_screen(text):
    """Заливает экран чёрным + крупный текст по центру. Вызывается ПЕРЕД
    halt'ом — MHS35 LCD persistence сохранит этот кадр после power-off
    (вместо тоста 'Shutting down…' который выглядит как зависание).
    Также форсим pygame.display.flip() чтобы кадр точно ушёл на дисплей."""
    screen.fill((0, 0, 0))
    y = SCREEN_H // 2 - 60
    for line in text.split("\n"):
        if line.strip():
            col = ERROR if line == line.upper() and len(line) > 3 else MUTED
            f = F_LARGE if col == ERROR else F_SMALL
            surf = f.render(line, True, col)
            screen.blit(surf, surf.get_rect(center=(SCREEN_W // 2, y)))
        y += 24
    pygame.display.flip()


def draw_top_strip(page_label=None):
    """Top-strip:
       Слева:  ● health-точка + (page_label | uptime)
       Справа: [⚡] [A·]<mode> <freq>GHz <W>W · <sleep_remaining>
       A·<mode>: pref=auto. Без префикса = ручной режим. Слово 'power:'
       убрано чтоб дать место sleep-индикатору."""
    pygame.draw.rect(screen, PANEL, (0, 0, SCREEN_W, 22))
    _, color = health_status()
    pygame.draw.circle(screen, color, (12, 11), 5)

    if page_label:
        left_text = page_label
    else:
        up = c_uptime.get()
        left_text = f"up {up}" if up else "up ?"
    screen.blit(F_SMALL.render(left_text, True, FG), (24, 4))

    # === Right pieces ===
    th = c_throttle.get()
    mode = c_pmode.get()
    pref = c_ppref.get()
    mode_color = ACCENT if mode == "normal" else (WARN if mode == "saver" else MUTED)
    mhz = c_cpu_max.get()
    w = c_watts.get()

    pieces = []
    # ⚡ для NOW (красный — событие СЕЙЧАС) и past (оранжевый — было, бит
    # остаётся до reboot). Кратковременные просадки Pi 5 чаще ловятся только
    # в past — иначе их не увидеть между поллингами.
    if th and th[0] == "NOW":
        pieces.append(F_SMALL.render("⚡", True, ERROR))
    elif th and th[0] == "past":
        pieces.append(F_SMALL.render("⚡", True, WARN))
    if pref == "auto":
        pieces.append(F_SMALL.render("A·", True, INFO))
    if mode and mode != "unknown":
        pieces.append(F_SMALL.render(mode, True, mode_color))
    if mhz is not None:
        pieces.append(F_SMALL.render(f"{mhz:.1f}G", True, MUTED))  # `G` короче `GHz`
    if w is not None:
        pieces.append(F_SMALL.render(f"{w}W", True, MUTED))

    # Sleep countdown. Скрываем когда sleep всё равно заблокирован условиями
    # main loop'а (backup/rsync активен) — иначе юзер видит "z 0s" но экран
    # не гаснет, выглядит как баг.
    sleep_to = c_sleep.get()
    sleep_blocked = (get_progress() is not None) or c_busy.get()
    if sleep_to > 0 and display_on and not sleep_blocked:
        rem = sleep_to - (time.time() - last_activity)
        if rem >= 1:   # < 1 сек не показываем — sleep сейчас сработает
            # Формат: показываем 2 единицы granularity чтобы не было
            # сюрприза. 4h47m раньше отображалось как просто "4h" — юзер
            # не понимал что ещё ~час до sleep'а.
            if rem < 60:
                rem_str = f"{int(rem)}s"
            elif rem < 300:                       # < 5 мин — секунды важны
                m, s = int(rem // 60), int(rem % 60)
                rem_str = f"{m}m {s:02d}s"
            elif rem < 3600:
                rem_str = f"{int(rem // 60)}m"
            else:
                h, m = int(rem // 3600), int((rem % 3600) // 60)
                rem_str = f"{h}h {m:02d}m"
            rem_col = ERROR if rem < 10 else (WARN if rem < 60 else MUTED)
            # Separator `·` перед sleep — отделяем power-блок от sleep visually.
            # `z ` — universal sleep notation (emoji 💤 не в DejaVu).
            pieces.append(F_SMALL.render("·", True, MUTED))
            pieces.append(F_SMALL.render(f"z {rem_str}", True, rem_col))

    GAP = 4
    total_w = sum(p.get_width() for p in pieces) + GAP * (len(pieces) - 1)
    bx = SCREEN_W - total_w - 8
    for p in pieces:
        screen.blit(p, (bx, 4))
        bx += p.get_width() + GAP

    return 26


# =============================================================================
# State machine
# =============================================================================
PAGE_STATUS         = "status"
PAGE_MENU           = "menu"
PAGE_PROGRESS       = "progress"
PAGE_LOGS           = "logs"
PAGE_LOG_VIEW       = "log_view"
PAGE_AP_INFO        = "ap_info"
PAGE_AP_CONFIRM     = "ap_confirm"
PAGE_REBOOT_CONFIRM = "reboot_confirm"
PAGE_OFF_CONFIRM    = "off_confirm"
PAGE_FLIP_CONFIRM   = "flip_confirm"
PAGE_SERVICES       = "services"
PAGE_NAS_STATUS     = "nas_status"
PAGE_DAILY_SUMMARY  = "daily_summary"
PAGE_CONFIGS        = "configs"
PAGE_DOCKER         = "docker"
PAGE_YTARCHIVER     = "ytarchiver"
PAGE_SYSTEM_DETAIL  = "system_detail"
PAGE_STORAGE_DETAIL = "storage_detail"
PAGE_NETWORK_DETAIL = "network_detail"
PAGE_PHOTO_BACKUPS  = "photo_backups"
PAGE_THERMAL        = "thermal"

state = {
    "page":        PAGE_STATUS,
    "prev_page":   PAGE_STATUS,
    "log_idx":     0,
    "log_paused":  False,
    "log_lines":   [],
    "toast":       None,   # (text, ts, color)
}


def go(page):
    if page != state["page"]:
        state["prev_page"] = state["page"]
        state["page"] = page


def toast(text, color=FG):
    state["toast"] = (text, time.time(), color)


# =============================================================================
# Pages
# =============================================================================
def _card(rect, title, title_color=MUTED, bg=PANEL, border=None):
    """Рисует фон карточки (опционально цветную подложку + бордер)
    + маленький заголовок-капс. Возвращает inner rect для контента."""
    pygame.draw.rect(screen, bg, rect, border_radius=8)
    if border is not None:
        pygame.draw.rect(screen, border, rect, 2, border_radius=8)
    screen.blit(F_TINY.render(title, True, title_color), (rect.x + 10, rect.y + 5))
    return pygame.Rect(rect.x + 10, rect.y + 20, rect.w - 20, rect.h - 24)


def _card_network(rect):
    """NETWORK card — большой hostname.local, мелкая строка с IP+SSID+сигналом."""
    inner = _card(rect, "NETWORK")
    ip = c_ip.get()
    wifi = c_wifi.get() or {"ssid": None, "signal": None}
    host = f"{socket.gethostname()}.local"
    if ip:
        # Большое: hostname.local — это то что юзер в браузер тычет
        host_surf = F_LARGE.render(host, True, FG)
        screen.blit(host_surf, (inner.x, inner.y))
        # Малое: IP · SSID · signal — справочная информация
        parts = [ip]
        ssid = wifi.get("ssid")
        sig = wifi.get("signal")
        if ssid: parts.append(ssid)
        if sig is not None: parts.append(f"{sig} dBm")
        s = F_SMALL.render("  ·  ".join(parts), True, MUTED)
        screen.blit(s, (inner.x, inner.y + host_surf.get_height() + 2))
    else:
        screen.blit(F_LARGE.render("offline", True, ERROR), (inner.x, inner.y))


def _card_ap(rect):
    """AP MODE card — крупная инструкция чтоб не забыть как зайти."""
    inner = _card(rect, "AP MODE — setup WiFi here", WARN,
                  bg=PANEL_WARN, border=WARN)
    # comitup создаёт AP с именем comitup-NNN (NNN = последние цифры
    # serial/MAC). Точное имя не знаем — показываем формат.
    # 1) что подключить
    screen.blit(F_SMALL.render("WiFi (no password):", True, MUTED), (inner.x, inner.y))
    screen.blit(F_MED.render("comitup-NNN", True, FG), (inner.x, inner.y + 14))
    # 2) куда зайти — крупно и ярко (порт 8080, чтоб не конфликтить с CasaOS:80)
    screen.blit(F_SMALL.render("then open in browser:", True, MUTED), (inner.x, inner.y + 40))
    screen.blit(F_MED.render("http://10.41.0.1:8080", True, INFO), (inner.x, inner.y + 54))


def _card_storage(rect):
    inner = _card(rect, "STORAGE  T7")
    disk = c_disk.get()
    t7t = c_t7_temp.get()
    if disk is None:
        msg = F_MED.render("NOT MOUNTED", True, ERROR)
        screen.blit(msg, msg.get_rect(center=(inner.centerx, inner.centery)))
        hint = F_TINY.render("plug T7 / check /mnt/t7", True, MUTED)
        screen.blit(hint, hint.get_rect(midtop=(inner.centerx, inner.centery + 12)))
        return
    if disk == "io_error":
        # Mount висит, но диск не отвечает (hot-pull / USB-glitch / sleep)
        msg = F_MED.render("I/O ERROR", True, ERROR)
        screen.blit(msg, msg.get_rect(center=(inner.centerx, inner.centery)))
        hint = F_TINY.render("tap for details · replug / fsck", True, MUTED)
        screen.blit(hint, hint.get_rect(midtop=(inner.centerx, inner.centery + 12)))
        return
    col = ACCENT if disk["pct"] < 80 else (WARN if disk["pct"] < 90 else ERROR)

    # Главная строка: used/total слева, t°C + free справа
    main = F_MED.render(f"{disk['used']} / {disk['total']}", True, FG)
    screen.blit(main, (inner.x, inner.y))
    right_parts = []
    if t7t: right_parts.append(f"{t7t}°C")
    right_parts.append(f"{disk['avail']} free")
    rt = F_SMALL.render(" · ".join(right_parts), True, MUTED)
    screen.blit(rt, (inner.right - rt.get_width(), inner.y + 4))

    # Bar внизу + % справа в КОНЦЕ строки (а не на самом баре — не сливается)
    pct_s = F_SMALL.render(f"{disk['pct']}%", True, col)
    pct_w = pct_s.get_width() + 6
    bar_y = inner.bottom - 14
    bar_w = inner.w - pct_w
    draw_bar(inner.x, bar_y, bar_w, 12, disk["pct"], col)
    screen.blit(pct_s, (inner.right - pct_s.get_width(),
                       bar_y + (12 - pct_s.get_height()) // 2))


def _card_system(rect):
    """CPU + RAM с барами + строка статуса (load, swap, zram, throttle)."""
    inner = _card(rect, "SYSTEM")
    y = inner.y

    # CPU temp + load %
    cpu_t = c_cpu_temp.get()
    cpu_p = c_cpu_pct.get()
    cpu_c = ACCENT if (cpu_t or 0) < 65 else (WARN if (cpu_t or 0) < 75 else ERROR)
    label = F_NORMAL.render(f"CPU  {cpu_t or '?'}°C", True, cpu_c)
    screen.blit(label, (inner.x, y))
    if cpu_p is not None:
        v = F_SMALL.render(f"{cpu_p}% load", True, MUTED)
        screen.blit(v, (inner.right - v.get_width(), y + 3))
    y += 19
    if cpu_p is not None:
        bar_c = ACCENT if cpu_p < 70 else (WARN if cpu_p < 90 else ERROR)
        draw_bar(inner.x, y, inner.w, 8, cpu_p, bar_c)
    y += 14

    # RAM bytes + pct
    ram = c_ram.get()
    if ram:
        col = ACCENT if ram["pct"] < 70 else (WARN if ram["pct"] < 90 else ERROR)
        screen.blit(F_NORMAL.render(
            f"RAM  {human_bytes(ram['used'])} / {human_bytes(ram['total'])}", True, FG), (inner.x, y))
        v = F_SMALL.render(f"{ram['pct']}%", True, MUTED)
        screen.blit(v, (inner.right - v.get_width(), y + 3))
        y += 19
        draw_bar(inner.x, y, inner.w, 8, ram["pct"], col)
        y += 14

    # Footer статуса
    bits = []
    load = c_load.get()
    sw = c_swap.get()
    zr = c_zram.get()
    if load is not None: bits.append(f"load {load:.2f}")
    if sw and sw['pct'] > 0: bits.append(f"swap {sw['pct']}%")
    if zr: bits.append(f"zram {zr:.1f}×")
    if bits:
        screen.blit(F_SMALL.render("  ·  ".join(bits), True, MUTED), (inner.x, y))
    # Throttle справа с цветом
    th = c_throttle.get()
    if th:
        tcol = th[1]
        ts = F_SMALL.render(f"throttle {th[0]}", True, tcol)
        screen.blit(ts, (inner.right - ts.get_width(), y))


def _card_backup_progress(rect, p):
    """Активный бэкап — карточка с зелёной подложкой чтоб глаз цеплялся."""
    src = (p.get("source") or "backup").upper()
    inner = _card(rect, f"{src} BACKUP IN PROGRESS", ACCENT,
                  bg=PANEL_ACCENT, border=ACCENT)
    pct = int(p.get("percent", 0))
    lbl = p.get("label") or p.get("device") or ""
    if len(lbl) > 26: lbl = lbl[:24] + "…"
    screen.blit(F_NORMAL.render(lbl, True, FG), (inner.x, inner.y))
    pct_t = F_MED.render(f"{pct}%", True, ACCENT)
    screen.blit(pct_t, (inner.right - pct_t.get_width(), inner.y - 2))

    bar_y = inner.y + 22
    draw_bar(inner.x, bar_y, inner.w, 12, pct, ACCENT)

    speed = p.get("speed") or "?"
    eta = p.get("eta") or "?"
    size_done = p.get("size_done") or "?"
    foot = f"{size_done}  ·  {speed}  ·  ETA {eta}"
    screen.blit(F_SMALL.render(foot, True, MUTED), (inner.x, inner.bottom - 16))


def _card_last_backup(rect):
    inner = _card(rect, "LAST PHOTO BACKUP")
    last = c_last.get()
    if not last:
        screen.blit(F_NORMAL.render("none yet", True, MUTED), (inner.x, inner.y))
        return
    date_s = F_NORMAL.render(last['date'], True, FG)
    screen.blit(date_s, (inner.x, inner.y))
    fc = F_SMALL.render(f"{last['files']} files", True, FG)
    screen.blit(fc, (inner.right - fc.get_width(), inner.y + 4))
    nm = last['name']
    if len(nm) > 32: nm = nm[:30] + "…"
    screen.blit(F_SMALL.render(nm, True, MUTED), (inner.x, inner.y + 22))


def _nas_aggregate():
    """Aggregate NAS backup state — без привязки к конкретной папке.
    Возвращает: total_local_bytes, total_nas_bytes, last_run (max), worst_status."""
    data = _load_json(NAS_STATUS_JSON)
    if not data:
        return None
    mods = data.get("modules") or []
    total_local = 0.0
    total_nas   = 0.0
    last_run    = 0
    statuses    = set()
    for m in mods:
        if m.get("exists"):
            sz = _parse_size(m.get("size"))
            if sz: total_local += sz
            st = m.get("status")
            if st: statuses.add(st)
            lr = m.get("last_run") or 0
            if lr > last_run: last_run = lr
        ns = _parse_size(m.get("nas_size"))
        if ns: total_nas += ns
    # Worst-of: fail > partial/warn > ok
    if "fail" in statuses:    worst = "fail"
    elif "partial" in statuses: worst = "partial"
    elif "warn" in statuses:    worst = "warn"
    elif "ok" in statuses:      worst = "ok"
    else:                       worst = None
    return {
        "local_bytes": total_local,
        "nas_bytes":   total_nas,
        "last_run":    last_run or None,
        "status":      worst,
    }


c_last_nas = Cached(_nas_aggregate, 30)


def _card_last_nas_backup(rect):
    inner = _card(rect, "LAST NAS BACKUP")
    agg = c_last_nas.get()
    if not agg or (agg["local_bytes"] == 0 and agg["nas_bytes"] == 0):
        screen.blit(F_NORMAL.render("none yet", True, MUTED), (inner.x, inner.y))
        return
    local_h = human_bytes(int(agg["local_bytes"])) if agg["local_bytes"] else "0B"
    nas_h   = human_bytes(int(agg["nas_bytes"]))   if agg["nas_bytes"]   else "?"
    pct     = (agg["local_bytes"] / agg["nas_bytes"] * 100) if agg["nas_bytes"] else None
    status  = agg["status"]
    last_r  = agg["last_run"]

    # `incomplete` теперь чисто информационное (pct < 80 = большая разница;
    # обычно EXCLUDES = Synology @eaDir + #recycle, ~5-15% мусора). НЕ влияет
    # на статус-точку, т.к. rsync exit-code в `status` — авторитетный источник:
    # если status='ok' значит rsync доехал. Раньше pct < 95 давал ложный
    # warn при норм бэкапе из-за thumbnails.
    size_gap = pct is not None and pct < 80
    if status == "fail":                dot = ERROR
    elif status in ("partial", "warn"): dot = WARN
    elif status == "ok":                dot = ACCENT
    else:                               dot = MUTED

    # Строка 1: точка + size totals слева, % справа (всегда FG, не WARN)
    pygame.draw.circle(screen, dot, (inner.x + 5, inner.y + 9), 5)
    sz_text = f"{local_h} / {nas_h}"
    screen.blit(F_NORMAL.render(sz_text, True, FG), (inner.x + 16, inner.y))
    if pct is not None:
        pct_s = F_NORMAL.render(f"{pct:.0f}%", True, FG)
        screen.blit(pct_s, (inner.right - pct_s.get_width(), inner.y))

    # Строка 2: time ago · status. Размер-gap показываем только если ОЧЕНЬ
    # большой (> 20%) И статус не ok — иначе тихо.
    parts = []
    if last_r: parts.append(_ago(last_r))
    if status: parts.append(status)
    if size_gap and status != "ok": parts.append("size mismatch")
    sub_col = WARN if status in ("partial", "warn", "fail") else MUTED
    screen.blit(F_SMALL.render("  ·  ".join(parts), True, sub_col),
                (inner.x + 16, inner.y + 20))


def page_status():
    screen.fill(BG)
    y = draw_top_strip()
    y += 4
    btns = []
    margin = 6
    card_w = SCREEN_W - margin * 2
    gap = 5

    # Доступная высота под карточки: всё от y до ботом-баттонс
    bottom_btn_y = SCREEN_H - 54
    available = bottom_btn_y - 6 - y

    # Состав карточек зависит от того есть ли активный бэкап и AP-режим
    p = get_progress()
    in_ap = is_ap_mode()

    if p:
        # Активный бэкап — главное, last-backup не показываем (он же сейчас идёт)
        cards = [
            (_card_ap if in_ap else _card_network,  96 if in_ap else 66),
            (lambda r: _card_backup_progress(r, p), 84),
            (_card_storage,                         68),
            (_card_system,                        104),
        ]
    else:
        # Юзер: 'если чуть убрать паддинга у System снизу — поместится и last
        # NAS backup'. System ужат 124→104, добавлен _card_last_nas_backup.
        cards = [
            (_card_ap if in_ap else _card_network,  96 if in_ap else 68),
            (_card_storage,                         74),
            (_card_system,                        104),
            (_card_last_nas_backup,                 62),
            (_card_last_backup,                     62),
        ]

    # Распределяем gap'ы — оставляем мелкие зазоры, без растягивания
    for draw_fn, h in cards:
        rect = pygame.Rect(margin, y, card_w, h)
        draw_fn(rect)
        # Tappable карточки: progress (lambda) → details, system → top procs
        if draw_fn.__name__ == "<lambda>":
            btns.append(Btn("", "progress_open", rect, ACCENT))
        elif draw_fn is _card_system:
            btns.append(Btn("", "open_system_detail", rect, ACCENT))
        elif draw_fn is _card_storage:
            btns.append(Btn("", "open_storage_detail", rect, ACCENT))
        elif draw_fn is _card_network:
            btns.append(Btn("", "open_network_detail", rect, ACCENT))
        elif draw_fn is _card_ap:
            btns.append(Btn("", "open_ap_info", rect, ACCENT))
        elif draw_fn is _card_last_nas_backup:
            btns.append(Btn("", "open_nas_status", rect, ACCENT))
        elif draw_fn is _card_last_backup:
            btns.append(Btn("", "open_photo_backups", rect, ACCENT))
        y += h + gap

    # Footer: SMB-клиенты — uptime теперь в top-strip, тут только активные сессии
    smb = c_smb.get() or 0
    if smb > 0:
        screen.blit(F_TINY.render(f"{smb} smb", True, MUTED),
                    (margin + 4, bottom_btn_y - 14))

    # Bottom button: Menu во всю ширину (AP info переехал в Menu)
    menu = Btn("Menu", "open_menu",
               pygame.Rect(8, bottom_btn_y, SCREEN_W - 16, 46),
               ACCENT, primary=True)
    draw_button(menu)
    btns += [menu]
    return btns


def _menu_helpers(btns, btn_h=36, gap_row=2, sect_h=12):
    """Layout-helpers для меню. Дефолты подкручены под flat-меню (всё на
    один экран в 320px). Можно переопределить если страница имеет меньше
    кнопок и хочется крупнее."""
    margin   = 8
    full_w   = SCREEN_W - margin * 2
    half_w   = (SCREEN_W - margin * 2 - 10) // 2

    state_y = [0]
    def set_y(v): state_y[0] = v
    def get_y():  return state_y[0]

    def section(title, color):
        # Только текст + подчёркивание линией. Без отступа сверху/снизу
        # чтобы по высоте было максимально компактно.
        screen.blit(F_TINY.render(title, True, color), (margin, get_y()))
        pygame.draw.line(screen, color,
                         (margin, get_y() + 10),
                         (SCREEN_W - margin, get_y() + 10), 1)
        set_y(get_y() + sect_h)

    def row_full(label, action, color, primary=False):
        r = pygame.Rect(margin, get_y(), full_w, btn_h)
        b = Btn(label, action, r, color, primary=primary)
        btns.append(b); draw_button(b)
        set_y(get_y() + btn_h + gap_row)

    def row_pair(l1, a1, c1, l2, a2, c2, primary1=False, primary2=False):
        r1 = pygame.Rect(margin, get_y(), half_w, btn_h)
        r2 = pygame.Rect(SCREEN_W - margin - half_w, get_y(), half_w, btn_h)
        b1 = Btn(l1, a1, r1, c1, primary=primary1)
        b2 = Btn(l2, a2, r2, c2, primary=primary2)
        btns.extend([b1, b2])
        draw_button(b1); draw_button(b2)
        set_y(get_y() + btn_h + gap_row)

    def row_triple(items):
        third_w = (SCREEN_W - margin * 2 - 12) // 3
        for i, (lbl, act, col, prim) in enumerate(items):
            x = margin + i * (third_w + 6)
            r = pygame.Rect(x, get_y(), third_w, btn_h)
            b = Btn(lbl, act, r, col, primary=prim)
            btns.append(b); draw_button(b)
        set_y(get_y() + btn_h + gap_row)

    def bottom_pair(l1, a1, l2, a2):
        bh = 48
        bot_y = SCREEN_H - bh - 8
        b1 = Btn(l1, a1, pygame.Rect(margin, bot_y, half_w, bh), MUTED)
        b2 = Btn(l2, a2,
                 pygame.Rect(SCREEN_W - margin - half_w, bot_y, half_w, bh),
                 MUTED)
        draw_button(b1); draw_button(b2)
        btns.extend([b1, b2])

    return set_y, get_y, section, row_full, row_pair, row_triple, bottom_pair


def page_menu():
    """Flat-меню: всё на одном экране. Юзер: 'переделаем страницу меню.
    row NAS: Run/Stop Backup, NAS status. Ниже INFO: Today, Logs, Services,
    Configs, Docker. SYSTEM (остаётся как было) + кнопки power.'"""
    screen.fill(BG)
    y0 = draw_top_strip("Menu") + 6
    btns = []
    # btn_h=48: чуть крупнее под резистивный touch (MHS35 шумит у краёв)
    (set_y, _g, section, row_full, row_pair, row_triple, bottom_pair
     ) = _menu_helpers(btns, btn_h=48, gap_row=6, sect_h=16)
    set_y(y0)

    # NAS — Run/Stop пара с NAS status. Run превращается в Stop когда
    # бэкап активен (systemctl is-active nas-backup-runtime).
    section("NAS", ACCENT)
    if c_nas_run.get():
        row_pair("Stop backup", "nas_stop",         ERROR,
                 "NAS status",  "open_nas_status",  INFO,
                 primary1=True)
    else:
        row_pair("Run backup",  "nas_run",          ACCENT,
                 "NAS status",  "open_nas_status",  INFO,
                 primary1=True)

    # INFO — что почитать. 6 элементов в 2 ряда по 3.
    section("INFO", INFO)
    row_triple([
        ("Today",    "open_daily",    INFO, False),
        ("Logs",     "open_logs",     INFO, False),
        ("Services", "open_services", INFO, False),
    ])
    row_triple([
        ("Configs",  "open_configs",  INFO, False),
        ("Docker",   "open_docker",   INFO, False),
        ("YT",       "open_yt",       INFO, False),
    ])
    row_full("Thermal guard", "open_thermal", INFO)

    # SYSTEM — wifi/власть + Power-режимы (юзер просил включить сюда)
    section("SYSTEM", WARN)
    row_pair("AP info",  "open_ap_info",    INFO,
             "Force AP", "open_ap_confirm", WARN)
    row_pair("Reboot",   "open_reboot",     WARN,
             "Shutdown", "open_off",        ERROR)
    pref = c_ppref.get()
    row_triple([
        ("Normal", "pwr_normal", ACCENT, pref == "normal"),
        ("Saver",  "pwr_saver",  WARN,   pref == "saver"),
        ("Auto",   "pwr_auto",   INFO,   pref == "auto"),
    ])

    bottom_pair("Back", "back_to_status",
                "Exit to desktop", "exit_to_desktop")
    return btns


def page_progress():
    screen.fill(BG)
    p = get_progress()
    if not p:
        go(PAGE_STATUS)
        return []
    btns = []
    y = draw_top_strip("Backup")
    y += 8

    src = p.get("source", "backup")
    screen.blit(F_LARGE.render(f"{src} backup", True, ACCENT), (8, y))
    y += 32
    lbl = p.get("label") or p.get("device") or ""
    if len(lbl) > 26: lbl = lbl[:24] + "…"
    screen.blit(F_MED.render(lbl, True, FG), (8, y))
    y += 28

    pct = int(p.get("percent", 0))
    bar_h = 32
    pygame.draw.rect(screen, BAR_BG, (8, y, SCREEN_W - 16, bar_h), border_radius=6)
    fw = int((SCREEN_W - 16) * pct / 100)
    pygame.draw.rect(screen, ACCENT, (8, y, fw, bar_h), border_radius=6)
    pct_t = F_MED.render(f"{pct}%", True, FG)
    screen.blit(pct_t, pct_t.get_rect(center=(SCREEN_W // 2, y + bar_h // 2)))
    y += bar_h + 18

    # Format files / size — если total известен показываем "done / total",
    # иначе просто "done" (для NAS backup total пишется как 0 или "" пока
    # rsync строит file list через --no-inc-recursive).
    files_done = p.get("files_done", 0) or 0
    files_total = p.get("files_total", 0) or 0
    files_str = f"{files_done} / {files_total}" if files_total else str(files_done)
    size_done = p.get("size_done") or "?"
    size_total = p.get("size_total") or ""
    size_str = f"{size_done} / {size_total}" if size_total else size_done

    rows = [
        ("Files", files_str),
        ("Size",  size_str),
        ("Speed", p.get("speed", "?")),
        ("ETA",   p.get("eta", "?")),
    ]
    for label_, value in rows:
        screen.blit(F_NORMAL.render(label_, True, MUTED), (8, y))
        screen.blit(F_NORMAL.render(str(value), True, FG), (90, y))
        y += 22

    tgt = p.get("target", "")
    if tgt:
        if len(tgt) > 40: tgt = "…" + tgt[-38:]
        screen.blit(F_TINY.render(tgt, True, MUTED), (8, y + 4))

    back = Btn("Hide", "back_to_status", pygame.Rect(8, SCREEN_H - 54, SCREEN_W - 16, 46), MUTED)
    draw_button(back); btns.append(back)
    return btns


def page_logs():
    screen.fill(BG)
    y = draw_top_strip("Logs")
    y += 10
    btns = []
    for i, (name, _) in enumerate(LOG_OPTIONS):
        r = pygame.Rect(8, y, SCREEN_W - 16, 40)
        b = Btn(name, f"log_{i}", r, INFO)
        draw_button(b); btns.append(b)
        y += 46
    back = Btn("Back", "open_menu", pygame.Rect(8, SCREEN_H - 54, SCREEN_W - 16, 46), MUTED)
    draw_button(back); btns.append(back)
    return btns


def page_log_view():
    screen.fill(BG)
    y = draw_top_strip("Logs")
    y += 4
    idx = state.get("log_idx", 0)
    name, path = LOG_OPTIONS[idx]
    if path == "__nas_latest__":
        log_dir = Path("/mnt/t7/nas-backup/_logs")
        path = None
        if log_dir.exists():
            files = sorted(log_dir.glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
            path = str(files[0]) if files else None

    suffix = " (paused)" if state.get("log_paused") else ""
    screen.blit(F_SMALL.render(f"{name}{suffix}", True, INFO), (8, y))
    y += 18

    if not state.get("log_paused"):
        try:
            if path and Path(path).exists():
                with open(path, "rb") as f:
                    f.seek(0, 2)
                    size = f.tell()
                    chunk = min(size, 32 * 1024)
                    f.seek(size - chunk)
                    data = f.read().decode("utf-8", errors="replace")
                state["log_lines"] = data.splitlines()[-200:]
            else:
                state["log_lines"] = ["(log file not found)"]
        except Exception as e:
            state["log_lines"] = [f"(error: {e})"]

    lines = state["log_lines"]
    bottom = SCREEN_H - 54 - 6
    line_h = 12
    max_lines = max(1, (bottom - y) // line_h)
    visible = lines[-max_lines:]
    for ln in visible:
        if len(ln) > 52: ln = ln[:50] + "…"
        screen.blit(F_MONO.render(ln, True, FG), (4, y))
        y += line_h

    # Back всегда слева, Pause/Resume справа.
    half_w = (SCREEN_W - 24) // 2
    back = Btn("Back", "open_logs",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    pause = Btn(
        "Resume" if state.get("log_paused") else "Pause",
        "toggle_log_pause",
        pygame.Rect(8 + half_w + 8, SCREEN_H - 54, half_w, 46), INFO,
    )
    draw_button(back); draw_button(pause)
    return [back, pause]


def _ago(ts):
    """Human-friendly 'X ago' для unix timestamp. None → '—'."""
    if not ts:
        return "—"
    delta = int(time.time() - ts)
    if delta < 60:    return f"{delta}s ago"
    if delta < 3600:  return f"{delta // 60}m ago"
    if delta < 86400: return f"{delta // 3600}h ago"
    return f"{delta // 86400}d ago"


def _load_json(path):
    if not path.exists():
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def page_nas_status():
    screen.fill(BG)
    y = draw_top_strip("NAS backup")
    y += 8
    btns = []

    data = _load_json(NAS_STATUS_JSON)
    if not data:
        screen.blit(F_NORMAL.render("No status data yet.", True, MUTED), (10, y))
        y += 22
        screen.blit(F_SMALL.render("Tap Refresh to scan now.", True, MUTED), (10, y))
    else:
        # Header — total used + updated time
        di = data.get("disk") or {}
        if di:
            head = f"{di.get('used','?')} / {di.get('total','?')}  ({di.get('pct','?')}%)"
            screen.blit(F_MED.render(head, True, FG), (10, y))
            avail_s = F_SMALL.render(f"{di.get('avail','?')} free", True, MUTED)
            screen.blit(avail_s, (SCREEN_W - avail_s.get_width() - 10, y + 5))
        y += 26
        upd = data.get("updated")
        if upd:
            screen.blit(F_TINY.render(f"updated {_ago(upd)}", True, MUTED), (10, y))
        y += 14
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 8

        modules = data.get("modules") or []
        bottom = SCREEN_H - 60
        avail_h = bottom - y - 8
        row_h = max(38, min(54, avail_h // max(1, len(modules))))

        for m in modules:
            name = m.get("name", "?")
            ex = m.get("exists", False)
            status = m.get("status")
            size = m.get("size") or "?"
            nas_size = m.get("nas_size")
            last_run = m.get("last_run")

            if not ex:
                dot_color = MUTED
                status_label = "absent"
            elif status == "ok":
                dot_color = ACCENT
                status_label = "ok"
            elif status == "warn":
                dot_color = WARN
                status_label = "warn"
            elif status == "fail":
                dot_color = ERROR
                status_label = "fail"
            elif status == "partial":
                # Backup был прерван — не докопирован. Жёлтый чтоб бросалось.
                dot_color = WARN
                status_label = "partial"
            else:
                dot_color = MUTED
                status_label = "never"

            # Точка статуса + имя модуля
            pygame.draw.circle(screen, dot_color, (16, y + 9), 5)
            screen.blit(F_NORMAL.render(name, True, FG), (28, y))

            # Справа: "local / source". Если status='ok' — серым (rsync
            # отчитался ОК, размер-gap = только EXCLUDES). Если status≠ok
            # И есть существенный gap — жёлтым.
            size_gap = ex and nas_size and _size_lt(size, nas_size, tolerance=0.80)
            if nas_size:
                local_s = F_NORMAL.render(size, True, FG if ex else MUTED)
                sep_col = WARN if (size_gap and status != "ok") else MUTED
                sep_s   = F_NORMAL.render(" / ", True, sep_col)
                src_s   = F_NORMAL.render(nas_size, True, sep_col)
                total_w = local_s.get_width() + sep_s.get_width() + src_s.get_width()
                x = SCREEN_W - total_w - 10
                screen.blit(local_s, (x, y)); x += local_s.get_width()
                screen.blit(sep_s,   (x, y)); x += sep_s.get_width()
                screen.blit(src_s,   (x, y))
            else:
                ss = F_NORMAL.render(size, True, FG if ex else MUTED)
                screen.blit(ss, (SCREEN_W - ss.get_width() - 10, y))

            # Подстрока: last_run + status. "size mismatch" только если status
            # говорит проблема. При status='ok' молчим — rsync сказал OK.
            sub_parts = [_ago(last_run), status_label]
            if size_gap and status != "ok":
                sub_parts.append("size mismatch")
            sub = "  ·  ".join(sub_parts)
            sub_col = WARN if "size mismatch" in sub or status in ("partial", "warn", "fail") else MUTED
            screen.blit(F_SMALL.render(sub, True, sub_col), (28, y + 20))
            y += row_h

    # Buttons: Back | Refresh — Back всегда слева (как в браузере)
    half_w = (SCREEN_W - 28) // 2
    back    = Btn("Back",    "open_menu",
                  pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "nas_status_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    return [back, refresh]


def page_daily_summary():
    screen.fill(BG)
    y = draw_top_strip("Today")
    y += 8
    btns = []

    data = _load_json(DAILY_SUMMARY_JSON)
    if not data:
        screen.blit(F_NORMAL.render("No summary data yet.", True, MUTED), (10, y))
        y += 22
        screen.blit(F_SMALL.render("Tap Refresh to gather.", True, MUTED), (10, y))
    else:
        # Дата + updated
        date_s = data.get("date") or "today"
        screen.blit(F_MED.render(date_s, True, FG), (10, y))
        upd_s = F_TINY.render(f"updated {_ago(data.get('updated'))}", True, MUTED)
        screen.blit(upd_s, (SCREEN_W - upd_s.get_width() - 10, y + 8))
        y += 24
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 8

        # Двухколоночная вёрстка метрик
        def kv(key, val, color=FG, big=False):
            nonlocal y
            screen.blit(F_SMALL.render(key, True, MUTED), (10, y))
            font = F_NORMAL if big else F_NORMAL
            v_surf = font.render(str(val), True, color)
            screen.blit(v_surf, (SCREEN_W - v_surf.get_width() - 10, y))
            y += 20

        # Throttle / undervoltage — заметно если есть
        th = data.get("throttle") or {}
        if th.get("now"):
            screen.blit(F_NORMAL.render("⚡ Under-voltage NOW", True, ERROR), (10, y))
            y += 22
        elif th.get("past"):
            screen.blit(F_SMALL.render("⚡ power dipped today", True, WARN), (10, y))
            y += 18

        kv("Uptime",   data.get("uptime") or "?")
        ct = data.get("cpu_temp")
        kv("CPU temp", f"{ct}°C" if ct else "?",
           ACCENT if (ct or 0) < 65 else (WARN if (ct or 0) < 75 else ERROR))
        t7 = data.get("t7") or {}
        ip = data.get("ip")
        ssid = data.get("ssid")
        kv("Network",  f"{ip or '?'}" + (f" ({ssid})" if ssid else ""))
        if t7.get("mounted"):
            kv("T7 disk", f"{t7.get('used','?')} / {t7.get('total','?')} ({t7.get('pct','?')}%)")
        else:
            kv("T7 disk", "NOT MOUNTED", ERROR)

        y += 4
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 8

        ph = data.get("photo_today") or {}
        if ph.get("cards", 0) > 0:
            kv("Photo cards", ph.get("cards"), ACCENT)
            kv("Photo files", ph.get("files"))
            kv("Photo size",  ph.get("size"))
        else:
            kv("Photo today", "none")

        kv("NAS backup", "done" if data.get("nas_today") else "—",
           ACCENT if data.get("nas_today") else MUTED)

        errs = data.get("errors_today") or 0
        kv("Errors",   errs, ACCENT if errs == 0 else ERROR)

        inc = data.get("incomplete") or 0
        if inc > 0:
            kv("Incomplete", inc, WARN)

        sd = data.get("sd_wear_pct")
        if sd is not None:
            sd_col = ACCENT if sd < 50 else (WARN if sd < 70 else ERROR)
            kv("microSD wear", f"~{sd}%", sd_col)

        if POWER_MODE_FILE.exists():
            try:
                pm = POWER_MODE_FILE.read_text().strip()
            except Exception:
                pm = "?"
            pm_col = (ACCENT if pm == "home" else
                      WARN   if pm == "emergency" else
                      INFO)
            kv("Power mode", pm, pm_col)

    half_w = (SCREEN_W - 28) // 2
    back    = Btn("Back",    "open_menu",
                  pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "daily_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    return [back, refresh]


c_services = Cached(load_services, 5)


def page_services():
    screen.fill(BG)
    y = draw_top_strip("Services")
    y += 8

    items = c_services.get() or []
    ip = c_ip.get()

    # Header — host + IP
    host = f"{socket.gethostname()}.local"
    screen.blit(F_MED.render(host, True, FG), (10, y))
    if ip:
        ip_s = F_SMALL.render(ip, True, MUTED)
        screen.blit(ip_s, (SCREEN_W - ip_s.get_width() - 10, y + 5))
    y += 28
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 8

    # Heights: 18 заголовок + 16 url + 14 за каждую note. Дальше gap.
    bottom_btn_y = SCREEN_H - 60
    LINE_H_NAME = 18
    LINE_H_URL  = 16
    LINE_H_NOTE = 14
    GAP_BETWEEN_ENTRIES = 8

    for name, url, notes, inline in items:
        if inline:
            # NAME: URL на одной строке — имя синим, ": URL" белым следом
            name_surf = F_NORMAL.render(name + ":", True, INFO)
            screen.blit(name_surf, (10, y))
            u = url
            max_url_px = SCREEN_W - 10 - name_surf.get_width() - 16
            # Урезать URL под доступную ширину
            while u and F_SMALL.size(u)[0] > max_url_px and len(u) > 4:
                u = u[:-2] + "…" if not u.endswith("…") else u[:-2] + "…"
            screen.blit(F_SMALL.render(u, True, FG),
                        (10 + name_surf.get_width() + 6, y + 3))
            y += LINE_H_NAME
        else:
            # Двухрядный: имя синим сверху, URL белым под именем
            screen.blit(F_NORMAL.render(name, True, INFO), (10, y))
            y += LINE_H_NAME
            u = url
            if len(u) > 38: u = u[:36] + "…"
            screen.blit(F_SMALL.render(u, True, FG), (18, y))
            y += LINE_H_URL
        # Заметки (мелким серым) — общий путь для inline и двухрядного
        for note in notes:
            note_s = note if len(note) <= 42 else note[:40] + "…"
            screen.blit(F_TINY.render(note_s, True, MUTED), (18, y))
            y += LINE_H_NOTE
            if y + LINE_H_NOTE >= bottom_btn_y:
                break
        y += GAP_BETWEEN_ENTRIES
        if y >= bottom_btn_y:
            break

    # Bottom: Back | Refresh — Back всегда слева
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "open_menu",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("⟳ Refresh", "services_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    return [back, refresh]


def _docker_projects():
    """Список docker-compose проектов через wrapper. None если docker недоступен."""
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/local/bin/docker-mgr.sh", "list"],
            timeout=8, stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
        return json.loads(out)
    except Exception:
        return None


c_docker = Cached(_docker_projects, 8)


def page_docker():
    screen.fill(BG)
    y = draw_top_strip("Docker")
    y += 6
    btns = []

    projects = c_docker.get()
    if projects is None:
        screen.blit(F_NORMAL.render("docker не доступен", True, ERROR), (10, y))
        y += 24
        screen.blit(F_SMALL.render("(нет sudoers или CASAOS не установлен)", True, MUTED), (10, y))
    elif not projects:
        screen.blit(F_NORMAL.render("Нет compose-проектов", True, MUTED), (10, y))
    else:
        # Заголовок таблицы
        screen.blit(F_TINY.render("PROJECT", True, MUTED), (10, y))
        screen.blit(F_TINY.render("STATUS", True, MUTED), (150, y))
        y += 14
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 6

        # Если слишком много — ограничим. У нас редко >5, но защита.
        for p in projects[:8]:
            name = p.get("Name", "?")
            status = p.get("Status", "?")
            running = "running" in status.lower()
            dot = ACCENT if running else MUTED
            pygame.draw.circle(screen, dot, (16, y + 9), 5 if running else 4)
            # Имя — обрезаем если длинно
            name_disp = name if len(name) <= 14 else name[:13] + "…"
            screen.blit(F_NORMAL.render(name_disp, True, FG), (28, y))
            # Статус — короткий
            status_short = status if len(status) <= 18 else status[:16] + "…"
            screen.blit(F_SMALL.render(status_short, True, MUTED), (150, y + 2))
            # Кнопка: Stop если бежит, Start если стоит
            btn_label = "Stop" if running else "Start"
            btn_color = WARN if running else ACCENT
            btn_rect = pygame.Rect(SCREEN_W - 70, y - 2, 60, 26)
            pygame.draw.rect(screen, BTN_BG, btn_rect, border_radius=4)
            pygame.draw.rect(screen, btn_color, btn_rect, 1, border_radius=4)
            t_surf = F_SMALL.render(btn_label, True, FG)
            screen.blit(t_surf, t_surf.get_rect(center=btn_rect.center))
            action = "docker_stop" if running else "docker_start"
            btns.append(Btn(btn_label, f"{action}:{name}", btn_rect, btn_color))
            y += 32

    # Bottom: Back | Refresh — Back всегда слева
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "open_menu",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "docker_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    btns.extend([back, refresh])
    return btns


def page_ytarchiver():
    """YT Archive статистика — channels/videos/storage + очередь скачивания.
    Источник: GET {URL}/api/stats и /api/queue. URL из yt-archiver.conf."""
    screen.fill(BG)
    y = draw_top_strip("YT Archive")
    y += 8
    btns = []

    data = c_yt.get()
    if not data:
        screen.blit(F_NORMAL.render("yt-archiver не доступен", True, ERROR), (10, y))
        y += 24
        screen.blit(F_SMALL.render(_yt_archiver_url(), True, MUTED), (10, y))
        y += 18
        screen.blit(F_SMALL.render("проверь /etc/travel-nas/yt-archiver.conf", True, MUTED), (10, y))
    else:
        # === Шапка: каналы · видео · диск ===
        ch = data.get("channels", 0)
        vi = data.get("videos", 0)
        sz = human_bytes(data.get("bytes", 0))
        screen.blit(F_LARGE.render(f"{vi} videos", True, FG), (10, y))
        screen.blit(F_NORMAL.render(sz, True, ACCENT),
                    (SCREEN_W - 10 - F_NORMAL.size(sz)[0], y + 6))
        y += 32
        screen.blit(F_SMALL.render(f"{ch} channels", True, MUTED), (10, y))
        y += 18
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 8

        # === Очередь: pending / downloading / errors ===
        q = data.get("queue") or {}
        paused = bool(data.get("paused"))
        # При paused — жёлтый заголовок "QUEUE · PAUSED" чтобы сразу было видно
        if paused:
            q_label = "QUEUE  ·  PAUSED"
            screen.blit(F_TINY.render(q_label, True, WARN), (10, y))
        else:
            screen.blit(F_TINY.render("QUEUE", True, MUTED), (10, y))
        y += 14

        dl_count   = q.get("downloading", 0)
        pend_count = q.get("pending", 0)
        err_count  = q.get("error", 0)

        # 3 row indicators со своим цветом
        rows = [
            ("downloading", dl_count,   ACCENT if dl_count else MUTED),
            ("pending",     pend_count, INFO   if pend_count else MUTED),
            ("errors",      err_count,  ERROR  if err_count else MUTED),
        ]
        for label, n, col in rows:
            pygame.draw.circle(screen, col, (16, y + 9), 5)
            screen.blit(F_NORMAL.render(label, True, FG), (28, y))
            n_surf = F_NORMAL.render(str(n), True, col)
            screen.blit(n_surf, (SCREEN_W - 10 - n_surf.get_width(), y))
            y += 22

        # === Текущие downloads с progress-баром ===
        dls = data.get("downloading") or []
        if dls:
            y += 6
            screen.blit(F_TINY.render("NOW DOWNLOADING", True, MUTED), (10, y))
            y += 14
            for d in dls[:3]:
                ch_name = d.get("channel", "")[:18]
                title   = (d.get("title") or "")[:28]
                # progress приходит как string "38.6", не число. float() сначала.
                try:
                    pct = int(float(d.get("progress") or 0))
                except (TypeError, ValueError):
                    pct = 0
                screen.blit(F_SMALL.render(f"{ch_name} — {pct}%", True, FG), (10, y))
                y += 16
                # bar
                draw_bar(10, y, SCREEN_W - 20, 6, pct, ACCENT)
                y += 10
                screen.blit(F_TINY.render(title, True, MUTED), (10, y))
                y += 14

    # Pause/Resume — толстая кнопка над bottom row. Лейбл и цвет зависят
    # от текущего paused-state из /api/queue/status. Если yt недоступен —
    # кнопку не рисуем (data is None ушла в ветку "не доступен" выше).
    if data is not None:
        is_paused = bool(data.get("paused"))
        if is_paused:
            pr_label, pr_action, pr_color = "▶ Resume downloads", "yt_resume", ACCENT
        else:
            pr_label, pr_action, pr_color = "⏸ Pause downloads",  "yt_pause",  WARN
        pr_y = SCREEN_H - 54 - 38
        pr_btn = Btn(pr_label, pr_action,
                     pygame.Rect(8, pr_y, SCREEN_W - 16, 32), pr_color)
        draw_button(pr_btn, F_SMALL)
        btns.append(pr_btn)

    # Bottom: Back | Refresh — Back всегда слева
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "open_menu",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "yt_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    btns.extend([back, refresh])
    return btns


def _disk_diag():
    """Диагностика T7: mount/fs/temp/SMART/dmesg-errors. Не fail-fast — каждая
    подсекция отдельно try/except. Тяжёлый (~1-2 сек) — вызываем только когда
    юзер открыл storage detail page."""
    info = {
        "mount_ok": False, "io_error": False, "fs_type": "?",
        "source": "?", "mount_opts": "?", "label": "?",
        "df_used": "?", "df_total": "?", "df_free": "?", "df_pct": None,
        "temp_c": None, "smart_ok": None, "smart_msg": "?",
        "dmesg_errs": 0, "usb_resets": 0, "usb_disconnects": 0,
        "model": "?",
    }
    # 1) Mount state
    try:
        if not Path(T7_MOUNT).is_mount():
            return info
        info["mount_ok"] = True
    except Exception:
        return info
    # 2) I/O probe
    try:
        os.listdir(T7_MOUNT)
    except OSError:
        info["io_error"] = True

    # 3) mount info: source/fs/opts
    try:
        out = subprocess.check_output(
            ["findmnt", "-no", "SOURCE,FSTYPE,OPTIONS", T7_MOUNT], timeout=2
        ).decode().strip().split()
        if len(out) >= 3:
            info["source"], info["fs_type"], info["mount_opts"] = out[0], out[1], out[2][:60]
    except Exception:
        pass

    # 4) df (если не io_error)
    if not info["io_error"]:
        try:
            out = subprocess.check_output(
                ["df", "-h", "--output=used,avail,size,pcent", T7_MOUNT], timeout=2
            ).decode().splitlines()
            if len(out) >= 2:
                p = out[1].split()
                info["df_used"], info["df_free"], info["df_total"] = p[0], p[1], p[2]
                info["df_pct"] = int(p[3].rstrip("%"))
        except Exception:
            pass

    # 5) temp
    t = c_t7_temp.get()
    if t: info["temp_c"] = t

    # 6) SMART через smartctl (sudo NOPASSWD есть)
    src = info["source"] if info["source"] != "?" else "/dev/sda"
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/sbin/smartctl", "-H", "-d", "sat", src],
            timeout=5, stderr=subprocess.STDOUT,
        ).decode(errors="replace")
        if "PASSED" in out:
            info["smart_ok"] = True; info["smart_msg"] = "PASSED"
        elif "FAILED" in out:
            info["smart_ok"] = False; info["smart_msg"] = "FAILED"
        else:
            info["smart_msg"] = "unknown"
    except subprocess.CalledProcessError as e:
        info["smart_msg"] = f"err {e.returncode}"
    except Exception:
        info["smart_msg"] = "n/a"

    # 7) Модель / Vendor. smartctl -i работает не для всех USB-bridge'ей.
    # Fallback цепочка: smartctl → /sys/block/.../model → /sys/block/.../vendor.
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/sbin/smartctl", "-i", "-d", "sat", src],
            timeout=5, stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
        for line in out.splitlines():
            if (line.startswith("Model Number:")
                    or line.startswith("Device Model:")
                    or line.startswith("Model Family:")
                    or line.startswith("Product:")):
                info["model"] = line.split(":", 1)[1].strip()[:30]
                break
    except Exception:
        pass
    if info["model"] == "?":
        # Fallback через sysfs — kernel всегда знает USB inquiry data
        # source = "/dev/sda1", нам нужен base "/sys/block/sda"
        m = re.match(r"/dev/([a-z]+)\d*$", src or "")
        if m:
            base = f"/sys/block/{m.group(1)}/device"
            parts = []
            for f in ("vendor", "model"):
                try:
                    p = Path(f"{base}/{f}").read_text().strip()
                    if p: parts.append(p)
                except Exception:
                    pass
            if parts:
                info["model"] = " ".join(parts)[:30]

    # 8) dmesg-ошибки (последний час)
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/bin/dmesg", "--time-format=iso"],
            timeout=3, stderr=subprocess.DEVNULL,
        ).decode(errors="replace")
    except Exception:
        out = ""
    if out:
        for line in out.splitlines()[-500:]:  # last ~500 lines
            ll = line.lower()
            if "sda" in ll:
                if "i/o error" in ll or "ext4-fs error" in ll:
                    info["dmesg_errs"] += 1
                if "reset" in ll and "usb" in ll:
                    info["usb_resets"] += 1
            if "usb disconnect" in ll:
                info["usb_disconnects"] += 1
    return info


c_disk_diag = Cached(_disk_diag, 30)


def page_storage_detail():
    """Подробности T7: mount, FS, SMART, температура, USB-ошибки в dmesg."""
    screen.fill(BG)
    y = draw_top_strip("Storage")
    y += 8
    btns = []
    d = c_disk_diag.get() or {}

    # === Header: mount status ===
    if not d.get("mount_ok"):
        screen.blit(F_LARGE.render("NOT MOUNTED", True, ERROR), (10, y))
        y += 28
        screen.blit(F_SMALL.render("проверь USB-кабель и /etc/fstab", True, MUTED), (10, y))
        y += 18
    elif d.get("io_error"):
        screen.blit(F_LARGE.render("I/O ERROR", True, ERROR), (10, y))
        y += 28
        screen.blit(F_SMALL.render("диск отвалился (hot-pull / glitch)", True, WARN), (10, y))
        y += 16
        screen.blit(F_SMALL.render("замени кабель → reboot → fsck", True, MUTED), (10, y))
        y += 18
    else:
        # OK путь — вкладка-таблица
        screen.blit(F_NORMAL.render(d.get("model", "?")[:28], True, FG), (10, y))
        y += 22

    # === Mount details ===
    if d.get("mount_ok"):
        def kv(label, value, value_col=FG):
            nonlocal y
            screen.blit(F_TINY.render(label, True, MUTED), (10, y))
            v = F_SMALL.render(str(value), True, value_col)
            screen.blit(v, (SCREEN_W - 10 - v.get_width(), y - 1))
            y += 16

        kv("source", d.get("source", "?"))
        kv("fs",     d.get("fs_type", "?"))
        if d.get("df_pct") is not None:
            pct_col = ACCENT if d["df_pct"] < 80 else (WARN if d["df_pct"] < 90 else ERROR)
            kv("space", f"{d.get('df_used')} / {d.get('df_total')} ({d['df_pct']}%)", pct_col)
            kv("free",  d.get("df_free", "?"))
        if d.get("temp_c"):
            tc = d["temp_c"]
            t_col = ACCENT if tc < 50 else (WARN if tc < 60 else ERROR)
            kv("temp", f"{tc}°C", t_col)

    y += 6
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 6

    # === SMART ===
    screen.blit(F_TINY.render("SMART", True, MUTED), (10, y))
    smart_msg = d.get("smart_msg", "?")
    smart_col = ACCENT if d.get("smart_ok") else (ERROR if d.get("smart_ok") is False else MUTED)
    sm = F_SMALL.render(smart_msg, True, smart_col)
    screen.blit(sm, (SCREEN_W - 10 - sm.get_width(), y - 1))
    y += 22

    # === USB / dmesg errors ===
    screen.blit(F_TINY.render("ERRORS (recent dmesg)", True, MUTED), (10, y))
    y += 14
    err_count = d.get("dmesg_errs", 0)
    usb_d = d.get("usb_disconnects", 0)
    usb_r = d.get("usb_resets", 0)
    err_col = ERROR if (err_count or usb_d or usb_r) else MUTED
    screen.blit(F_SMALL.render(f"sda I/O errors: {err_count}", True, err_col), (10, y)); y += 16
    screen.blit(F_SMALL.render(f"USB disconnects: {usb_d}", True, err_col), (10, y)); y += 16
    screen.blit(F_SMALL.render(f"USB resets:      {usb_r}", True, err_col), (10, y)); y += 16

    # === Last verify (bit-rot/IO scrub) ===
    v = c_verify.get() or {}
    if v.get("last_run"):
        y += 6
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 4
        screen.blit(F_TINY.render("Last verify", True, MUTED), (10, y))
        ok = v.get("status") == "ok"
        state_txt = "✓ ok" if ok else "✗ alert"
        state_col = ACCENT if ok else ERROR
        s = F_SMALL.render(state_txt, True, state_col)
        screen.blit(s, (SCREEN_W - 10 - s.get_width(), y - 1))
        y += 18
        # Parse last_run "YYYYMMDD-HHMMSS" → relative days
        try:
            from datetime import datetime, timezone
            t_run = datetime.strptime(v["last_run"], "%Y%m%d-%H%M%S")
            days_ago = (datetime.now() - t_run).days
            ago_txt = "today" if days_ago == 0 else (
                f"{days_ago}d ago" if days_ago < 30 else f"{days_ago // 30}mo ago")
            screen.blit(F_TINY.render(ago_txt, True, MUTED), (10, y))
        except Exception:
            screen.blit(F_TINY.render(v["last_run"], True, MUTED), (10, y))
        files_txt = f"{v.get('total_files', 0)} files · {v.get('bitrot', 0)} bit-rot"
        bf = F_TINY.render(files_txt, True, MUTED)
        screen.blit(bf, (SCREEN_W - 10 - bf.get_width(), y))
        y += 14

    # === Bottom: Back | Refresh ===
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "back_to_status",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "storage_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    btns.extend([back, refresh])
    return btns


def _photo_backups_list(limit=10):
    """Список бэкапов photos: idx по DD-MM-YYYY/HH-MM-SS_label_uuid.
    Возвращает [(date, time_label, files, size_bytes, incomplete), ...] — последние."""
    base = Path(T7_MOUNT) / "usb-imports"
    out = []
    if not base.is_dir():
        return out
    try:
        # date dirs DD-MM-YYYY, newest first
        date_dirs = sorted([d for d in base.iterdir() if d.is_dir()],
                            key=lambda d: d.name, reverse=True)
    except Exception:
        return out
    total = 0
    for dd in date_dirs:
        try:
            items = sorted(dd.iterdir(), key=lambda p: p.name, reverse=True)
        except Exception:
            continue
        for it in items:
            if not it.is_dir():
                continue
            incomplete = it.name.endswith(".incomplete")
            name = it.name.removesuffix(".incomplete") if incomplete else it.name
            files = 0
            size = 0
            try:
                for p in it.rglob("*"):
                    if p.is_file():
                        files += 1
                        try:
                            size += p.stat().st_size
                        except Exception:
                            pass
                        if files > 50000:
                            break
            except Exception:
                pass
            out.append({
                "date":  dd.name,
                "label": name,
                "files": files,
                "size":  size,
                "incomplete": incomplete,
            })
            total += 1
            if total >= limit:
                return out
    return out


def _photo_backups_totals():
    """Aggregate всех бэкапов: total backups / files / size."""
    base = Path(T7_MOUNT) / "usb-imports"
    if not base.is_dir():
        return None
    total_backups = 0
    total_files   = 0
    total_size    = 0
    incomplete    = 0
    try:
        for dd in base.iterdir():
            if not dd.is_dir(): continue
            for it in dd.iterdir():
                if not it.is_dir(): continue
                total_backups += 1
                if it.name.endswith(".incomplete"):
                    incomplete += 1
                # Считать files/size — дорого. Берём du -s per-backup иначе медленно.
                try:
                    for p in it.rglob("*"):
                        if p.is_file():
                            total_files += 1
                            try: total_size += p.stat().st_size
                            except Exception: pass
                            if total_files > 200000:
                                return {"backups": total_backups,
                                        "files": total_files,
                                        "size": total_size,
                                        "incomplete": incomplete,
                                        "truncated": True}
                except Exception:
                    pass
    except Exception:
        return None
    return {"backups": total_backups, "files": total_files,
            "size": total_size, "incomplete": incomplete,
            "truncated": False}


c_photo_list   = Cached(_photo_backups_list,   30)
c_photo_totals = Cached(_photo_backups_totals, 60)


def page_photo_backups():
    """Список SD/USB бэкапов: дата · label · files · size · incomplete-флаг."""
    screen.fill(BG)
    y = draw_top_strip("Photo backups")
    y += 8
    btns = []

    totals = c_photo_totals.get()
    items  = c_photo_list.get() or []

    if totals is None:
        screen.blit(F_NORMAL.render("/mnt/t7/usb-imports недоступен", True, ERROR), (10, y))
        y += 24
        screen.blit(F_SMALL.render("T7 не примонтирован?", True, MUTED), (10, y))
    elif totals.get("backups", 0) == 0:
        screen.blit(F_LARGE.render("none yet", True, MUTED), (10, y))
        y += 28
        screen.blit(F_SMALL.render("Бэкапы появятся когда подключишь", True, MUTED), (10, y))
        y += 16
        screen.blit(F_SMALL.render("SD-карту или USB-флешку через udev.", True, MUTED), (10, y))
        y += 22
        screen.blit(F_TINY.render("Source: /mnt/t7/usb-imports", True, MUTED), (10, y))
    else:
        # Aggregate
        n_b = totals["backups"]
        n_f = totals["files"]
        n_s = human_bytes(totals["size"])
        inc = totals["incomplete"]
        line1 = f"{n_b} imports · {n_f} files · {n_s}"
        screen.blit(F_NORMAL.render(line1, True, FG), (10, y))
        y += 22
        if inc:
            screen.blit(F_SMALL.render(f"⚠ {inc} incomplete", True, WARN), (10, y))
            y += 18

        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 6
        screen.blit(F_TINY.render("RECENT", True, MUTED), (10, y))
        y += 14

        for r in items[:10]:
            # Цвет/иконка для incomplete
            icon_col = WARN if r["incomplete"] else MUTED
            pygame.draw.circle(screen, icon_col, (16, y + 9), 4)
            # Compact format: date без года + HH:MM + source type.
            # Полное имя `17-43-21_USB_dev-sdb1` → `17:43 USB` (убираем
            # секунды + device path — они не помогают визуально различать).
            date_short = r["date"][:5] if len(r["date"]) >= 5 else r["date"]  # DD-MM
            label = r["label"]
            # Парсим HH-MM-SS_<source>_<dev-sdX>
            m = re.match(r"^(\d{2})-(\d{2})-\d{2}_([^_]+)", label)
            if m:
                short = f"{m.group(1)}:{m.group(2)} {m.group(3)}"[:16]
            else:
                short = label[:16] + ("…" if len(label) > 16 else "")
            text = f"{date_short} {short}"
            screen.blit(F_SMALL.render(text, True, FG), (28, y))
            # files+size справа
            right = f"{r['files']}f · {human_bytes(r['size'])}"
            if r["incomplete"]:
                right = "✗ " + right
            rt = F_TINY.render(right, True, WARN if r["incomplete"] else MUTED)
            screen.blit(rt, (SCREEN_W - 10 - rt.get_width(), y + 2))
            y += 18

    # === Bottom ===
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "back_to_status",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "photo_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    btns.extend([back, refresh])
    return btns


def _tailscale_info():
    """Возвращает dict со статусом Tailscale или {} если не установлено / down.
    Ключи: installed, online (bool), ip, dns_name, peers (int)."""
    out = {"installed": False}
    if not Path("/usr/bin/tailscale").exists() and not Path("/usr/local/bin/tailscale").exists():
        return out
    out["installed"] = True
    try:
        # --json не требует sudo если ставили с --operator=$USER
        raw = subprocess.check_output(
            ["tailscale", "status", "--json"], timeout=3,
            stderr=subprocess.DEVNULL,
        ).decode()
        data = json.loads(raw)
        self_info = data.get("Self", {}) or {}
        # BackendState: "Running" = ок, "NeedsLogin"/"Stopped" = down
        out["backend_state"] = data.get("BackendState", "?")
        out["online"] = data.get("BackendState") == "Running"
        ips = self_info.get("TailscaleIPs") or []
        out["ip"] = ips[0] if ips else None
        out["dns_name"] = (self_info.get("DNSName") or "").rstrip(".")
        out["peers"] = len((data.get("Peer") or {}))
    except Exception:
        out["online"] = False
    return out


c_tailscale = Cached(_tailscale_info, 15)


def _verify_status():
    """Читает /var/lib/travel-nas/verify-status.json (последний scrub).
    {} если файла нет (verify ещё не запускался)."""
    try:
        p = Path("/var/lib/travel-nas/verify-status.json")
        if not p.exists():
            return {}
        return json.loads(p.read_text())
    except Exception:
        return {}


c_verify = Cached(_verify_status, 60)


def _thermal_state():
    """JSON-state thermal-guard'а из /var/lib/travel-nas/thermal-guard.state.json
    плюс актуальный conf (mode/enabled). Возвращает dict со всеми нужными полями."""
    out = {
        "installed": Path("/usr/local/bin/thermal-guard.py").exists(),
        "enabled":   True,
        "mode":      "warn",
        "last_temp": None,
        "hot":       0,
        "cool":      0,
        "actions":   [],
        "thresholds": {},
    }
    if not out["installed"]:
        return out
    # State JSON
    try:
        st = json.loads(Path("/var/lib/travel-nas/thermal-guard.state.json").read_text())
        out["last_temp"] = st.get("last_temp")
        out["hot"]       = st.get("hot_consec", 0)
        out["cool"]      = st.get("cool_consec", 0)
        out["actions"]   = st.get("actions") or []
    except Exception:
        pass
    # Conf (mode + enabled + thresholds)
    try:
        for ln in Path("/etc/travel-nas/thermal-guard.conf").read_text().splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            m = re.match(r'^([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$', ln)
            if not m:
                continue
            k, v = m.group(1), m.group(2)
            if k == "ENABLED":          out["enabled"] = v.lower() == "true"
            elif k == "MODE":           out["mode"] = v.lower()
            elif k == "THROTTLE_TEMP":  out["thresholds"]["throttle"] = int(v)
            elif k == "PAUSE_TEMP":     out["thresholds"]["pause"]    = int(v)
            elif k == "STOP_TEMP":      out["thresholds"]["stop"]     = int(v)
            elif k == "COOLDOWN_TEMP":  out["thresholds"]["cool"]     = int(v)
    except Exception:
        pass
    return out


c_thermal = Cached(_thermal_state, 8)


def _thermal_write_conf_key(key, value):
    """Меняет KEY=VALUE в /etc/travel-nas/thermal-guard.conf (owned юзером).
    True если получилось записать. Используется кнопками страницы Thermal."""
    p = Path("/etc/travel-nas/thermal-guard.conf")
    if not p.exists():
        return False
    try:
        lines = p.read_text().splitlines()
        found = False
        for i, ln in enumerate(lines):
            if re.match(rf"^\s*{re.escape(key)}\s*=", ln):
                lines[i] = f"{key}={value}"
                found = True
                break
        if not found:
            lines.append(f"{key}={value}")
        p.write_text("\n".join(lines) + "\n")
        return True
    except Exception:
        return False


def _net_diag():
    """Сеть: интерфейс, ssid/signal/bitrate, IP, gateway, DNS, MAC, mode."""
    info = {
        "iface": "wlan0", "mode": "?", "ssid": "?", "signal": None,
        "bitrate": "?", "ip": "?", "gateway": "?", "dns": "?", "mac": "?",
    }
    wifi = c_wifi.get() or {}
    if wifi.get("ssid"):     info["ssid"]   = wifi["ssid"]
    if wifi.get("signal") is not None: info["signal"] = wifi["signal"]
    ip = c_ip.get()
    if ip: info["ip"] = ip
    gw = c_gateway.get()
    if gw: info["gateway"] = gw
    # Bitrate + mode + MAC
    try:
        out = subprocess.check_output(
            ["iw", "dev", "wlan0", "link"], timeout=2, stderr=subprocess.DEVNULL
        ).decode()
        for line in out.splitlines():
            line = line.strip()
            if line.startswith("tx bitrate:"):
                info["bitrate"] = line.split(":", 1)[1].strip()[:24]
    except Exception:
        pass
    try:
        with open(f"/sys/class/net/{info['iface']}/address") as f:
            info["mac"] = f.read().strip()
    except Exception:
        pass
    # Mode: AP / client
    ip_val = info["ip"]
    if ip_val and ip_val.startswith("10.41."):
        info["mode"] = "AP (comitup)"
    else:
        info["mode"] = "client"
    # DNS
    try:
        with open("/etc/resolv.conf") as f:
            servers = [l.split()[1] for l in f if l.startswith("nameserver")]
        info["dns"] = ", ".join(servers[:3])[:35]
    except Exception:
        pass
    return info


c_net_diag = Cached(_net_diag, 8)


def page_network_detail():
    """Подробности WiFi/сети: SSID, signal, IP, gateway, DNS, MAC, mode."""
    screen.fill(BG)
    y = draw_top_strip("Network")
    y += 8
    btns = []
    d = c_net_diag.get() or {}

    # Mode большой
    mode = d.get("mode", "?")
    mode_col = WARN if "AP" in mode else ACCENT
    screen.blit(F_NORMAL.render(mode, True, mode_col), (10, y))
    y += 24

    def kv(label, value, value_col=FG):
        nonlocal y
        screen.blit(F_TINY.render(label, True, MUTED), (10, y))
        v = F_SMALL.render(str(value)[:30], True, value_col)
        screen.blit(v, (SCREEN_W - 10 - v.get_width(), y - 1))
        y += 18

    kv("SSID",     d.get("ssid", "?"))
    sig = d.get("signal")
    if sig is not None:
        # -50 отлично, -65 ОК, -75 плохо
        sig_col = ACCENT if sig > -60 else (WARN if sig > -75 else ERROR)
        kv("signal", f"{sig} dBm", sig_col)
    if d.get("bitrate", "?") != "?":
        kv("bitrate", d["bitrate"])

    y += 4
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 4

    kv("IPv4",    d.get("ip", "?"))
    kv("gateway", d.get("gateway", "?"))
    kv("DNS",     d.get("dns", "?"))
    kv("MAC",     d.get("mac", "?"))

    # === Tailscale секция (если установлен) ===
    ts = c_tailscale.get() or {}
    if ts.get("installed"):
        y += 6
        pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
        y += 4
        screen.blit(F_TINY.render("Tailscale", True, MUTED), (10, y))
        state = "online" if ts.get("online") else (ts.get("backend_state") or "down")
        state_col = ACCENT if ts.get("online") else WARN
        s_surf = F_SMALL.render(state, True, state_col)
        screen.blit(s_surf, (SCREEN_W - 10 - s_surf.get_width(), y - 1))
        y += 18
        if ts.get("ip"):
            kv("TS IP", ts["ip"], ACCENT)
        if ts.get("dns_name"):
            # Magic DNS может быть длинным — обрежем агрессивнее
            dn = ts["dns_name"]
            if len(dn) > 26: dn = dn[:24] + "…"
            kv("magic DNS", dn)
        if ts.get("peers") is not None:
            kv("peers", str(ts["peers"]))

    # === Bottom ===
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "back_to_status",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "net_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    btns.extend([back, refresh])
    return btns


def page_system_detail():
    """Детали системы — top CPU/RAM-процессов + текущие метрики.
    Открывается по тапу на SYSTEM card на главной."""
    screen.fill(BG)
    y = draw_top_strip("System")
    y += 8
    btns = []

    # === Главная строка: CPU temp / freq / governor ===
    cpu_t = c_cpu_temp.get()
    cpu_p = c_cpu_pct.get()
    mhz   = c_cpu_max.get()
    th    = c_throttle.get()
    load  = c_load.get()
    mode  = c_pmode.get()
    cpu_c = ACCENT if (cpu_t or 0) < 65 else (WARN if (cpu_t or 0) < 75 else ERROR)

    line1 = f"CPU {cpu_t or '?'}°C  ·  {mhz:.1f}GHz" if mhz else f"CPU {cpu_t or '?'}°C"
    screen.blit(F_NORMAL.render(line1, True, cpu_c), (10, y))
    if cpu_p is not None:
        v = F_NORMAL.render(f"{cpu_p}%", True, FG)
        screen.blit(v, (SCREEN_W - 10 - v.get_width(), y))
    y += 22

    sub_bits = []
    if load is not None:  sub_bits.append(f"load {load:.2f}")
    if mode and mode != "unknown": sub_bits.append(f"mode {mode}")
    if th:
        sub_bits.append(f"throttle {th[0]}")
    screen.blit(F_SMALL.render("  ·  ".join(sub_bits), True, MUTED), (10, y))
    y += 18
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 8

    # === TOP по CPU ===
    screen.blit(F_TINY.render("TOP CPU", True, MUTED), (10, y))
    y += 14
    rows = c_top_cpu.get() or []
    if not rows:
        screen.blit(F_SMALL.render("(idle, <0.5%)", True, MUTED), (10, y))
        y += 16
    else:
        for r in rows[:5]:
            screen.blit(F_SMALL.render(r["name"], True, FG), (10, y))
            v = F_SMALL.render(f"{r['cpu']:.1f}%", True, ACCENT if r["cpu"] < 50 else WARN)
            screen.blit(v, (SCREEN_W - 10 - v.get_width(), y))
            y += 16

    y += 6
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 8

    # === TOP по RAM ===
    screen.blit(F_TINY.render("TOP MEM", True, MUTED), (10, y))
    y += 14
    rows = c_top_mem.get() or []
    if not rows:
        screen.blit(F_SMALL.render("(<0.5%)", True, MUTED), (10, y))
        y += 16
    else:
        for r in rows[:5]:
            screen.blit(F_SMALL.render(r["name"], True, FG), (10, y))
            v = F_SMALL.render(f"{r['mem']:.1f}%", True, INFO)
            screen.blit(v, (SCREEN_W - 10 - v.get_width(), y))
            y += 16

    # === Bottom: Back | Refresh ===
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "back_to_status",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    refresh = Btn("Refresh", "system_refresh",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(refresh)
    btns.extend([back, refresh])
    return btns


def page_thermal():
    """Управление thermal-guard'ом: статус, mode toggle, enable/disable, restore."""
    screen.fill(BG)
    y = draw_top_strip("Thermal guard")
    y += 8
    btns = []
    t = c_thermal.get() or {}

    if not t.get("installed"):
        screen.blit(F_NORMAL.render("thermal-guard не установлен", True, ERROR), (10, y))
        y += 24
        screen.blit(F_SMALL.render("travel-nas-setup → THERMAL_GUARD", True, MUTED), (10, y))
        back = Btn("Back", "open_menu",
                   pygame.Rect(8, SCREEN_H - 54, SCREEN_W - 16, 46), MUTED)
        draw_button(back); return [back]

    # === Заголовок: большая температура + цветной mode-бейдж ===
    temp = t.get("last_temp")
    thr = t.get("thresholds") or {}
    if temp is None:
        temp_str = "?"
        temp_col = MUTED
    else:
        temp_str = f"{temp}°C"
        if temp >= thr.get("stop", 85):       temp_col = ERROR
        elif temp >= thr.get("pause", 82):    temp_col = ERROR
        elif temp >= thr.get("throttle", 80): temp_col = WARN
        elif temp <= thr.get("cool", 70):     temp_col = ACCENT
        else:                                 temp_col = FG

    big = F_LARGE.render(temp_str, True, temp_col)
    screen.blit(big, (10, y))

    mode = t.get("mode", "warn")
    enabled = t.get("enabled", True)
    if not enabled:
        mode_label, mode_col = "DISABLED", MUTED
    elif mode == "auto":
        mode_label, mode_col = "AUTO", ACCENT
    else:
        mode_label, mode_col = "WARN", INFO
    m_s = F_NORMAL.render(mode_label, True, mode_col)
    screen.blit(m_s, (SCREEN_W - 10 - m_s.get_width(), y + 8))
    y += 36

    # Hot/cool counters
    h, cl = t.get("hot", 0), t.get("cool", 0)
    screen.blit(F_TINY.render(
        f"hot {h}m  ·  cool {cl}m", True, MUTED), (10, y))
    y += 14
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 6

    # === Thresholds компактно ===
    th_line = (f"throttle {thr.get('throttle','?')}°  "
               f"pause {thr.get('pause','?')}°  "
               f"stop {thr.get('stop','?')}°")
    screen.blit(F_TINY.render(th_line, True, MUTED), (10, y))
    y += 14
    screen.blit(F_TINY.render(
        f"restore при ≤ {thr.get('cool','?')}° подряд", True, MUTED), (10, y))
    y += 16

    # === Actions list ===
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 6
    screen.blit(F_TINY.render("ACTIONS", True, MUTED), (10, y))
    y += 14
    acts = t.get("actions") or []
    if not acts:
        screen.blit(F_SMALL.render("система не вмешивается", True, MUTED), (10, y))
        y += 16
    else:
        for a in acts[:6]:
            name = (a.get("container") or "?")
            if len(name) > 24: name = name[:22] + "…"
            stage = a.get("stage", "?")
            st_col = ERROR if stage == "stop" else (WARN if stage == "pause" else INFO)
            screen.blit(F_SMALL.render(name, True, FG), (10, y))
            s_s = F_SMALL.render(stage, True, st_col)
            screen.blit(s_s, (SCREEN_W - 10 - s_s.get_width(), y))
            y += 16

    # === Кнопки управления ===
    # Layout: [Mode toggle] над [Enable toggle | Restore] над [Back | Open log]
    btn_h = 30
    spacing = 4
    by = SCREEN_H - 54 - (btn_h + spacing) * 2 - 8

    # Row 1: Mode toggle full-width (warn↔auto). Не активна если DISABLED.
    next_mode = "auto" if mode != "auto" else "warn"
    mode_label_full = f"Mode → {next_mode.upper()}"
    mode_btn_col = ACCENT if next_mode == "auto" else INFO
    mode_btn = Btn(mode_label_full, "thermal_toggle_mode",
                   pygame.Rect(8, by, SCREEN_W - 16, btn_h),
                   mode_btn_col if enabled else MUTED)
    draw_button(mode_btn, F_SMALL)
    if enabled: btns.append(mode_btn)
    by += btn_h + spacing

    # Row 2: Enable/Disable | Restore
    half_w2 = (SCREEN_W - 28) // 2
    en_label = "Disable" if enabled else "Enable"
    en_col   = MUTED if enabled else ACCENT
    en_btn   = Btn(en_label, "thermal_toggle_enabled",
                   pygame.Rect(8, by, half_w2, btn_h), en_col)
    rest_disabled = not acts
    rest_btn = Btn("Restore", "thermal_restore",
                   pygame.Rect(SCREEN_W - 8 - half_w2, by,
                               half_w2, btn_h),
                   MUTED if rest_disabled else WARN)
    draw_button(en_btn, F_SMALL); draw_button(rest_btn, F_SMALL)
    btns.append(en_btn)
    if not rest_disabled: btns.append(rest_btn)

    # Row 3 (Bottom): Back | Open log
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "open_menu",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    log_btn = Btn("View log", "thermal_open_log",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), INFO)
    draw_button(back); draw_button(log_btn)
    btns.extend([back, log_btn])
    return btns


def page_configs():
    """Шпаргалка где что лежит — чтоб не забыть перед перепрошивкой."""
    screen.fill(BG)
    y = draw_top_strip("Configs")
    y += 6

    confs = [
        ("/etc/travel-nas/tg-notify.conf",      "Telegram bot token"),
        ("/etc/travel-nas/nas-backup.conf",     "NAS host + password"),
        ("/etc/travel-nas/services.conf",       "Dashboard URL list"),
        ("/etc/travel-nas/power-mode.conf",     "Home WiFi SSIDs"),
        ("/etc/travel-nas/photo-backup.conf",   "USB backup settings"),
        ("/etc/travel-nas/thermal-guard.conf",  "Перегрев: mode/пороги/excludes"),
        ("/etc/travel-nas/t7-info.conf",        "T7 UUID (auto)"),
    ]

    screen.blit(F_TINY.render("/etc/travel-nas/  (●=exists)", True, MUTED), (10, y))
    y += 14
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 4

    for path, desc in confs:
        name = path.split("/")[-1]
        exists = Path(path).exists()
        col = ACCENT if exists else MUTED
        # ●/○ dot слева
        pygame.draw.circle(screen, col, (16, y + 8), 4 if exists else 3,
                           0 if exists else 1)
        screen.blit(F_SMALL.render(name, True, FG if exists else MUTED), (28, y))
        screen.blit(F_TINY.render(desc, True, MUTED), (28, y + 13))
        y += 28

    y += 2
    pygame.draw.line(screen, BTN_BG, (10, y), (SCREEN_W - 10, y), 1)
    y += 6

    # Backup команда
    screen.blit(F_TINY.render("Pi-config-backup runs Sun 03:00.", True, INFO), (10, y))
    y += 14
    screen.blit(F_TINY.render("Saved to /mnt/t7/pi-config-backups/", True, MUTED), (10, y))
    y += 16

    screen.blit(F_TINY.render("T7 SURVIVES microSD wipe:", True, ACCENT), (10, y))
    y += 14
    for line in [
        "  /mnt/t7/usb-imports  (USB backups)",
        "  /mnt/t7/nas-backup   (NAS sync)",
        "  /mnt/t7/_logs        (script logs)",
    ]:
        screen.blit(F_TINY.render(line, True, MUTED), (10, y))
        y += 13

    # Flip screen — тонкая полная-ширина кнопка над bottom row
    flip_y = SCREEN_H - 54 - 38
    flip_btn = Btn("↻ Flip screen (USB top ↔ bottom)", "open_flip_confirm",
                   pygame.Rect(8, flip_y, SCREEN_W - 16, 32), INFO)
    draw_button(flip_btn, F_SMALL)

    # Bottom: Back | Backup now — Back всегда слева
    half_w = (SCREEN_W - 28) // 2
    back = Btn("Back", "open_menu",
               pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    backup_btn = Btn("Backup now", "pi_backup_now",
                     pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), ACCENT)
    draw_button(back); draw_button(backup_btn)
    return [flip_btn, back, backup_btn]


def page_ap_info():
    screen.fill(BG)
    y = draw_top_strip("AP info")
    y += 8
    screen.blit(F_LARGE.render("AP Mode", True, WARN), (8, y)); y += 32

    cs = c_comitup.get()
    if cs:
        col = ACCENT if cs.upper() in ("CONNECTED", "CONNECTING") else WARN
        screen.blit(F_SMALL.render(f"comitup: {cs}", True, col), (8, y)); y += 18

    # comitup создаёт AP с именем comitup-NNN (NNN = последние цифры MAC/serial).
    screen.blit(F_SMALL.render("WiFi network:", True, MUTED), (8, y)); y += 16
    screen.blit(F_MED.render("comitup-NNN", True, FG), (8, y)); y += 30

    screen.blit(F_SMALL.render("Password:", True, MUTED), (8, y)); y += 16
    screen.blit(F_NORMAL.render("(open network)", True, FG), (8, y)); y += 26

    ip = c_ip.get() or "10.41.0.1"
    screen.blit(F_SMALL.render("Connect to AP, then:", True, MUTED), (8, y)); y += 16
    screen.blit(F_SMALL.render("Setup WiFi: http://10.41.0.1:8080", True, FG), (8, y)); y += 16
    if not (ip and ip.startswith("10.41.")):
        screen.blit(F_SMALL.render(f"Current IP: {ip}", True, MUTED), (8, y)); y += 16
    screen.blit(F_SMALL.render(f"Web:  http://{ip}:8080", True, FG), (8, y)); y += 16
    screen.blit(F_SMALL.render(f"SSH:  ssh oleg@{ip}", True, FG), (8, y))

    back = Btn("Back", "back_to_prev", pygame.Rect(8, SCREEN_H - 54, SCREEN_W - 16, 46), MUTED)
    draw_button(back); return [back]


def _draw_confirm(title, lines, action, button_label, button_color):
    screen.fill(BG)
    y = draw_top_strip(title)
    y += 12
    screen.blit(F_LARGE.render(title + "?", True, button_color), (8, y)); y += 36
    for line in lines:
        screen.blit(F_NORMAL.render(line, True, FG), (8, y)); y += 22

    half_w = (SCREEN_W - 24) // 2
    cancel = Btn("Cancel", "open_menu",
                 pygame.Rect(8, SCREEN_H - 54, half_w, 46), MUTED)
    confirm = Btn(button_label, action,
                  pygame.Rect(8 + half_w + 8, SCREEN_H - 54, half_w, 46),
                  button_color, primary=True)
    draw_button(cancel); draw_button(confirm)
    return [cancel, confirm]


def page_ap_confirm():
    return _draw_confirm(
        "Force AP",
        [
            "Drops current WiFi and",
            "starts comitup hotspot.",
            "",
            "Connect to:",
            "  comitup-NNN",
            "  http://10.41.0.1:8080",
            "",
            "Pi запомнит новый WiFi",
            "после ввода через portal.",
        ],
        "do_force_ap", "Force AP", WARN,
    )


def page_reboot_confirm():
    return _draw_confirm(
        "Reboot",
        [
            "Reboot the Pi now.",
            "",
            "All running backups",
            "will be interrupted.",
        ],
        "do_reboot", "Reboot", WARN,
    )


def page_flip_confirm():
    # Текущая ориентация из config.txt — показываем "0° → 180°" или наоборот
    cur = "?"
    try:
        with open("/boot/firmware/config.txt") as f:
            for line in f:
                if "dtoverlay=mhs35:rotate=" in line:
                    cur = line.split("rotate=", 1)[1].strip()
                    break
    except Exception:
        pass
    nxt = "180°" if cur == "0" else "0°"
    arrow = f"{cur}° → {nxt}"
    return _draw_confirm(
        "Flip screen",
        [
            arrow,
            "",
            "Pi reboots сразу.",
            "Возвращается через",
            "~30-60 сек.",
        ],
        "do_flip_screen", "Flip + reboot", INFO,
    )


def page_off_confirm():
    return _draw_confirm(
        "Shutdown",
        [
            "Power off the Pi.",
            "",
            "Wait for green LED",
            "to stop blinking",
            "before unplugging.",
        ],
        "do_shutdown", "Shutdown", ERROR,
    )


PAGES = {
    PAGE_STATUS:         page_status,
    PAGE_MENU:           page_menu,
    PAGE_PROGRESS:       page_progress,
    PAGE_LOGS:           page_logs,
    PAGE_LOG_VIEW:       page_log_view,
    PAGE_AP_INFO:        page_ap_info,
    PAGE_AP_CONFIRM:     page_ap_confirm,
    PAGE_REBOOT_CONFIRM: page_reboot_confirm,
    PAGE_OFF_CONFIRM:    page_off_confirm,
    PAGE_FLIP_CONFIRM:   page_flip_confirm,
    PAGE_SERVICES:       page_services,
    PAGE_NAS_STATUS:     page_nas_status,
    PAGE_DAILY_SUMMARY:  page_daily_summary,
    PAGE_CONFIGS:        page_configs,
    PAGE_DOCKER:         page_docker,
    PAGE_YTARCHIVER:     page_ytarchiver,
    PAGE_SYSTEM_DETAIL:  page_system_detail,
    PAGE_STORAGE_DETAIL: page_storage_detail,
    PAGE_NETWORK_DETAIL: page_network_detail,
    PAGE_PHOTO_BACKUPS:  page_photo_backups,
    PAGE_THERMAL:        page_thermal,
}


# =============================================================================
# Toast / touch-flash overlays
# =============================================================================
def draw_toast():
    t = state.get("toast")
    if not t: return False
    text, ts, color = t
    if time.time() - ts > TOAST_DURATION:
        state["toast"] = None
        return False
    surf = F_SMALL.render(text, True, BG)
    pad_x, pad_y = 10, 6
    w = surf.get_width() + pad_x * 2
    h = surf.get_height() + pad_y * 2
    rect = pygame.Rect((SCREEN_W - w) // 2, 30, w, h)
    pygame.draw.rect(screen, color, rect, border_radius=6)
    screen.blit(surf, (rect.x + pad_x, rect.y + pad_y))
    return True


def draw_touch_flash():
    global touch_flash
    if touch_flash is None: return False
    x, y, ts = touch_flash
    age = time.time() - ts
    if age > TOUCH_FLASH_DURATION:
        touch_flash = None
        return False
    radius = int(14 + age * 80)
    alpha = max(0, 220 - int(age * 220 / TOUCH_FLASH_DURATION))
    s = pygame.Surface((radius * 2 + 4, radius * 2 + 4), pygame.SRCALPHA)
    pygame.draw.circle(s, (76, 175, 80, alpha), (radius + 2, radius + 2), radius, 3)
    screen.blit(s, (x - radius - 2, y - radius - 2))
    return True


# =============================================================================
# Action dispatch
# =============================================================================
def _spawn_nas(action_arg, msg, color):
    log_path = Path("/mnt/t7/nas-backup/_logs/dashboard.log")
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass
    try:
        lf = open(log_path, "ab")
    except Exception:
        lf = subprocess.DEVNULL
    subprocess.Popen(
        ["sudo", "-n", "/usr/local/bin/nas-backup.sh", action_arg],
        stdout=lf, stderr=lf, stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    toast(msg, color)


def do_action(action):
    if action == "open_menu":           go(PAGE_MENU)
    elif action == "back_to_status":    go(PAGE_STATUS)
    elif action == "back_to_prev":
        prev = state["prev_page"]
        state["prev_page"] = state["page"]
        state["page"] = prev
    elif action == "open_logs":
        state["log_paused"] = False
        go(PAGE_LOGS)
    elif action.startswith("log_"):
        state["log_idx"] = int(action.split("_", 1)[1])
        state["log_paused"] = False
        go(PAGE_LOG_VIEW)
    elif action == "toggle_log_pause":
        state["log_paused"] = not state.get("log_paused", False)
    elif action == "open_ap_info":      go(PAGE_AP_INFO)
    elif action == "open_services":
        c_services.invalidate()  # свежий conf при заходе на страницу
        go(PAGE_SERVICES)
    elif action == "services_refresh":  c_services.invalidate()
    elif action == "exit_to_desktop":
        # Постим QUIT — main loop корректно остановится, pygame.quit() в конце.
        # Пользователь вернётся через Desktop ярлык "Travel-NAS Dashboard".
        # Заодно: перезаписываем ярлыки на рабочем столе (без дублей —
        # write_text overwrite-ит существующие). Чтоб юзер их видел сразу
        # после exit, а не после следующего travel-nas-update.
        _ensure_desktop_icons()
        pygame.event.post(pygame.event.Event(pygame.QUIT))
        toast("Exiting to desktop…", MUTED)
    elif action == "open_nas_status":   go(PAGE_NAS_STATUS)
    elif action == "open_daily":        go(PAGE_DAILY_SUMMARY)
    elif action == "open_configs":      go(PAGE_CONFIGS)
    elif action == "open_docker":       go(PAGE_DOCKER)
    elif action == "open_yt":           go(PAGE_YTARCHIVER)
    elif action == "open_thermal":
        c_thermal.invalidate(); go(PAGE_THERMAL)
    elif action == "thermal_toggle_mode":
        cur = (c_thermal.get() or {}).get("mode", "warn")
        new = "auto" if cur != "auto" else "warn"
        if _thermal_write_conf_key("MODE", new):
            c_thermal.invalidate()
            toast(f"Thermal mode → {new}", ACCENT if new == "auto" else INFO)
        else:
            toast("conf write failed", ERROR)
    elif action == "thermal_toggle_enabled":
        cur = (c_thermal.get() or {}).get("enabled", True)
        new = "false" if cur else "true"
        if _thermal_write_conf_key("ENABLED", new):
            c_thermal.invalidate()
            toast(f"Thermal {'enabled' if new == 'true' else 'disabled'}",
                  ACCENT if new == "true" else MUTED)
        else:
            toast("conf write failed", ERROR)
    elif action == "thermal_restore":
        try:
            subprocess.run(["sudo", "-n", "/usr/local/bin/thermal-guard.py",
                            "--restore"], timeout=60, capture_output=True)
            c_thermal.invalidate()
            toast("Restored all actions", ACCENT)
        except Exception:
            toast("restore failed", ERROR)
    elif action == "thermal_open_log":
        # Открыть log_view для thermal-guard. Ищем индекс в LOG_OPTIONS.
        for i, (name, _) in enumerate(LOG_OPTIONS):
            if name == "Thermal guard":
                state["log_idx"] = i
                state["prev_page"] = PAGE_THERMAL  # чтобы Back из log вернуло сюда
                go(PAGE_LOG_VIEW)
                break
    elif action == "yt_refresh":
        c_yt.invalidate()
        toast("YT stats refreshing…", INFO)
    elif action in ("yt_pause", "yt_resume"):
        # Текущее состояние берём из кэша; toggle вызывает API.
        current = bool((c_yt.get() or {}).get("paused"))
        ok, new_state = _yt_toggle_pause(current)
        c_yt.invalidate()  # пересчитать с новым state
        if ok:
            toast("All downloads paused" if new_state else "Downloads resumed",
                  WARN if new_state else ACCENT)
        else:
            toast("yt-archiver: API request failed", ERROR)
    elif action == "open_system_detail":  go(PAGE_SYSTEM_DETAIL)
    elif action == "system_refresh":
        c_top_cpu.invalidate(); c_top_mem.invalidate()
        toast("Refreshing…", INFO)
    elif action == "open_storage_detail":  go(PAGE_STORAGE_DETAIL)
    elif action == "storage_refresh":
        c_disk_diag.invalidate(); c_disk.invalidate(); c_verify.invalidate()
        toast("Refreshing storage…", INFO)
    elif action == "open_network_detail":  go(PAGE_NETWORK_DETAIL)
    elif action == "net_refresh":
        c_net_diag.invalidate(); c_ip.invalidate(); c_wifi.invalidate()
        c_gateway.invalidate(); c_tailscale.invalidate()
        toast("Refreshing network…", INFO)
    elif action == "open_photo_backups": go(PAGE_PHOTO_BACKUPS)
    elif action == "photo_refresh":
        c_photo_list.invalidate(); c_photo_totals.invalidate(); c_last.invalidate()
        toast("Scanning imports…", INFO)
    elif action == "docker_refresh":
        # Сброс кеша → следующий рендер дёрнет actual data
        c_docker.last = 0
        toast("Refreshing…", INFO)
    elif action.startswith("docker_stop:") or action.startswith("docker_start:"):
        op, name = action.split(":", 1)
        op = op.replace("docker_", "")
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/docker-mgr.sh", op, name],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        toast(f"docker {op} {name}…", WARN if op == "stop" else ACCENT)
        c_docker.last = 0  # инвалидируем кеш чтоб через 1-2 рендера видеть новый статус
    elif action == "pi_backup_now":
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/pi-config-backup.sh"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        toast("Pi-config backup started…", ACCENT)
    elif action == "nas_status_refresh":
        # --query-source — фолбэк через rsync --dry-run --stats для модулей
        # у которых нет завершённого backup-лога. МЕДЛЕННО (минуты).
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/nas-backup-status.py", "--query-source"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        toast("Refreshing (querying NAS — may take minutes)…", INFO)
    elif action == "daily_refresh":
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/daily-summary.sh", "--json"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        toast("Refreshing daily summary…", INFO)
    elif action == "open_ap_confirm":   go(PAGE_AP_CONFIRM)
    elif action == "open_reboot":       go(PAGE_REBOOT_CONFIRM)
    elif action == "open_off":          go(PAGE_OFF_CONFIRM)
    elif action == "open_flip_confirm": go(PAGE_FLIP_CONFIRM)
    elif action == "progress_open":     go(PAGE_PROGRESS)

    elif action in ("pwr_normal", "pwr_saver", "pwr_auto"):
        # Записываем pref + сразу применяем. Скрипт сам обновит state-file,
        # дашборд подхватит через c_pmode/c_ppref на следующем ticke.
        mode_arg = action.replace("pwr_", "")
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/power-mode.sh", mode_arg],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        # Инвалидируем кэши чтобы подсветка кнопки обновилась сразу
        c_pmode.invalidate(); c_ppref.invalidate()
        toast(f"Power → {mode_arg}", INFO if mode_arg == "auto" else
              (ACCENT if mode_arg == "normal" else WARN))

    elif action == "do_force_ap":
        # Документированный (см. comitup-cli.8) способ переключения в HOTSPOT:
        # `comitup-cli d` — удаляет текущий NM-connection профиль; comitup
        # daemon ловит это через D-Bus и тут же стартует AP. comitup-web
        # слушает на :8080 (web_port в /etc/comitup.conf), чтобы не
        # конфликтить с CasaOS-gateway на :80.
        if not Path("/usr/sbin/comitup-cli").exists():
            toast("comitup not installed", ERROR)
        else:
            subprocess.Popen(
                ["sudo", "-n", "/usr/sbin/comitup-cli", "d"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL, start_new_session=True,
            )
            toast("Dropping WiFi → AP… (5-15 сек)", WARN)
            go(PAGE_STATUS)
    elif action == "do_reboot":
        # Ставим persistent shutdown-screen state — main loop увидит и
        # будет держать чёрный экран с текстом пока fast-reboot.sh не
        # прибьёт нас через halt syscall. LCD persistence сохранит ЭТОТ
        # кадр после power-cut, не обычный дашборд.
        state["shutdown_msg"] = "REBOOTING\n\nunplug USB-C\nto force off"
        subprocess.Popen(["sudo", "-n", "/usr/local/bin/fast-reboot.sh"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    elif action == "do_shutdown":
        state["shutdown_msg"] = "POWERED OFF\n\nunplug USB-C\nto fully disconnect\n(red LED = standby)"
        subprocess.Popen(["sudo", "-n", "/usr/local/bin/fast-shutdown.sh"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    elif action == "do_flip_screen":
        # Применяем flip (config.txt + xorg calibration) и сразу же ребутаем.
        # screen-rotate.sh sync операция (~0.5 сек); reboot потом отдельно.
        try:
            subprocess.run(
                ["sudo", "-n", "/usr/local/bin/screen-rotate.sh", "flip"],
                timeout=10, capture_output=True,
            )
        except Exception:
            pass
        state["shutdown_msg"] = "FLIPPING\n\nrebooting...\nback in 30-60s"
        subprocess.Popen(["sudo", "-n", "/usr/local/bin/fast-reboot.sh"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)

    elif action == "nas_run":   _spawn_nas("--run",     "NAS backup started", ACCENT)
    elif action == "nas_dry":   _spawn_nas("--dry-run", "Dry-run started",    INFO)
    elif action == "nas_diff":  _spawn_nas("--diff",    "Diff started",       INFO)
    elif action == "nas_stop":
        # systemctl stop кладёт SIGTERM на cgroup unit'а — рssync и
        # backup-progress-writer завершаются. JSON-файл прогресса rsync не
        # успеет дописать, но это ок: следующий чек по systemctl is-active
        # вернёт false и Stop-кнопка исчезнет.
        subprocess.Popen(
            ["sudo", "-n", "/usr/bin/systemctl", "stop", "nas-backup-runtime"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        c_nas_run.invalidate()
        toast("Stopping NAS backup…", WARN)


# =============================================================================
# Main loop
# =============================================================================
def main():
    global last_activity, last_force_above, last_touch_ts, touch_flash, display_on
    last_refresh = 0.0
    btns = []
    running = True

    while running:
        now = time.time()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                last_activity = now
                set_backlight(True)
            elif event.type in (pygame.MOUSEBUTTONDOWN, pygame.FINGERDOWN):
                # X11 + evdev часто шлёт оба → дедупим
                if now - last_touch_ts < TOUCH_DEDUP_WINDOW:
                    continue
                last_touch_ts = now
                if event.type == pygame.MOUSEBUTTONDOWN:
                    pos = event.pos
                else:
                    pos = (int(event.x * SCREEN_W), int(event.y * SCREEN_H))
                last_activity = now
                touch_flash = (pos[0], pos[1], now)
                if not display_on:
                    set_backlight(True)
                    continue
                for b in btns:
                    if b.rect.collidepoint(pos):
                        do_action(b.action)
                        last_refresh = 0  # принудительный rerender
                        break

        # Auto-sleep (не во время бэкапа). Таймаут берётся из файла на лету —
        # юзер меняет через /sleep в TG, дашборд подхватывает без рестарта.
        # 0 = никогда не гасить.
        sleep_to = c_sleep.get()
        if (display_on
                and sleep_to > 0
                and (now - last_activity) > sleep_to
                and get_progress() is None
                and not c_busy.get()):
            set_backlight(False)
            screen.fill((0, 0, 0))
            pygame.display.flip()

        # Re-assert Z-order периодически (cheap; страховка от LXDE-панели)
        if now - last_force_above > FORCE_ABOVE_INTERVAL:
            last_force_above = now
            force_above()

        # Если backup закончился — выходим из PROGRESS обратно
        if state["page"] == PAGE_PROGRESS and get_progress() is None:
            go(PAGE_STATUS)

        overlays_active = (touch_flash is not None) or (state.get("toast") is not None)
        interval = FAST_REFRESH_INTERVAL if overlays_active else REFRESH_INTERVAL

        # Shutdown overlay — рисуем каждый тик пока state['shutdown_msg']
        # активен. Это до halt syscall'а — LCD persistence сохранит ИМЕННО
        # этот кадр после power-cut, не обычный дашборд.
        if state.get("shutdown_msg"):
            _shutdown_screen(state["shutdown_msg"])
            clock.tick(FPS)
            continue

        if display_on and (now - last_refresh) > interval:
            last_refresh = now
            draw_fn = PAGES.get(state["page"], page_status)
            try:
                btns = draw_fn() or []
            except Exception as e:
                screen.fill(BG)
                err_surf = F_SMALL.render(f"draw error: {e}", True, ERROR)
                screen.blit(err_surf, (8, 8))
                btns = []
            draw_toast()
            draw_touch_flash()
            pygame.display.flip()

        # Screenshot-on-demand для /screenshot из tg-listener. Дёшево: один
        # Path.exists() за тик. Когда tg-listener тапает SCREENSHOT_REQ —
        # сохраняем текущий экран и удаляем флаг.
        if SCREENSHOT_REQ.exists():
            try:
                pygame.image.save(screen, str(SCREENSHOT_OUT))
            except Exception:
                pass
            try: SCREENSHOT_REQ.unlink()
            except Exception: pass

        clock.tick(FPS)

    pygame.quit()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pygame.quit()
    except Exception as e:
        import traceback
        try:
            with open(ERROR_LOG, "a") as f:
                f.write(f"[{datetime.now()}] {e}\n")
                f.write(traceback.format_exc())
        except Exception:
            pass
        raise
