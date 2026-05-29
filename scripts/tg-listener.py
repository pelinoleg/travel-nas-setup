#!/usr/bin/env python3
# =============================================================================
# tg-listener.py — Telegram bot для управления travel-NAS
# =============================================================================
# Long-polling via getUpdates. Slim: только stdlib + requests.
#
# Команды:
#   /status     снимок (uptime, T7, CPU, бэкапы сегодня, режим питания)
#   /backup     запустить NAS backup
#   /backup dry dry-run
#   /logs [N]   последние N строк всех логов на T7 (default 30)
#   /reboot     перезагрузка Pi (с подтверждением)
#   /shutdown   выключение Pi (с подтверждением)
#   /power MODE home/field/emergency/auto
#   /help       список команд
#
# Авторизация: chat_id из /etc/travel-nas/tg-notify.conf.
# Запросы от других chat_id игнорируются.
#
# Systemd unit: tg-listener.service (запускается как oleg, restart=always).
# =============================================================================

import os
import re
import json
import socket
import sys
import time
import subprocess
import urllib.request
import urllib.parse
import urllib.error
from pathlib import Path

CONFIG = Path("/etc/travel-nas/tg-notify.conf")
DAILY_SUMMARY_JSON = Path("/var/lib/travel-nas/daily-summary.json")
NAS_STATUS_JSON    = Path("/var/lib/travel-nas/nas-backup-status.json")
POWER_MODE_FILE    = Path("/var/lib/travel-nas/power-mode.txt")
POWER_PREF_FILE    = Path("/var/lib/travel-nas/power-mode-pref")
OFFSET_FILE        = Path("/var/lib/travel-nas/tg-listener.offset")
T7_LOGS            = Path("/mnt/t7/_logs")

# Pending confirmations: {chat_id: (action, expires_ts)}
pending = {}
CONFIRM_TTL = 30  # seconds


def load_config():
    """Парсим bash-стиль конфиг через regex (без source)."""
    if not CONFIG.exists():
        print(f"ERROR: {CONFIG} not found. Run travel-nas-setup first.", file=sys.stderr)
        sys.exit(1)
    text = CONFIG.read_text()
    def get(key):
        m = re.search(rf'^\s*{key}="?([^"\n]*)"?', text, re.M)
        return m.group(1).strip() if m else ""
    token = get("TG_BOT_TOKEN")
    chat_id = get("TG_CHAT_ID")
    if not token or not chat_id:
        print("ERROR: TG_BOT_TOKEN/TG_CHAT_ID empty in tg-notify.conf", file=sys.stderr)
        sys.exit(1)
    return token, chat_id


def tg_request(token, method, params=None, timeout=35):
    """POST на Telegram API. Возвращает dict или None."""
    url = f"https://api.telegram.org/bot{token}/{method}"
    data = urllib.parse.urlencode(params or {}).encode() if params else None
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        print(f"HTTPError {e.code}: {body}", file=sys.stderr)
    except (urllib.error.URLError, TimeoutError, ConnectionResetError) as e:
        print(f"Network error: {e}", file=sys.stderr)
    return None


def send_photo(token, chat_id, photo_path, caption=""):
    """Telegram sendPhoto через multipart/form-data. Без requests (stdlib only)."""
    boundary = "----TG" + os.urandom(8).hex()
    body = []
    def field(name, value):
        body.append(f"--{boundary}\r\n".encode())
        body.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.append(f"{value}\r\n".encode())
    field("chat_id", str(chat_id))
    if caption:
        field("caption", caption[:1000])
    body.append(f"--{boundary}\r\n".encode())
    body.append(b'Content-Disposition: form-data; name="photo"; filename="dashboard.png"\r\n')
    body.append(b'Content-Type: image/png\r\n\r\n')
    with open(photo_path, "rb") as f:
        body.append(f.read())
    body.append(b"\r\n")
    body.append(f"--{boundary}--\r\n".encode())
    data = b"".join(body)
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendPhoto",
        data=data,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"sendPhoto HTTPError {e.code}: {e.read().decode(errors='replace')}", file=sys.stderr)
    except (urllib.error.URLError, TimeoutError, ConnectionResetError) as e:
        print(f"sendPhoto network error: {e}", file=sys.stderr)
    return None


def send_kbd(token, chat_id, text, keyboard, parse_mode="Markdown"):
    """sendMessage с inline-клавиатурой.
    keyboard: список рядов, каждый ряд — list of (label, callback_data)."""
    rows = [[{"text": l, "callback_data": d} for l, d in row] for row in keyboard]
    payload = {
        "chat_id": chat_id,
        "text": text[:4000],
        "parse_mode": parse_mode,
        "reply_markup": json.dumps({"inline_keyboard": rows}),
    }
    res = tg_request(token, "sendMessage", payload)
    if not res or not res.get("ok"):
        # Fallback без parse_mode (как у обычного send)
        payload.pop("parse_mode", None)
        res = tg_request(token, "sendMessage", payload)
    return res


def send(token, chat_id, text, parse_mode="Markdown"):
    """Отправить сообщение. Если Markdown не парсится — fallback в plain text
    чтобы юзер хотя бы что-то увидел (а не "бот молчит")."""
    text = text[:4000]
    res = tg_request(token, "sendMessage", {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": parse_mode,
    })
    if res and res.get("ok"):
        return res
    # Fallback — без parse_mode
    return tg_request(token, "sendMessage", {
        "chat_id": chat_id,
        "text": text,
    })


# === Command handlers ============================================================

def cmd_help(token, chat_id, args):
    send(token, chat_id, """*Travel-NAS bot* — все команды:

📊 *Статус*
`/status` `/today` — snapshot (uptime, CPU, T7, throttle)
`/screenshot` `/screen` — PNG-снимок текущего экрана дашборда
`/sleep` — auto-sleep таймаут (`/sleep 5m`, `/sleep never`)
`/nas` — статус NAS-бэкапов (модули, размеры, last-run)
`/docker` — Docker-compose проекты + кнопки Stop/Start/Restart
`/docker audit` — диагностика UID-mismatch в bind mount'ах
`/yt` — статус yt-archiver очереди (`/yt pause` / `/yt resume`)
`/services` — все URL установленных сервисов
`/configs` — `/etc/travel-nas/` файлы + где что лежит
`/tailscale` `/ts` — статус Tailscale VPN + peers
`/verify` — последний bit-rot/IO scrub T7 (`/verify run` чтоб запустить сейчас)
`/rotate` `/flip` — flip ориентации экрана 0°↔180° + ребут

🔄 *Действия*
`/backup` — NAS backup
`/backup dry` — dry-run NAS backup
`/backup diff` — diff с NAS (что изменится)
`/update` — быстро обновить только скрипты (~30 сек)
`/update full` — полный апдейт: скрипты + apt + docker (~5-15 мин)
`/logs [N]` — хвост всех логов (default 30 строк)

🔌 *Питание*
`/power` — справка + текущее
`/power auto` — система сама решает (A· префикс в UI)
`/power normal` `/power saver` — фиксируем ручной режим
`/power status` — что и почему сейчас

⚙️ *Система*
`/reboot` — ребут Pi (нужно /yes)
`/shutdown` — выключение (нужно /yes)
`/yes` — подтвердить pending действие (reboot/shutdown)

`/help` `/start` — это сообщение""")


def cmd_status(token, chat_id, args):
    parts = ["*Travel-NAS status*"]
    if DAILY_SUMMARY_JSON.exists():
        try:
            d = json.loads(DAILY_SUMMARY_JSON.read_text())
            up = d.get("uptime", "?")
            cpu = d.get("cpu_temp")
            t7 = d.get("t7") or {}
            ph = d.get("photo_today") or {}
            th = d.get("throttle") or {}
            parts.append(f"⏱ Up: `{up}`")
            if cpu is not None: parts.append(f"🌡 CPU: `{cpu}°C`")
            if t7.get("mounted"):
                parts.append(f"💾 T7: `{t7.get('used','?')} / {t7.get('total','?')}` ({t7.get('pct','?')}%)")
            if th.get("now"):
                parts.append("⚡ *UNDER-VOLTAGE NOW*")
            elif th.get("past"):
                parts.append("⚡ power dipped earlier today")
            if ph.get("cards", 0) > 0:
                parts.append(f"📷 today: {ph['cards']} cards, {ph['files']} files, {ph['size']}")
            inc = d.get("incomplete") or 0
            if inc:
                parts.append(f"🔶 incomplete backups: {inc}")
            sd = d.get("sd_wear_pct")
            if sd is not None:
                parts.append(f"💳 microSD wear ~{sd}%")
        except Exception as e:
            parts.append(f"(json error: {e})")
    if POWER_MODE_FILE.exists():
        try:
            applied = POWER_MODE_FILE.read_text().strip()
            pref = (POWER_PREF_FILE.read_text().strip()
                    if POWER_PREF_FILE.exists() else "auto")
            marker = "A·" if pref == "auto" else ""
            parts.append(f"🔌 power: `{marker}{applied}` (pref `{pref}`)")
        except Exception:
            pass
    send(token, chat_id, "\n".join(parts))


def cmd_backup(token, chat_id, args):
    arg = (args[0] if args else "").lower()
    if arg in ("dry", "dry-run", "--dry-run"):
        cmd = ["sudo", "-n", "/usr/local/bin/nas-backup.sh", "--dry-run"]
        label = "Dry-run started"
    elif arg in ("diff", "--diff"):
        cmd = ["sudo", "-n", "/usr/local/bin/nas-backup.sh", "--diff"]
        label = "Diff started"
    else:
        cmd = ["sudo", "-n", "/usr/local/bin/nas-backup.sh", "--run"]
        label = "NAS backup started"
    try:
        subprocess.Popen(cmd,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True)
        send(token, chat_id, f"✅ {label}")
    except Exception as e:
        send(token, chat_id, f"❌ Failed to spawn: {e}")


def cmd_logs(token, chat_id, args):
    try:
        n = int(args[0]) if args else 30
    except ValueError:
        n = 30
    n = max(5, min(200, n))
    lines = []
    if T7_LOGS.is_dir():
        for log in sorted(T7_LOGS.glob("*.log"),
                          key=lambda p: p.stat().st_mtime, reverse=True):
            try:
                tail = subprocess.check_output(
                    ["tail", f"-n{n // 4}", str(log)],
                    timeout=5, stderr=subprocess.DEVNULL,
                ).decode(errors="replace")
                lines.append(f"=== {log.name} ===\n{tail}")
            except Exception:
                continue
    text = "\n".join(lines)
    if not text.strip():
        send(token, chat_id, "_(no logs)_")
        return
    # Telegram max 4096 — режем
    send(token, chat_id, f"```\n{text[-3800:]}\n```")


def cmd_power(token, chat_id, args):
    # /power без аргументов — справка + текущее состояние
    if not args:
        try:
            cur = POWER_MODE_FILE.read_text().strip() if POWER_MODE_FILE.exists() else "unknown"
        except Exception:
            cur = "unknown"
        try:
            pref = POWER_PREF_FILE.read_text().strip() if POWER_PREF_FILE.exists() else "auto"
        except Exception:
            pref = "auto"
        marker = "A·" if pref == "auto" else ""
        send(token, chat_id, f"""*Power mode* — три режима

Pref: `{pref}` · applied: `{marker}{cur}`

🟢 `normal` — CPU ondemand (до 2.4 GHz). Ручной, не меняется сам.
🟡 `saver` — CPU powersave (зажат на min). Ручной, не меняется сам.
🔵 `auto` — система сама решает по throttle/temp (показано `A·` префиксом).

Auto-логика (при pref=auto):
• throttled-bit или CPU temp ≥ 75°C → saver
• CPU temp < 65°C AND throttle clear → normal (гистерезис 10°)

Команды:
`/power normal` — фиксируем normal
`/power saver` — фиксируем saver
`/power auto` — включаем авто-переключение
`/power status` — детально что сейчас + почему

Триггеры тика:
• NetworkManager dispatcher при connect/disconnect
• system-monitor каждые 5 мин""")
        return

    mode = args[0].lower()
    if mode not in ("normal", "saver", "auto", "status",
                    "home", "field", "emergency"):  # legacy aliases
        send(token, chat_id, "Usage: `/power [normal|saver|auto|status]`\nБез аргумента → справка")
        return
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/local/bin/power-mode.sh", mode],
            timeout=30, stderr=subprocess.STDOUT,
        ).decode(errors="replace").strip()
        send(token, chat_id, f"🔌 power-mode → `{out or mode}`")
    except subprocess.CalledProcessError as e:
        send(token, chat_id, f"❌ failed: {e.output.decode(errors='replace')[:200]}")
    except Exception as e:
        send(token, chat_id, f"❌ {e}")


def cmd_reboot(token, chat_id, args):
    pending[chat_id] = ("reboot", time.time() + CONFIRM_TTL)
    send(token, chat_id, "⚠️ Reboot? Reply `/yes` within 30s.")


def cmd_shutdown(token, chat_id, args):
    pending[chat_id] = ("shutdown", time.time() + CONFIRM_TTL)
    send(token, chat_id, "⚠️ Shutdown? Reply `/yes` within 30s.")


def cmd_yes(token, chat_id, args):
    p = pending.get(chat_id)
    if not p or p[1] < time.time():
        pending.pop(chat_id, None)
        send(token, chat_id, "Nothing to confirm.")
        return
    action, _ = pending.pop(chat_id)
    if action == "reboot":
        send(token, chat_id, "🔄 Rebooting…")
        subprocess.Popen(["sudo", "-n", "/usr/bin/systemctl", "reboot"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True)
    elif action == "shutdown":
        send(token, chat_id, "💀 Shutting down…")
        subprocess.Popen(["sudo", "-n", "/usr/bin/systemctl", "poweroff"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL, start_new_session=True)


UPDATE_LOG_PATH    = Path("/tmp/travel-nas-update.log")
UPDATE_DONE_MARKER = Path("/tmp/travel-nas-update.done")


def cmd_update(token, chat_id, args):
    """travel-nas-update в фоне (detached) — он сам себя рестартует
    через systemctl restart tg-listener в конце, поэтому ждать sync'но
    нельзя: убьёт хэндлер до того как он отправит ответ.

    Решение: запускаем detached → отправляем "Update started" → бот
    умирает → systemd поднимает новый процесс → main() читает marker
    и шлёт "✅ Update done" сразу после старта.

    Аргументы:
        (нет)   — быстрый режим (~30 сек): только наши скрипты + restart.
        full    — полный (~5-15 мин): + apt upgrade + docker compose pull/up."""
    try:
        UPDATE_LOG_PATH.write_text("")
    except Exception:
        pass
    try:
        UPDATE_DONE_MARKER.unlink()
    except Exception:
        pass

    full_mode = bool(args) and args[0].lower() in ("full", "--full", "-f")
    cmd = ["sudo", "-n", "/usr/local/bin/travel-nas-update"]
    if full_mode:
        cmd.append("--full")

    # start_new_session=True ⇒ child в своей сессии, переживёт systemctl
    # restart tg-listener (который придёт нам через SIGTERM в конце апдейта)
    log_fd = open(UPDATE_LOG_PATH, "w")
    subprocess.Popen(
        cmd,
        stdout=log_fd, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )
    if full_mode:
        send(token, chat_id, """🔄 *Full update запущен в фоне.*

Это апдейт ВСЕГО — может занять *5-15 мин*:
• скрипты из GitHub
• `apt upgrade` (включая kernel)
• `docker compose pull` + `up -d` по всем CasaOS-приложениям

Бот сам перезапустится и пришлёт итог + флаг `REBOOT_NEEDED` если нужен ребут.

Лог: `/tmp/travel-nas-update.log`""")
    else:
        send(token, chat_id, """🔄 *Update запущен в фоне.*

Только скрипты из GitHub (~20-40 сек).
Для полного апдейта (apt + docker): `/update full`

Бот сам перезапустится и пришлёт итог.
Лог: `/tmp/travel-nas-update.log`""")


def _resolve_host_ip():
    host = f"{socket.gethostname()}.local"
    try:
        ip = subprocess.check_output(["hostname", "-I"], timeout=2).decode().split()[0]
    except Exception:
        ip = "?"
    return host, ip


SERVICES_CONF_PATH = Path("/etc/travel-nas/services.conf")


def cmd_services(token, chat_id, args):
    """Список сервисов из services.conf с подстановкой {host}/{ip}."""
    if not SERVICES_CONF_PATH.exists():
        send(token, chat_id, "_services.conf не найден — запусти travel-nas-setup_")
        return
    host, ip = _resolve_host_ip()
    lines = ["*Services*", ""]
    try:
        for raw in SERVICES_CONF_PATH.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, url = line.split("=", 1)
            url = url.strip().replace("{host}", host).replace("{ip}", ip)
            lines.append(f"• *{name.strip()}* — `{url}`")
    except Exception as e:
        lines.append(f"(read error: {e})")
    send(token, chat_id, "\n".join(lines))


def cmd_configs(token, chat_id, args):
    """Список /etc/travel-nas/*.conf — что есть, что нет, плюс шпаргалка путей."""
    confs = [
        ("/etc/travel-nas/tg-notify.conf",     "Telegram bot token + chat_id"),
        ("/etc/travel-nas/nas-backup.conf",    "NAS host/user/password"),
        ("/etc/travel-nas/services.conf",      "Dashboard URLs"),
        ("/etc/travel-nas/power-mode.conf",    "Home WiFi SSIDs"),
        ("/etc/travel-nas/photo-backup.conf",  "USB backup settings"),
        ("/etc/travel-nas/t7-info.conf",       "T7 UUID (auto-generated)"),
    ]
    lines = ["*Configs* `/etc/travel-nas/`", ""]
    for path, desc in confs:
        mark = "✅" if Path(path).exists() else "❌"
        name = path.split("/")[-1]
        lines.append(f"{mark} `{name}` — {desc}")
    lines += [
        "",
        "*Where things live*",
        "• Scripts — `/usr/local/bin/*.{sh,py}`",
        "• Configs — `/etc/travel-nas/`",
        "• Systemd — `/etc/systemd/system/`",
        "• Sudoers — `/etc/sudoers.d/travel-nas-dashboard`",
        "• Runtime state — `/var/lib/travel-nas/`",
        "• Logs — `/mnt/t7/_logs/`",
        "• Pi-config backups — `/mnt/t7/pi-config-backups/`",
        "",
        "*Save before re-flash*",
        "`sudo cp -r /etc/travel-nas /mnt/t7/_etc-backup`",
    ]
    send(token, chat_id, "\n".join(lines))


NAS_STATUS_JSON_TG = Path("/var/lib/travel-nas/nas-backup-status.json")


def _ago_short(ts):
    if not ts:
        return "—"
    delta = int(time.time() - ts)
    if delta < 60:    return f"{delta}s"
    if delta < 3600:  return f"{delta // 60}m"
    if delta < 86400: return f"{delta // 3600}h"
    return f"{delta // 86400}d"


def cmd_yt(token, chat_id, args):
    """yt-archiver pause/resume всех закачек через API.
    `/yt` — статус (paused/pending/downloading/error).
    `/yt pause` — приостановить все.
    `/yt resume` — продолжить."""
    # URL из yt-archiver.conf или дефолт
    base = "http://localhost:8081"
    try:
        with open("/etc/travel-nas/yt-archiver.conf") as f:
            for ln in f:
                m = re.match(r'^\s*URL\s*=\s*["\']?([^"\'\s]+)', ln.strip())
                if m: base = m.group(1).rstrip("/"); break
    except Exception:
        pass

    if not args:
        try:
            import urllib.request
            with urllib.request.urlopen(f"{base}/api/queue/status", timeout=4) as r:
                s = json.loads(r.read())
            icon = "⏸" if s.get("paused") else "▶"
            send(token, chat_id, f"""*YT-Archiver queue* {icon}

paused:       `{s.get("paused")}`
pending:      {s.get("pending", 0)}
downloading:  {s.get("downloading", 0)}
error:        {s.get("error", 0)}
max parallel: {s.get("max_concurrent", 1)}

`/yt pause` — приостановить все
`/yt resume` — продолжить""")
        except Exception as e:
            send(token, chat_id, f"❌ yt-archiver недоступен: `{e}`")
        return

    arg = args[0].lower()
    if arg not in ("pause", "resume"):
        send(token, chat_id, "Используй `/yt`, `/yt pause`, `/yt resume`.")
        return
    try:
        import urllib.request
        req = urllib.request.Request(f"{base}/api/queue/{arg}", method="POST")
        with urllib.request.urlopen(req, timeout=5) as r:
            r.read()
        send(token, chat_id,
             f"⏸ *YT downloads paused.*" if arg == "pause"
             else f"▶ *YT downloads resumed.*")
    except Exception as e:
        send(token, chat_id, f"❌ API request failed: `{e}`")


def cmd_docker(token, chat_id, args):
    """Список compose-проектов с кнопками Stop/Start/Restart.
    `/docker audit` — диагностика прав bind mount'ов (UID-mismatch)."""
    if args and args[0].lower() == "audit":
        try:
            out = subprocess.check_output(
                ["sudo", "-n", "/usr/local/bin/docker-mgr.sh", "audit"],
                timeout=30, stderr=subprocess.STDOUT,
            ).decode(errors="replace").strip()
        except Exception as e:
            send(token, chat_id, f"❌ audit failed: {e}")
            return
        # Plain text — escape Markdown в выводе содержит chown/пути
        send(token, chat_id, f"*Docker bind-mount audit*\n```\n{out[:3500]}\n```")
        return

    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/local/bin/docker-mgr.sh", "list"],
            timeout=10, stderr=subprocess.STDOUT,
        ).decode(errors="replace")
        projects = json.loads(out)
    except Exception as e:
        send(token, chat_id, f"❌ docker list failed: {e}")
        return
    if not projects:
        send(token, chat_id, "_Нет docker-compose проектов_")
        return
    lines = ["*Docker compose projects*"]
    keyboard = []
    for p in projects:
        name = p.get("Name", "?")
        status = p.get("Status", "?")
        running = "running" in status.lower()
        emoji = "🟢" if running else "⚪"
        lines.append(f"{emoji} *{name}* — `{status}`")
        if running:
            keyboard.append([
                ("⏹ Stop",    f"docker:stop:{name}"),
                ("🔄 Restart", f"docker:restart:{name}"),
            ])
        else:
            keyboard.append([("▶️ Start", f"docker:start:{name}")])
    send_kbd(token, chat_id, "\n".join(lines), keyboard)


def handle_docker_callback(token, chat_id, data):
    """data = 'docker:<action>:<name>'"""
    try:
        _, action, name = data.split(":", 2)
    except ValueError:
        return
    if action not in ("start", "stop", "restart"):
        return
    send(token, chat_id, f"🔄 docker {action} `{name}`…")
    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/local/bin/docker-mgr.sh", action, name],
            timeout=180, stderr=subprocess.STDOUT,
        ).decode(errors="replace")
        tail = "\n".join(out.strip().split("\n")[-10:])
        send(token, chat_id, f"✅ `{name}` {action}'ed\n```\n{tail or '(no output)'}\n```")
    except subprocess.CalledProcessError as e:
        body = e.output.decode(errors="replace")[-1000:]
        send(token, chat_id, f"❌ {action} `{name}` failed:\n```\n{body}\n```")
    except subprocess.TimeoutExpired:
        send(token, chat_id, f"⏱ {action} `{name}` timeout >3 мин")


def cmd_nas(token, chat_id, args):
    """NAS backup статус — per-module: status dot, size, last-run age."""
    if not NAS_STATUS_JSON_TG.exists():
        send(token, chat_id, "_nas-backup-status.json не найден — запусти /update или подожди hourly timer_")
        return
    try:
        d = json.loads(NAS_STATUS_JSON_TG.read_text())
    except Exception as e:
        send(token, chat_id, f"json error: {e}")
        return
    lines = ["*NAS backup status*"]
    di = d.get("disk") or {}
    if di:
        lines.append(f"💾 T7: `{di.get('used','?')} / {di.get('total','?')}` ({di.get('pct','?')}%, {di.get('avail','?')} free)")
    upd = d.get("updated")
    if upd:
        lines.append(f"_updated {_ago_short(upd)} ago_")
    lines.append("")
    emoji = {"ok": "🟢", "warn": "🟡", "fail": "🔴", None: "⚪"}
    for m in d.get("modules", []):
        name = m.get("name", "?")
        if not m.get("exists"):
            lines.append(f"⚪ *{name}* — absent")
            continue
        st = m.get("status")
        size = m.get("size", "?")
        lr = m.get("last_run")
        lines.append(f"{emoji.get(st,'⚪')} *{name}* — `{size}` — {_ago_short(lr)} ago" if lr else f"{emoji.get(st,'⚪')} *{name}* — `{size}` — never")
    send(token, chat_id, "\n".join(lines))


SCREENSHOT_REQ = Path("/var/run/travel-nas/screenshot-req")
SCREENSHOT_PNG = Path("/var/run/travel-nas/dashboard.png")
SLEEP_TIMEOUT_FILE = Path("/var/lib/travel-nas/sleep-timeout")

# Пресеты sleep-таймаутов в секундах. Юзер пишет "/sleep 5m" или "/sleep never"
SLEEP_PRESETS = {
    "30s":   30,
    "1m":    60,
    "5m":    300,
    "15m":   900,
    "30m":   1800,
    "1h":    3600,
    "never": 0,
    "off":   0,
}


def _format_sleep(seconds):
    if seconds == 0:
        return "never (всегда вкл)"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h"


def cmd_sleep(token, chat_id, args):
    """Auto-sleep timeout дашборда. `/sleep` без args — текущий + пресеты.
    `/sleep 5m` или `/sleep never` — переключить."""
    if not args:
        cur = 300
        try:
            if SLEEP_TIMEOUT_FILE.exists():
                cur = int(SLEEP_TIMEOUT_FILE.read_text().strip())
        except Exception:
            pass
        preset_list = ", ".join(f"`{k}`" for k in SLEEP_PRESETS if k not in ("off",))
        send(token, chat_id, f"""*Auto-sleep экрана дашборда*

Сейчас: `{_format_sleep(cur)}`

Пресеты: {preset_list}
Или произвольное: `/sleep 120s`, `/sleep 7m`, `/sleep 2h`

`/sleep never` — экран не гаснет вовсе (для долгого мониторинга).""")
        return

    arg = args[0].lower().strip()
    if arg in SLEEP_PRESETS:
        secs = SLEEP_PRESETS[arg]
    else:
        # Парсим '120s', '5m', '2h' или просто число секунд
        m = re.match(r"^(\d+)([smh]?)$", arg)
        if not m:
            send(token, chat_id, f"❌ Не понял `{arg}`. Используй `/sleep` для справки.")
            return
        n, unit = int(m.group(1)), m.group(2)
        secs = n * {"s": 1, "m": 60, "h": 3600, "": 1}[unit]
        if secs > 86400:
            send(token, chat_id, "❌ Слишком много (> 24 часа). 0 = никогда.")
            return

    try:
        SLEEP_TIMEOUT_FILE.parent.mkdir(parents=True, exist_ok=True)
        SLEEP_TIMEOUT_FILE.write_text(str(secs))
    except Exception as e:
        send(token, chat_id, f"❌ не смог записать: {e}")
        return
    send(token, chat_id, f"💤 Auto-sleep → `{_format_sleep(secs)}`\n_(применяется в течение 5 сек)_")


def cmd_rotate(token, chat_id, args):
    """Flip MHS35 0° ↔ 180° (USB сверху ↔ USB снизу).
    `/rotate` — текущая ориентация + подсказка.
    `/rotate flip` — переключить + ребут."""
    # Текущее значение из config.txt
    cur = "?"
    try:
        with open("/boot/firmware/config.txt") as f:
            for line in f:
                m = re.search(r"dtoverlay=mhs35:rotate=(\d+)", line)
                if m:
                    cur = m.group(1)
                    break
    except Exception:
        pass

    if not args:
        next_r = "180" if cur == "0" else "0"
        send(token, chat_id, f"""*Screen rotation*

Сейчас: `{cur}°` (USB { 'сверху' if cur == '0' else 'снизу' if cur == '180' else '?' })

`/rotate flip` — переключить на `{next_r}°` + ребут.
_(применяется только после reboot — kernel-overlay)_""")
        return

    if args[0].lower() not in ("flip", "toggle"):
        send(token, chat_id, "Используй `/rotate` или `/rotate flip`.")
        return

    try:
        out = subprocess.check_output(
            ["sudo", "-n", "/usr/local/bin/screen-rotate.sh", "flip"],
            timeout=10, stderr=subprocess.STDOUT,
        ).decode()
    except Exception as e:
        send(token, chat_id, f"❌ screen-rotate.sh упал: `{e}`")
        return

    # Ребут через fast-reboot.sh (T7-aware, c SysRq-fallback'ом)
    new_r = "180" if cur == "0" else "0"
    send(token, chat_id, f"""🔄 *Rotation → `{new_r}°`*

```
{out.strip()}
```

Сейчас уйду в reboot — вернусь через ~30-60 сек. После загрузки экран будет в новой ориентации, touch уже откалиброван.""")
    try:
        subprocess.Popen(
            ["sudo", "-n", "/usr/local/bin/fast-reboot.sh"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except Exception as e:
        send(token, chat_id, f"⚠ reboot не запустился: `{e}`\nСделай вручную: `sudo reboot`")


def cmd_verify(token, chat_id, args):
    """Backup verify scrub: status или run.
    `/verify` — последний статус (JSON из /var/lib/travel-nas/verify-status.json)
    `/verify run` — запустить scrub сейчас в фоне (sudo systemctl start nas-verify.service)"""
    if args and args[0].lower() in ("run", "start", "now"):
        try:
            subprocess.run(
                ["sudo", "-n", "systemctl", "start", "--no-block", "nas-verify.service"],
                timeout=10, check=True,
            )
            send(token, chat_id, """🔍 *Verify запущен.*

Сканирует T7 (~30-60 мин на ~600GB). Алёрт придёт автоматически если что-то нашёл; иначе тишина.

Текущий прогресс смотри в `journalctl -u nas-verify.service -f` или через `/logs verify`.""")
        except Exception as e:
            send(token, chat_id, f"❌ не смог запустить: `{e}`")
        return

    p = Path("/var/lib/travel-nas/verify-status.json")
    if not p.exists():
        send(token, chat_id,
             "_Verify ни разу не запускался._\n\n"
             "`/verify run` — запустить сейчас\n"
             "Авто-запуск раз в месяц по systemd-timer (если включён модуль VERIFY).")
        return
    try:
        d = json.loads(p.read_text())
    except Exception as e:
        send(token, chat_id, f"❌ verify-status.json повреждён: `{e}`")
        return

    icon = "✅" if d.get("status") == "ok" else "🔴"
    bytes_gb = (d.get("bytes_read") or 0) / (1024 ** 3)
    elapsed_min = (d.get("elapsed_sec") or 0) // 60
    sample = "\n".join(f"  • `{p}`" for p in (d.get("bitrot_sample") or []))
    if sample:
        sample = f"\n\n*Bit-rot файлы (sample):*\n{sample}"

    send(token, chat_id, f"""*Verify status* {icon} `{d.get('status', '?')}`

Last run:    `{d.get('last_run', '?')}` ({elapsed_min} min)
Files:       {d.get('total_files', 0)} ({bytes_gb:.1f} GiB)
Added:       {d.get('added', 0)}
Deleted:     {d.get('deleted', 0)}
Changed ok:  {d.get('changed_normal', 0)}
🔴 Bit-rot:   {d.get('bitrot', 0)}
🔴 Read fail: {d.get('read_failures', 0)}
🔴 I/O dmesg: {d.get('io_errors', 0)}{sample}

`/verify run` — запустить scrub сейчас""")


def cmd_tailscale(token, chat_id, args):
    """Статус Tailscale: установлен / online / IP / magic DNS / peers.
    Без аргументов — текущий status. Аргументы зарезервированы (на будущее)."""
    if not (Path("/usr/bin/tailscale").exists() or Path("/usr/local/bin/tailscale").exists()):
        send(token, chat_id,
             "_Tailscale не установлен._\n\n"
             "Установка: `travel-nas-setup` → выбрать `TAILSCALE`, или вручную:\n"
             "`curl -fsSL https://tailscale.com/install.sh | sudo sh`")
        return
    try:
        raw = subprocess.check_output(
            ["tailscale", "status", "--json"], timeout=5,
            stderr=subprocess.STDOUT,
        ).decode()
        data = json.loads(raw)
    except Exception as e:
        send(token, chat_id, f"❌ `tailscale status` failed: `{e}`")
        return

    state = data.get("BackendState", "?")
    self_info = data.get("Self") or {}
    ips = self_info.get("TailscaleIPs") or []
    ts_ip = ips[0] if ips else "—"
    dns_name = (self_info.get("DNSName") or "").rstrip(".") or "—"
    online = state == "Running"
    peers = data.get("Peer") or {}

    # Краткий список peer'ов (макс 6 — телега не любит длинные сообщения)
    peer_lines = []
    for _key, p in list(peers.items())[:6]:
        if not isinstance(p, dict):
            continue
        nm = (p.get("HostName") or p.get("DNSName") or "?").rstrip(".")
        nm = nm.split(".")[0]  # короткое имя
        pips = p.get("TailscaleIPs") or []
        pip = pips[0] if pips else "—"
        is_online = "🟢" if p.get("Online") else "⚪"
        peer_lines.append(f"{is_online} `{nm}` — `{pip}`")
    peers_block = "\n".join(peer_lines) if peer_lines else "_(нет других устройств)_"
    if len(peers) > 6:
        peers_block += f"\n_…и ещё {len(peers) - 6}_"

    icon = "🟢" if online else "🔴"
    send(token, chat_id, f"""*Tailscale* {icon} `{state}`

*Это устройство*
IP:        `{ts_ip}`
DNS:       `{dns_name}`

*Peers* ({len(peers)}):
{peers_block}

_Через tailnet ssh:_ `ssh oleg@{dns_name.split('.')[0] if dns_name != '—' else 'travel-nas'}`""")


def cmd_screenshot(token, chat_id, args):
    """Запрашивает у dashboard'а скриншот текущего экрана и отправляет в TG.
    Механика: touch SCREENSHOT_REQ → dashboard на следующем тике main loop'а
    (≤ ~1 сек при FPS=30) сохраняет screen в SCREENSHOT_PNG и убирает флаг."""
    if not SCREENSHOT_REQ.parent.exists():
        send(token, chat_id, "❌ /var/run/travel-nas/ не существует — дашборд запущен?")
        return
    # Чтобы не отдать старый PNG: убираем стейл-файл, затем запрашиваем новый
    old_mtime = SCREENSHOT_PNG.stat().st_mtime if SCREENSHOT_PNG.exists() else 0
    SCREENSHOT_REQ.touch()
    # Ждём до 5 сек пока dashboard перепишет PNG (mtime изменится)
    deadline = time.time() + 5
    while time.time() < deadline:
        if SCREENSHOT_PNG.exists() and SCREENSHOT_PNG.stat().st_mtime > old_mtime:
            break
        time.sleep(0.2)
    else:
        # Не дождались — флаг убираем чтобы не накапливалось
        try: SCREENSHOT_REQ.unlink()
        except Exception: pass
        send(token, chat_id, "❌ dashboard не ответил за 5 сек — возможно не запущен")
        return
    r = send_photo(token, chat_id, SCREENSHOT_PNG)
    if not r or not r.get("ok"):
        send(token, chat_id, "❌ sendPhoto failed")


COMMANDS = {
    "/help":     cmd_help,
    "/start":    cmd_help,
    "/status":   cmd_status,
    "/today":    cmd_status,        # alias — Today page показывает то же
    "/backup":   cmd_backup,
    "/update":   cmd_update,
    "/logs":     cmd_logs,
    "/power":    cmd_power,
    "/services": cmd_services,
    "/configs":  cmd_configs,
    "/nas":      cmd_nas,
    "/docker":   cmd_docker,
    "/yt":       cmd_yt,
    "/reboot":   cmd_reboot,
    "/shutdown": cmd_shutdown,
    "/yes":      cmd_yes,
    "/screenshot": cmd_screenshot,
    "/screen":   cmd_screenshot,
    "/sleep":    cmd_sleep,
    "/tailscale": cmd_tailscale,
    "/ts":       cmd_tailscale,
    "/verify":   cmd_verify,
    "/rotate":   cmd_rotate,
    "/flip":     cmd_rotate,
}


# === Main loop ===================================================================

def main():
    token, chat_id_str = load_config()
    chat_id = int(chat_id_str)

    # Восстанавливаем offset чтобы при рестарте не обрабатывать старые сообщения
    offset = 0
    if OFFSET_FILE.exists():
        try:
            offset = int(OFFSET_FILE.read_text().strip())
        except Exception:
            offset = 0
    OFFSET_FILE.parent.mkdir(parents=True, exist_ok=True)

    print(f"tg-listener started, authorized chat_id={chat_id}, offset={offset}")

    # Если предыдущий /update оставил marker — отправляем итог сразу после старта
    if UPDATE_DONE_MARKER.exists():
        try:
            marker = UPDATE_DONE_MARKER.read_text().strip()
            log_tail = ""
            if UPDATE_LOG_PATH.exists():
                try:
                    log_tail = UPDATE_LOG_PATH.read_text()
                except Exception:
                    pass
            tail_lines = "\n".join(log_tail.strip().split("\n")[-15:])
            reboot_warning = ""
            if "REBOOT_NEEDED" in marker:
                reboot_warning = "\n\n⚠ *Нужен reboot* — выполни `sudo reboot` когда удобно."
            # Multi-line marker (--full mode) → отдельный code-блок;
            # single-line (fast mode) — inline после тире.
            if "\n" in marker:
                send(token, chat_id,
                     f"✅ *Update done*\n```\n{marker}\n```\n_log tail:_\n```\n{tail_lines}\n```{reboot_warning}")
            else:
                send(token, chat_id,
                     f"✅ *Update done* — {marker}\n```\n{tail_lines}\n```{reboot_warning}")
        except Exception as e:
            print(f"update marker error: {e}", file=sys.stderr)
        try:
            UPDATE_DONE_MARKER.unlink()
        except Exception:
            pass

    while True:
        result = tg_request(token, "getUpdates", {
            "timeout": 30, "offset": offset,
        }, timeout=40)
        if not result or not result.get("ok"):
            time.sleep(5)
            continue
        for upd in result.get("result", []):
            offset = upd["update_id"] + 1
            try:
                OFFSET_FILE.write_text(str(offset))
            except Exception:
                pass

            # Callback от inline-кнопки (например docker stop/start)
            cb = upd.get("callback_query")
            if cb:
                cb_chat = cb.get("message", {}).get("chat", {}).get("id")
                if cb_chat != chat_id:
                    continue
                cb_id = cb.get("id", "")
                cb_data = cb.get("data", "")
                # Подтверждаем callback (убираем "крутилку" у юзера)
                tg_request(token, "answerCallbackQuery", {"callback_query_id": cb_id})
                if cb_data.startswith("docker:"):
                    try:
                        handle_docker_callback(token, chat_id, cb_data)
                    except Exception as e:
                        print(f"docker callback error: {e}", file=sys.stderr)
                continue

            msg = upd.get("message") or upd.get("edited_message")
            if not msg: continue
            if msg.get("chat", {}).get("id") != chat_id:
                # Не свой чат — игнор
                continue
            text = (msg.get("text") or "").strip()
            if not text: continue

            # Парсим команду: /cmd@bot args ...
            parts = text.split()
            cmd = parts[0].split("@")[0].lower()
            args = parts[1:]

            handler = COMMANDS.get(cmd)
            if not handler:
                continue
            try:
                handler(token, chat_id, args)
            except Exception as e:
                print(f"Handler {cmd} error: {e}", file=sys.stderr)
                try:
                    send(token, chat_id, f"❌ Error: {e}")
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
