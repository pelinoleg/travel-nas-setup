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
SLEEP_AFTER_SEC = 300          # 5 минут до auto-sleep
TOAST_DURATION = 2.0
TOUCH_FLASH_DURATION = 0.25
TOUCH_DEDUP_WINDOW = 0.12      # игнорируем дубль touch+mouse в одно касание
FORCE_ABOVE_INTERVAL = 3       # cheap re-assert: ловит pcmanfm/udev попапы быстро

STATE_DIR = Path("/var/run/travel-nas")
PROGRESS_FILE = STATE_DIR / "backup-progress.json"
ERROR_LOG = Path("/tmp/travel-nas-display.error.log")

T7_MOUNT = "/mnt/t7"

SERVICES_CONF      = Path("/etc/travel-nas/services.conf")
NAS_STATUS_JSON    = Path("/var/lib/travel-nas/nas-backup-status.json")
DAILY_SUMMARY_JSON = Path("/var/lib/travel-nas/daily-summary.json")
POWER_MODE_FILE    = Path("/var/lib/travel-nas/power-mode.txt")
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
    """vcgencmd get_throttled → ('OK'|'NOW'|'past', color)."""
    out = subprocess.check_output(["vcgencmd", "get_throttled"], timeout=2).decode()
    val = int(out.strip().split("=")[1], 16)
    if val == 0:                return ("OK", ACCENT)
    if val & 0x7:               return ("NOW", ERROR)
    if val & 0x70000:           return ("past", WARN)
    return ("past", WARN)


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
        ["sudo", "-n", "smartctl", "-a", "-d", "sat", device],
        timeout=5, stderr=subprocess.DEVNULL,
    ).decode()
    for line in out.splitlines():
        if "Temperature" in line:
            for p in line.split():
                if p.isdigit() and 10 < int(p) < 100:
                    return int(p)
    return None


def _disk_info():
    out = subprocess.check_output(
        ["df", "-h", "--output=used,avail,size,pcent", T7_MOUNT], timeout=2
    ).decode().splitlines()
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
            ["sudo", "-n", "smbstatus", "-b"],
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


def load_services():
    """Возвращает [(name, url)] — из /etc/travel-nas/services.conf или дефолты.
    {host}/{ip} в URL подставляются текущими значениями."""
    items = SERVICES_DEFAULTS
    if SERVICES_CONF.exists():
        try:
            parsed = []
            for line in SERVICES_CONF.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                parsed.append((k.strip(), v.strip()))
            if parsed:
                items = parsed
        except Exception:
            pass
    ip = c_ip.get() or "?"
    host = f"{socket.gethostname()}.local"
    return [(n, u.replace("{host}", host).replace("{ip}", ip)) for n, u in items]


def health_status():
    """Аггрегат "общего здоровья" — mount/SMART/temp/disk-fill.
    Throttling и питание оцениваются ОТДЕЛЬНО через ⚡-значок, не сюда."""
    bad, warn = False, False
    disk = c_disk.get()
    if not disk:
        bad = True
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


c_pmode = Cached(_power_mode, 5)


def draw_top_strip(page_label=None):
    """Top-strip:
       Слева:    ● health-точка + hostname
       Центр:    [⚡] power: <mode> <freq>GHz <W>W
       Справа:   HH:MM"""
    pygame.draw.rect(screen, PANEL, (0, 0, SCREEN_W, 22))
    _, color = health_status()
    pygame.draw.circle(screen, color, (12, 11), 5)

    host_text = page_label or socket.gethostname()
    host_surf = F_SMALL.render(host_text, True, FG)
    screen.blit(host_surf, (24, 4))

    now_str = datetime.now().strftime("%H:%M")
    t_surf = F_SMALL.render(now_str, True, MUTED)
    screen.blit(t_surf, (SCREEN_W - t_surf.get_width() - 8, 4))

    # === Центрированный блок «power: ...» ===
    th = c_throttle.get()
    mode = c_pmode.get()
    mode_color = ACCENT if mode == "normal" else (WARN if mode == "saver" else MUTED)
    mhz = c_cpu_max.get()
    w = c_watts.get()

    pieces = []
    if th and th[0] == "NOW":
        pieces.append(F_SMALL.render("⚡", True, ERROR))
    pieces.append(F_SMALL.render("power:", True, MUTED))
    if mode and mode != "unknown":
        pieces.append(F_SMALL.render(mode, True, mode_color))
    if mhz is not None:
        pieces.append(F_SMALL.render(f"{mhz:.1f}GHz", True, MUTED))
    if w is not None:
        pieces.append(F_SMALL.render(f"{w}W", True, MUTED))

    GAP = 5
    total_w = sum(p.get_width() for p in pieces) + GAP * (len(pieces) - 1)
    bx = (SCREEN_W - total_w) // 2
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
PAGE_SERVICES       = "services"
PAGE_NAS_STATUS     = "nas_status"
PAGE_DAILY_SUMMARY  = "daily_summary"
PAGE_CONFIGS        = "configs"
PAGE_DOCKER         = "docker"

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
    """AP MODE card — заменяет network когда мы в AP-режиме."""
    inner = _card(rect, "AP MODE — connect to setup WiFi", WARN,
                  bg=PANEL_WARN, border=WARN)
    # comitup создаёт AP с именем <hostname>-XXXX (где XXXX = первые 4
    # символа hash или MAC, зависит от версии). Берём текущий hostname.
    ap_name = f"{socket.gethostname()}-XXXX"
    screen.blit(F_MED.render(ap_name, True, FG), (inner.x, inner.y))
    screen.blit(F_SMALL.render("open network · no password", True, MUTED), (inner.x, inner.y + 24))
    screen.blit(F_SMALL.render("then open: http://10.41.0.1", True, INFO), (inner.x, inner.y + 42))


def _card_storage(rect):
    inner = _card(rect, "STORAGE  T7")
    disk = c_disk.get()
    t7t = c_t7_temp.get()
    if not disk:
        screen.blit(F_MED.render("not mounted", True, ERROR), (inner.x, inner.y))
        return
    col = ACCENT if disk["pct"] < 80 else (WARN if disk["pct"] < 90 else ERROR)

    # Главная строка: used / total | t°C
    main = F_MED.render(f"{disk['used']} / {disk['total']}", True, FG)
    screen.blit(main, (inner.x, inner.y))
    right_parts = []
    if t7t: right_parts.append(f"{t7t}°C")
    right_parts.append(f"{disk['avail']} free")
    rt = F_SMALL.render(" · ".join(right_parts), True, MUTED)
    screen.blit(rt, (inner.right - rt.get_width(), inner.y + 4))

    # Бар + % внутри
    bar_y = inner.bottom - 14
    draw_bar(inner.x, bar_y, inner.w, 12, disk["pct"], col)
    pct = F_TINY.render(f"{disk['pct']}%", True, BG if disk['pct'] > 12 else FG)
    screen.blit(pct, (inner.x + 6, bar_y))


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
            (_card_ap if in_ap else _card_network,  80 if in_ap else 66),
            (lambda r: _card_backup_progress(r, p), 84),
            (_card_storage,                         68),
            (_card_system,                        110),
        ]
    else:
        cards = [
            (_card_ap if in_ap else _card_network,  82 if in_ap else 68),
            (_card_storage,                         74),
            (_card_system,                        124),
            (_card_last_backup,                     62),
        ]

    # Распределяем gap'ы — оставляем мелкие зазоры, без растягивания
    for draw_fn, h in cards:
        rect = pygame.Rect(margin, y, card_w, h)
        draw_fn(rect)
        # Если progress-карточка — кликается → открывает детали
        if draw_fn.__name__ == "<lambda>":
            btns.append(Btn("", "progress_open", rect, ACCENT))
        y += h + gap

    # Footer: SMB-клиенты + uptime + clock — не основная информация, мелко
    smb = c_smb.get() or 0
    up = c_uptime.get() or "?"
    foot = [f"up {up}"]
    if smb > 0: foot.append(f"{smb} smb")
    screen.blit(F_TINY.render("  ·  ".join(foot), True, MUTED), (margin + 4, bottom_btn_y - 14))

    # Bottom buttons
    half_w = (SCREEN_W - 24) // 2
    menu = Btn("Menu",    "open_menu",    pygame.Rect(8, bottom_btn_y, half_w, 46),                ACCENT, primary=True)
    ap   = Btn("AP info", "open_ap_info", pygame.Rect(8 + half_w + 8, bottom_btn_y, half_w, 46),   INFO)
    draw_button(menu); draw_button(ap)
    btns += [menu, ap]
    return btns


def page_menu():
    """Меню разбито на 3 секции (NAS / INFO / SYSTEM) с заголовками-капсами
    и цветной полоской — чтобы понятно было что к чему относится."""
    screen.fill(BG)
    y = draw_top_strip("Menu")
    y += 6
    btns = []

    margin   = 8
    full_w   = SCREEN_W - margin * 2
    half_w   = (SCREEN_W - margin * 2 - 10) // 2
    btn_h    = 44
    gap_row  = 6
    sect_h   = 16

    def section(title, color):
        nonlocal y
        screen.blit(F_SMALL.render(title, True, color), (margin, y))
        pygame.draw.line(screen, color,
                         (margin, y + 14), (SCREEN_W - margin, y + 14), 1)
        y += sect_h

    def row_full(label, action, color, primary=False):
        nonlocal y
        r = pygame.Rect(margin, y, full_w, btn_h)
        b = Btn(label, action, r, color, primary=primary)
        btns.append(b); draw_button(b)
        y += btn_h + gap_row

    def row_pair(l1, a1, c1, l2, a2, c2):
        nonlocal y
        r1 = pygame.Rect(margin, y, half_w, btn_h)
        r2 = pygame.Rect(SCREEN_W - margin - half_w, y, half_w, btn_h)
        b1 = Btn(l1, a1, r1, c1); b2 = Btn(l2, a2, r2, c2)
        btns.extend([b1, b2])
        draw_button(b1); draw_button(b2)
        y += btn_h + gap_row

    # === NAS BACKUP ===
    section("NAS BACKUP", ACCENT)
    row_full("Run", "nas_run", ACCENT, primary=True)
    row_pair("Dry-run", "nas_dry",  INFO,
             "Diff",    "nas_diff", INFO)

    # === INFO & STATUS ===
    section("INFO & STATUS", INFO)
    row_pair("NAS status", "open_nas_status", INFO,
             "Today",      "open_daily",      INFO)
    row_pair("Logs",       "open_logs",       INFO,
             "Services",   "open_services",   INFO)
    row_pair("Configs",    "open_configs",    INFO,
             "Docker",     "open_docker",     INFO)

    # === SYSTEM ===
    section("SYSTEM", WARN)
    row_pair("AP info",    "open_ap_info",    INFO,
             "Force AP",   "open_ap_confirm", WARN)
    row_pair("Reboot",     "open_reboot",     WARN,
             "Shutdown",   "open_off",        ERROR)

    # Bottom row: Back | Exit to desktop
    bot_y = SCREEN_H - btn_h - 8
    back = Btn("Back", "back_to_status",
               pygame.Rect(margin, bot_y, half_w, btn_h), MUTED)
    exit_b = Btn("Exit to desktop", "exit_to_desktop",
                 pygame.Rect(SCREEN_W - margin - half_w, bot_y, half_w, btn_h), MUTED)
    draw_button(back); draw_button(exit_b)
    btns.extend([back, exit_b])
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

    rows = [
        ("Files", f"{p.get('files_done', 0)} / {p.get('files_total', 0)}"),
        ("Size",  f"{p.get('size_done', '?')} / {p.get('size_total', '?')}"),
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

    half_w = (SCREEN_W - 24) // 2
    pause = Btn(
        "Resume" if state.get("log_paused") else "Pause",
        "toggle_log_pause",
        pygame.Rect(8, SCREEN_H - 54, half_w, 46), INFO,
    )
    back = Btn("Back", "open_logs",
               pygame.Rect(8 + half_w + 8, SCREEN_H - 54, half_w, 46), MUTED)
    draw_button(pause); draw_button(back)
    return [pause, back]


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
            else:
                dot_color = MUTED
                status_label = "never"

            # Точка статуса + имя модуля
            pygame.draw.circle(screen, dot_color, (16, y + 9), 5)
            screen.blit(F_NORMAL.render(name, True, FG), (28, y))
            # Размер справа
            ss = F_NORMAL.render(size, True, FG if ex else MUTED)
            screen.blit(ss, (SCREEN_W - ss.get_width() - 10, y))
            # Подстрока: last_run + status
            sub = f"{_ago(last_run)}  ·  {status_label}"
            screen.blit(F_SMALL.render(sub, True, MUTED), (28, y + 20))
            y += row_h

    # Buttons: Refresh | Back
    half_w = (SCREEN_W - 28) // 2
    refresh = Btn("Refresh", "nas_status_refresh",
                  pygame.Rect(8, SCREEN_H - 54, half_w, 46), INFO)
    back    = Btn("Back",    "open_menu",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), MUTED)
    draw_button(refresh); draw_button(back)
    return [refresh, back]


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
    refresh = Btn("Refresh", "daily_refresh",
                  pygame.Rect(8, SCREEN_H - 54, half_w, 46), INFO)
    back    = Btn("Back",    "open_menu",
                  pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), MUTED)
    draw_button(refresh); draw_button(back)
    return [refresh, back]


def page_services():
    screen.fill(BG)
    y = draw_top_strip("Services")
    y += 8

    items = load_services()
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

    # Compute per-row height so list fills available space evenly
    bottom_btn_y = SCREEN_H - 60
    available = bottom_btn_y - y - 8
    n = max(1, len(items))
    # Минимум 44px на запись (заголовок 18 + url 16 + воздух)
    row_h = max(44, min(60, available // n))

    for name, url in items:
        # Имя сервиса
        screen.blit(F_NORMAL.render(name, True, INFO), (10, y))
        # URL под именем (или обрезка если очень длинный)
        u = url
        if len(u) > 38: u = u[:36] + "…"
        screen.blit(F_SMALL.render(u, True, FG), (18, y + 20))
        y += row_h

    back = Btn("Back", "open_menu",
               pygame.Rect(8, SCREEN_H - 54, SCREEN_W - 16, 46), MUTED)
    draw_button(back); return [back]


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

    # Bottom: Refresh | Back
    half_w = (SCREEN_W - 28) // 2
    refresh = Btn("Refresh", "docker_refresh",
                  pygame.Rect(8, SCREEN_H - 54, half_w, 46), INFO)
    back = Btn("Back", "open_menu",
               pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), MUTED)
    draw_button(refresh); draw_button(back)
    btns.extend([refresh, back])
    return btns


def page_configs():
    """Шпаргалка где что лежит — чтоб не забыть перед перепрошивкой."""
    screen.fill(BG)
    y = draw_top_strip("Configs")
    y += 6

    confs = [
        ("/etc/travel-nas/tg-notify.conf",    "Telegram bot token"),
        ("/etc/travel-nas/nas-backup.conf",   "NAS host + password"),
        ("/etc/travel-nas/services.conf",     "Dashboard URL list"),
        ("/etc/travel-nas/power-mode.conf",   "Home WiFi SSIDs"),
        ("/etc/travel-nas/photo-backup.conf", "USB backup settings"),
        ("/etc/travel-nas/t7-info.conf",      "T7 UUID (auto)"),
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

    # Bottom: Backup now | Back
    half_w = (SCREEN_W - 28) // 2
    backup_btn = Btn("Backup now", "pi_backup_now",
                     pygame.Rect(8, SCREEN_H - 54, half_w, 46), ACCENT)
    back = Btn("Back", "open_menu",
               pygame.Rect(SCREEN_W - 8 - half_w, SCREEN_H - 54, half_w, 46), MUTED)
    draw_button(backup_btn); draw_button(back)
    return [backup_btn, back]


def page_ap_info():
    screen.fill(BG)
    y = draw_top_strip("AP info")
    y += 8
    screen.blit(F_LARGE.render("AP Mode", True, WARN), (8, y)); y += 32

    cs = c_comitup.get()
    if cs:
        col = ACCENT if cs.upper() in ("CONNECTED", "CONNECTING") else WARN
        screen.blit(F_SMALL.render(f"comitup: {cs}", True, col), (8, y)); y += 18

    # comitup создаёт AP с именем <hostname>-XXXX (где XXXX = первые 4
    # символа hash или MAC, зависит от версии). Берём текущий hostname.
    ap_name = f"{socket.gethostname()}-XXXX"
    screen.blit(F_SMALL.render("WiFi network:", True, MUTED), (8, y)); y += 16
    screen.blit(F_MED.render(ap_name, True, FG), (8, y)); y += 30

    screen.blit(F_SMALL.render("Password:", True, MUTED), (8, y)); y += 16
    screen.blit(F_NORMAL.render("(open network)", True, FG), (8, y)); y += 26

    ip = c_ip.get() or "10.41.0.1"
    screen.blit(F_SMALL.render("Connect to AP, then:", True, MUTED), (8, y)); y += 16
    screen.blit(F_SMALL.render("Setup WiFi: http://10.41.0.1", True, FG), (8, y)); y += 16
    if not (ip and ip.startswith("10.41.")):
        screen.blit(F_SMALL.render(f"Current IP: {ip}", True, MUTED), (8, y)); y += 16
    screen.blit(F_SMALL.render(f"Web:  http://{ip}", True, FG), (8, y)); y += 16
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
            "Deletes current WiFi",
            "and starts comitup AP.",
            "",
            "WiFi password will be",
            "forgotten — re-enter via",
            "captive portal:",
            f"  {socket.gethostname()}-XXXX",
            "  http://10.41.0.1",
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
    PAGE_SERVICES:       page_services,
    PAGE_NAS_STATUS:     page_nas_status,
    PAGE_DAILY_SUMMARY:  page_daily_summary,
    PAGE_CONFIGS:        page_configs,
    PAGE_DOCKER:         page_docker,
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
    elif action == "open_services":     go(PAGE_SERVICES)
    elif action == "exit_to_desktop":
        # Постим QUIT — main loop корректно остановится, pygame.quit() в конце.
        # Пользователь вернётся через Desktop ярлык "Travel-NAS Dashboard".
        pygame.event.post(pygame.event.Event(pygame.QUIT))
        toast("Exiting to desktop…", MUTED)
    elif action == "open_nas_status":   go(PAGE_NAS_STATUS)
    elif action == "open_daily":        go(PAGE_DAILY_SUMMARY)
    elif action == "open_configs":      go(PAGE_CONFIGS)
    elif action == "open_docker":       go(PAGE_DOCKER)
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
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/nas-backup-status.py"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        toast("Refreshing NAS status…", INFO)
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
    elif action == "progress_open":     go(PAGE_PROGRESS)

    elif action == "do_force_ap":
        # Документированный (см. comitup-cli.8) способ переключения в HOTSPOT:
        # `comitup-cli d` — удаляет текущий NM-connection профиль; comitup
        # daemon ловит это через D-Bus и тут же стартует AP.
        # Destructive: пароль домашнего WiFi пропадёт из NetworkManager,
        # юзер перезаходит через captive portal на 10.41.0.1.
        if not Path("/usr/bin/comitup-cli").exists():
            toast("comitup not installed", ERROR)
        else:
            subprocess.Popen(
                ["sudo", "-n", "/usr/bin/comitup-cli", "d"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL, start_new_session=True,
            )
            toast("Dropping WiFi → AP… (5-15 сек)", WARN)
            go(PAGE_STATUS)
    elif action == "do_reboot":
        subprocess.Popen(["sudo", "-n", "/usr/bin/systemctl", "reboot"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        toast("Rebooting…", WARN); go(PAGE_STATUS)
    elif action == "do_shutdown":
        subprocess.Popen(["sudo", "-n", "/usr/bin/systemctl", "poweroff"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, start_new_session=True)
        toast("Shutting down…", ERROR); go(PAGE_STATUS)

    elif action == "nas_run":   _spawn_nas("--run",     "NAS backup started", ACCENT)
    elif action == "nas_dry":   _spawn_nas("--dry-run", "Dry-run started",    INFO)
    elif action == "nas_diff":  _spawn_nas("--diff",    "Diff started",       INFO)


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

        # Auto-sleep (не во время бэкапа)
        # Не гасим экран если:
        #  - идёт backup (progress JSON активный)
        #  - или просто rsync бежит (даже без нашего writer'а)
        if (display_on
                and (now - last_activity) > SLEEP_AFTER_SEC
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
