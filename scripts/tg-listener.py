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
`/nas` — статус NAS-бэкапов (модули, размеры, last-run)
`/docker` — Docker-compose проекты + кнопки Stop/Start/Restart
`/services` — все URL установленных сервисов
`/configs` — `/etc/travel-nas/` файлы + где что лежит

🔄 *Действия*
`/backup` — NAS backup
`/backup dry` — dry-run NAS backup
`/backup diff` — diff с NAS (что изменится)
`/update` — обновить скрипты из GitHub
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
    и шлёт "✅ Update done" сразу после старта."""
    try:
        UPDATE_LOG_PATH.write_text("")
    except Exception:
        pass
    try:
        UPDATE_DONE_MARKER.unlink()
    except Exception:
        pass

    # start_new_session=True ⇒ child в своей сессии, переживёт systemctl
    # restart tg-listener (который придёт нам через SIGTERM в конце апдейта)
    log_fd = open(UPDATE_LOG_PATH, "w")
    subprocess.Popen(
        ["sudo", "-n", "/usr/local/bin/travel-nas-update"],
        stdout=log_fd, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL, start_new_session=True,
    )
    send(token, chat_id, """🔄 *Update запущен в фоне.*

Длительность ~20-40 сек.
Бот сам перезапустится и сразу пришлёт итог.

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


def cmd_docker(token, chat_id, args):
    """Список compose-проектов с кнопками Stop/Start/Restart."""
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
    "/reboot":   cmd_reboot,
    "/shutdown": cmd_shutdown,
    "/yes":      cmd_yes,
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
            send(token, chat_id,
                 f"✅ *Update done* — {marker}\n```\n{tail_lines}\n```")
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
