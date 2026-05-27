#!/usr/bin/env python3
# =============================================================================
# travel-nas-display.py - Dashboard для MHS35 (480x320 touch)
# =============================================================================
# Полноэкранное приложение на Pygame для экрана MHS35.
# Показывает статус travel-NAS, переключается в режим progress при backup,
# отображает AP-mode когда нет WiFi, имеет кнопки запуска скриптов.
# Auto-sleep подсветки через 5 минут.
#
# State читается из JSON-файлов в /var/run/travel-nas/.
# Скрипты backup'а пишут туда свой прогресс.
# =============================================================================

import os
import sys
import json
import time
import socket
import subprocess
import pygame
from pathlib import Path
from datetime import datetime

# === Configuration ===
SCREEN_W, SCREEN_H = 480, 320
FPS = 10  # обновление UI

STATE_DIR = Path("/var/run/travel-nas")
STATE_DIR.mkdir(parents=True, exist_ok=True)
STATE_FILE = STATE_DIR / "state.json"
PROGRESS_FILE = STATE_DIR / "backup-progress.json"

T7_MOUNT = "/mnt/t7"
SLEEP_AFTER_SEC = 300  # 5 минут auto-sleep

# Colors (Material Design dark)
BG = (18, 18, 18)
FG = (235, 235, 235)
ACCENT = (76, 175, 80)        # green
WARN = (255, 152, 0)          # orange
ERROR = (244, 67, 54)         # red
INFO = (33, 150, 243)         # blue
MUTED = (100, 100, 100)
BTN_BG = (40, 40, 40)
BTN_ACTIVE = (60, 60, 60)

FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# === Setup ===
os.environ.setdefault("SDL_FBDEV", "/dev/fb0")
os.environ.setdefault("SDL_VIDEODRIVER", "fbcon")
os.environ.setdefault("SDL_NOMOUSE", "0")

pygame.init()
pygame.mouse.set_visible(False)

try:
    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H), pygame.FULLSCREEN)
except pygame.error:
    # Fallback на windowed для отладки
    screen = pygame.display.set_mode((SCREEN_W, SCREEN_H))

clock = pygame.time.Clock()
last_activity = time.time()
display_on = True


def load_font(size, bold=False):
    path = FONT_BOLD if bold else FONT_PATH
    if not Path(path).exists():
        return pygame.font.Font(None, size)
    return pygame.font.Font(path, size)


F_LARGE = load_font(28, bold=True)
F_MED = load_font(20, bold=True)
F_NORMAL = load_font(16)
F_SMALL = load_font(13)
F_TINY = load_font(11)


# === System info helpers ===

def get_cpu_temp():
    try:
        out = subprocess.check_output(["vcgencmd", "measure_temp"], timeout=2).decode()
        return int(float(out.split("=")[1].split("'")[0]))
    except Exception:
        return None


def get_t7_temp():
    try:
        device = subprocess.check_output(
            ["findmnt", "-n", "-o", "SOURCE", T7_MOUNT], timeout=2
        ).decode().strip()
        if not device:
            return None
        device = device.rstrip("0123456789")
        out = subprocess.check_output(
            ["sudo", "smartctl", "-a", "-d", "sat", device], timeout=5
        ).decode()
        for line in out.splitlines():
            if "Temperature" in line:
                parts = line.split()
                for p in parts:
                    if p.isdigit() and 10 < int(p) < 100:
                        return int(p)
        return None
    except Exception:
        return None


def get_disk_info():
    try:
        out = subprocess.check_output(
            ["df", "-h", "--output=used,size,pcent", T7_MOUNT], timeout=2
        ).decode().splitlines()
        if len(out) >= 2:
            parts = out[1].split()
            return {"used": parts[0], "total": parts[1], "pct": parts[2].rstrip("%")}
    except Exception:
        pass
    return None


def get_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def get_ssid():
    try:
        out = subprocess.check_output(["iwgetid", "-r"], timeout=2).decode().strip()
        return out if out else None
    except Exception:
        return None


def is_ap_mode():
    """Проверяет работает ли Comitup AP-режим."""
    try:
        ip = get_ip()
        # Comitup использует подсеть 10.41.0.0/24
        if ip and ip.startswith("10.41."):
            return True
        # Или нет SSID вообще
        if not get_ssid():
            return True
    except Exception:
        pass
    return False


def get_last_photo_backup():
    """Возвращает последний бэкап фоток."""
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
    # Считаем файлы
    try:
        files_count = sum(1 for _ in latest.rglob("*") if _.is_file())
    except Exception:
        files_count = 0
    return {
        "date": latest_date.name,
        "name": latest.name,
        "files": files_count,
    }


def get_uptime():
    try:
        with open("/proc/uptime") as f:
            secs = float(f.read().split()[0])
        d = int(secs // 86400)
        h = int((secs % 86400) // 3600)
        m = int((secs % 3600) // 60)
        if d > 0:
            return f"{d}d {h}h"
        if h > 0:
            return f"{h}h {m}m"
        return f"{m}m"
    except Exception:
        return "?"


def get_progress():
    """Читает текущий прогресс бэкапа из JSON."""
    if not PROGRESS_FILE.exists():
        return None
    try:
        with open(PROGRESS_FILE) as f:
            data = json.load(f)
        # Если файл старше 60 сек — не показываем
        if time.time() - data.get("updated", 0) > 60:
            PROGRESS_FILE.unlink()
            return None
        return data
    except Exception:
        return None


# === Backlight control ===

def set_backlight(on: bool):
    """Включает/выключает подсветку через vcgencmd."""
    global display_on
    if on == display_on:
        return
    try:
        subprocess.run(
            ["vcgencmd", "display_power", "1" if on else "0"],
            timeout=2, capture_output=True
        )
        display_on = on
    except Exception:
        pass


# === Rendering ===

def draw_status_screen():
    screen.fill(BG)

    # Header
    pygame.draw.rect(screen, (30, 30, 30), (0, 0, SCREEN_W, 36))
    title = F_MED.render("🎒 Travel-NAS", True, FG)
    screen.blit(title, (12, 6))

    # Time
    now = datetime.now().strftime("%H:%M")
    t_surf = F_MED.render(now, True, FG)
    screen.blit(t_surf, (SCREEN_W - t_surf.get_width() - 12, 6))

    # Network
    y = 50
    ip = get_ip()
    ssid = get_ssid()
    if ip:
        net_color = ACCENT
        if ip.startswith("10.41."):
            net_text = f"📡 AP MODE  ·  {ip}"
            net_color = WARN
        else:
            net_text = f"📡 {ssid or 'eth'}  ·  {ip}"
    else:
        net_text = "📡 No network"
        net_color = ERROR
    surf = F_NORMAL.render(net_text, True, net_color)
    screen.blit(surf, (12, y))
    y += 28

    # Disk
    disk = get_disk_info()
    if disk:
        disk_pct = int(disk["pct"])
        disk_color = ACCENT if disk_pct < 80 else (WARN if disk_pct < 90 else ERROR)
        text = f"💾 T7: {disk['used']} / {disk['total']}  ({disk['pct']}%)"
    else:
        text = "💾 T7: not mounted"
        disk_color = ERROR
        disk_pct = 0
    surf = F_NORMAL.render(text, True, disk_color)
    screen.blit(surf, (12, y))
    y += 22
    # Progress bar
    bar_x, bar_w = 12, SCREEN_W - 24
    pygame.draw.rect(screen, BTN_BG, (bar_x, y, bar_w, 8), border_radius=4)
    fill_w = int(bar_w * disk_pct / 100)
    pygame.draw.rect(screen, disk_color, (bar_x, y, fill_w, 8), border_radius=4)
    y += 24

    # Temperatures
    cpu_t = get_cpu_temp()
    t7_t = get_t7_temp()
    cpu_color = ACCENT if (cpu_t or 0) < 65 else (WARN if cpu_t < 75 else ERROR)
    t7_color = ACCENT if (t7_t or 0) < 55 else (WARN if (t7_t or 0) < 65 else ERROR)
    cpu_text = F_NORMAL.render(f"🌡  Pi: {cpu_t or '?'}°C", True, cpu_color)
    t7_text = F_NORMAL.render(f"T7: {t7_t or '?'}°C", True, t7_color)
    screen.blit(cpu_text, (12, y))
    screen.blit(t7_text, (160, y))
    uptime_text = F_NORMAL.render(f"⏱  {get_uptime()}", True, FG)
    screen.blit(uptime_text, (320, y))
    y += 28

    # Last photo backup
    last = get_last_photo_backup()
    if last:
        text = F_NORMAL.render("📷 Last photo backup:", True, INFO)
        screen.blit(text, (12, y))
        y += 20
        sub = F_SMALL.render(f"   {last['date']}  ·  {last['name']}", True, FG)
        screen.blit(sub, (12, y))
        y += 16
        files = F_SMALL.render(f"   {last['files']} files", True, MUTED)
        screen.blit(files, (12, y))
        y += 20
    else:
        text = F_NORMAL.render("📷 No backups yet", True, MUTED)
        screen.blit(text, (12, y))
        y += 28

    # Buttons (bottom)
    btn_y = SCREEN_H - 50
    btn_w = (SCREEN_W - 40) // 3
    btn_h = 40
    btns = [
        ("NAS backup", "nas_backup", ACCENT),
        ("Logs", "logs", INFO),
        ("Refresh", "refresh", FG),
    ]
    button_rects = {}
    for i, (label, action, color) in enumerate(btns):
        x = 10 + i * (btn_w + 10)
        rect = pygame.Rect(x, btn_y, btn_w, btn_h)
        pygame.draw.rect(screen, BTN_BG, rect, border_radius=6)
        pygame.draw.rect(screen, color, rect, 2, border_radius=6)
        text = F_NORMAL.render(label, True, FG)
        text_rect = text.get_rect(center=rect.center)
        screen.blit(text, text_rect)
        button_rects[action] = rect

    return button_rects


def draw_progress_screen(progress):
    screen.fill(BG)

    # Header
    title = F_LARGE.render("📷 Backing up...", True, ACCENT)
    screen.blit(title, (12, 12))

    # Device info
    y = 60
    device = progress.get("device", "?")
    label = progress.get("label", "")
    surf = F_MED.render(f"{label or device}", True, FG)
    screen.blit(surf, (12, y))
    y += 32

    # Progress bar (big)
    pct = progress.get("percent", 0)
    bar_x = 12
    bar_y = y
    bar_w = SCREEN_W - 24
    bar_h = 32
    pygame.draw.rect(screen, BTN_BG, (bar_x, bar_y, bar_w, bar_h), border_radius=8)
    fill_w = int(bar_w * pct / 100)
    pygame.draw.rect(screen, ACCENT, (bar_x, bar_y, fill_w, bar_h), border_radius=8)

    pct_text = F_MED.render(f"{pct}%", True, FG)
    pct_rect = pct_text.get_rect(center=(SCREEN_W // 2, bar_y + bar_h // 2))
    screen.blit(pct_text, pct_rect)

    y += 50

    # Stats
    files_done = progress.get("files_done", 0)
    files_total = progress.get("files_total", 0)
    speed = progress.get("speed", "?")
    eta = progress.get("eta", "?")
    size_done = progress.get("size_done", "?")
    size_total = progress.get("size_total", "?")

    stats = [
        f"Files: {files_done} / {files_total}",
        f"Size:  {size_done} / {size_total}",
        f"Speed: {speed}",
        f"ETA:   {eta}",
    ]
    for line in stats:
        surf = F_NORMAL.render(line, True, FG)
        screen.blit(surf, (12, y))
        y += 22

    # Target path
    y = SCREEN_H - 30
    target = progress.get("target", "")
    if target:
        surf = F_TINY.render(target, True, MUTED)
        screen.blit(surf, (12, y))


def draw_ap_screen():
    screen.fill(BG)

    title = F_LARGE.render("📡 AP Mode", True, WARN)
    screen.blit(title, (12, 12))

    sub = F_NORMAL.render("WiFi setup required", True, MUTED)
    screen.blit(sub, (12, 50))

    # Try to get Comitup info
    try:
        out = subprocess.check_output(["comitup-cli", "i"], timeout=3).decode()
        # Парсим примитивно
        lines = out.split("\n")
    except Exception:
        lines = []

    y = 90
    info_lines = [
        f"WiFi: travel-nas-{socket.gethostname()[-4:]}",
        "Password: (open / 12345678)",
        "",
        f"Web: http://{get_ip() or '10.41.0.1'}",
        f"SSH: ssh oleg@{get_ip() or '10.41.0.1'}",
    ]
    for line in info_lines:
        surf = F_NORMAL.render(line, True, FG)
        screen.blit(surf, (12, y))
        y += 26


# === Touch / click handling ===

def handle_click(pos, button_rects):
    global last_activity
    last_activity = time.time()
    if not display_on:
        set_backlight(True)
        return None

    for action, rect in button_rects.items():
        if rect.collidepoint(pos):
            return action
    return None


def run_action(action):
    if action == "nas_backup":
        subprocess.Popen(
            ["lxterminal", "-e", "sudo /usr/local/bin/nas-backup.sh"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    elif action == "logs":
        subprocess.Popen(
            ["lxterminal", "-e", "tail -F /mnt/t7/_logs/photo-backup.log"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
    elif action == "refresh":
        pass  # просто перерисовать


# === Main loop ===

def main():
    global last_activity
    last_refresh = 0
    REFRESH_INTERVAL = 5

    button_rects = {}
    running = True

    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.MOUSEBUTTONDOWN:
                action = handle_click(event.pos, button_rects)
                if action:
                    run_action(action)
                    last_refresh = 0  # принудительно обновить
            elif event.type == pygame.FINGERDOWN:
                pos = (int(event.x * SCREEN_W), int(event.y * SCREEN_H))
                action = handle_click(pos, button_rects)
                if action:
                    run_action(action)
                    last_refresh = 0
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    running = False
                last_activity = time.time()
                set_backlight(True)

        # Auto-sleep
        if display_on and (time.time() - last_activity) > SLEEP_AFTER_SEC:
            # Не уходим в sleep если идёт backup
            if get_progress() is None:
                set_backlight(False)
                screen.fill((0, 0, 0))
                pygame.display.flip()

        # Refresh
        if display_on and (time.time() - last_refresh) > REFRESH_INTERVAL:
            last_refresh = time.time()

            progress = get_progress()
            if progress:
                # Принудительно включаем подсветку во время backup
                set_backlight(True)
                last_activity = time.time()
                draw_progress_screen(progress)
                button_rects = {}
            elif is_ap_mode():
                draw_ap_screen()
                button_rects = {}
            else:
                button_rects = draw_status_screen()

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
        with open("/var/log/travel-nas-display.error.log", "a") as f:
            f.write(f"[{datetime.now()}] {e}\n")
            f.write(traceback.format_exc())
        raise
