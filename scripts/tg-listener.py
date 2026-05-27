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


def send(token, chat_id, text, parse_mode="Markdown"):
    return tg_request(token, "sendMessage", {
        "chat_id": chat_id,
        "text": text[:4000],
        "parse_mode": parse_mode,
    })


# === Command handlers ============================================================

def cmd_help(token, chat_id, args):
    send(token, chat_id, """*Travel-NAS bot commands*

`/status` — system snapshot
`/backup` — run NAS backup
`/backup dry` — dry-run
`/logs [N]` — last N lines of logs (default 30)
`/power [home|field|emergency|auto]`
`/reboot` — reboot Pi (asks confirmation)
`/shutdown` — power off Pi (asks confirmation)
`/yes` — confirm pending action
`/help` — this message""")


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
            parts.append(f"🔌 power mode: `{POWER_MODE_FILE.read_text().strip()}`")
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
    mode = (args[0] if args else "auto").lower()
    if mode not in ("home", "field", "emergency", "auto", "status"):
        send(token, chat_id, "Usage: /power [home|field|emergency|auto|status]")
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


COMMANDS = {
    "/help":     cmd_help,
    "/start":    cmd_help,
    "/status":   cmd_status,
    "/backup":   cmd_backup,
    "/logs":     cmd_logs,
    "/power":    cmd_power,
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
