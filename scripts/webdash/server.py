#!/usr/bin/env python3
# =============================================================================
# travel-nas web dashboard — backend (Flask).
#
# Отдаёт:
#   /                     → static/index.html (SPA)
#   /static/*             → ассеты (app.js, style.css, uplot)
#   /api/snapshot         → текущий снимок метрик (JSON)
#   /api/stream           → SSE: пушит снимок каждые STREAM_SEC сек (без refresh)
#   /api/history?m=&range=→ временной ряд из SQLite (1h/24h/7d)
#   /api/action/<name>    → привилегированные действия (через sudo NOPASSWD)
#
# Данные берём из тех же источников, что и старый дашборд/бот: /sys, vcgenchd,
# df, smartctl, docker, nmcli/iw, tailscale, *.status.json. Дорогие источники
# опрашиваются реже (фоновые сэмплеры), SSE читает общий кэш — поэтому быстро.
#
# История пишется в SQLite на /mnt/storage (НЕ на microSD — бережём карту).
# Конфиг: /etc/travel-nas/webdash.conf (порт, таймаут экрана, ночь, ...).
# =============================================================================
import json, os, pwd, sqlite3, subprocess, threading, time
from pathlib import Path
from flask import Flask, Response, request, jsonify, send_from_directory

BASE = Path(__file__).resolve().parent
STATIC = BASE / "static"

# --- конфиг ------------------------------------------------------------------
CONF = {
    "PORT": 8090,
    "STREAM_SEC": 2,          # как часто SSE пушит снимок
    "SAMPLE_SEC": 30,         # как часто пишем точку в историю (SQLite)
    "HISTORY_DB": "/mnt/storage/.travel-nas/metrics.db",
    "STORAGE_MOUNT": "/mnt/storage",
}
def load_conf():
    p = Path("/etc/travel-nas/webdash.conf")
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k in CONF and v:
                CONF[k] = int(v) if v.isdigit() else v
load_conf()

USER = pwd.getpwuid(1000).pw_name if os.path.exists("/etc/passwd") else "root"
app = Flask(__name__, static_folder=None)

# =============================================================================
# Сбор метрик. SAMPLE — общий кэш, обновляют фоновые потоки. Разные cadence.
# =============================================================================
SAMPLE = {"ts": 0, "system": {}, "storage": {}, "network": {}, "services": {}}
_lock = threading.Lock()

def sh(cmd, timeout=8):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""

def read(path, default=""):
    try:
        return Path(path).read_text().strip()
    except Exception:
        return default

# ---- быстрые метрики (CPU/temp/RAM/net/throttle) — каждые ~2с ----------------
_prev_cpu = None
_prev_net = None
def cpu_percent():
    global _prev_cpu
    try:
        parts = read("/proc/stat").splitlines()[0].split()[1:]
        vals = list(map(int, parts))
        idle = vals[3] + vals[4]
        total = sum(vals)
        if _prev_cpu:
            dt, di = total - _prev_cpu[0], idle - _prev_cpu[1]
            pct = round(100 * (dt - di) / dt, 1) if dt > 0 else 0
        else:
            pct = 0
        _prev_cpu = (total, idle)
        return pct
    except Exception:
        return 0

def net_rate():
    global _prev_net
    rx = tx = 0
    try:
        for line in read("/proc/net/dev").splitlines():
            if ":" not in line:
                continue
            iface, data = line.split(":", 1)
            iface = iface.strip()
            if iface in ("lo",) or iface.startswith(("veth", "br-", "docker")):
                continue
            f = data.split()
            rx += int(f[0]); tx += int(f[8])
        now = time.time()
        if _prev_net:
            dt = now - _prev_net[2]
            rrx = (rx - _prev_net[0]) / dt if dt > 0 else 0
            rtx = (tx - _prev_net[1]) / dt if dt > 0 else 0
        else:
            rrx = rtx = 0
        _prev_net = (rx, tx, now)
        return round(rrx / 1e6, 2), round(rtx / 1e6, 2)   # MB/s
    except Exception:
        return 0, 0

def sample_fast():
    temp = 0
    t = read("/sys/class/thermal/thermal_zone0/temp")
    if t.isdigit():
        temp = round(int(t) / 1000, 1)
    mem = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, v = line.partition(":")
        mem[k] = int(v.strip().split()[0]) if v.strip() else 0
    mem_total = mem.get("MemTotal", 0) / 1e6
    mem_avail = mem.get("MemAvailable", 0) / 1e6
    throttled = sh(["vcgencmd", "get_throttled"]).replace("throttled=", "")
    gov = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "?")
    up = read("/proc/uptime").split()
    uptime = int(float(up[0])) if up else 0
    la = read("/proc/loadavg").split()[:3]
    rrx, rtx = net_rate()
    return {
        "cpu": cpu_percent(), "temp": temp,
        "mem_used": round(mem_total - mem_avail, 2), "mem_total": round(mem_total, 2),
        "throttled": throttled, "throttled_now": throttled not in ("", "0x0"),
        "governor": gov, "uptime": uptime, "load": la,
        "net_rx": rrx, "net_tx": rtx,
    }

# ---- медленные метрики (диск/SMART/docker/сеть/tailscale/бэкапы) — ~15-30с ----
def sample_storage():
    out = sh(["df", "-B1", "--output=size,used,avail,pcent,target", CONF["STORAGE_MOUNT"]])
    size = used = avail = pct = 0; mounted = False
    lines = out.splitlines()
    if len(lines) >= 2:
        f = lines[1].split()
        try:
            size, used, avail = int(f[0]), int(f[1]), int(f[2])
            pct = int(f[3].rstrip("%")); mounted = f[4] == CONF["STORAGE_MOUNT"]
        except Exception:
            pass
    # SMART (sudo); авто-детект устройства /mnt/storage
    src = sh(["findmnt", "-n", "-o", "SOURCE", "--target", CONF["STORAGE_MOUNT"]])
    dev = src.rstrip("0123456789").rstrip("p") if src else ""
    disk_temp = None; health = "?"
    if dev:
        sm = sh(["sudo", "-n", "smartctl", "-a", dev], timeout=10)
        for line in sm.splitlines():
            low = line.lower()
            if "temperature" in low and disk_temp is None:
                for tok in line.split():
                    if tok.isdigit():
                        disk_temp = int(tok); break
            if "overall-health" in low:
                health = line.split(":")[-1].strip()
    return {"size": size, "used": used, "avail": avail, "pct": pct,
            "mounted": mounted, "disk_temp": disk_temp, "health": health,
            "device": src}

def sample_network():
    ips = sh(["hostname", "-I"]).split()
    ip = ips[0] if ips else "?"
    ssid = sh(["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"])
    ssid = next((l.split(":", 1)[1] for l in ssid.splitlines()
                 if l.startswith("yes:")), "")
    signal = ""
    for line in read("/proc/net/wireless").splitlines():
        if ":" in line and "wlan" in line:
            parts = line.split()
            if len(parts) > 3:
                signal = parts[3].rstrip(".")
    ts_ip = sh(["tailscale", "ip", "-4"], timeout=5).splitlines()
    return {"ip": ip, "ssid": ssid, "signal": signal,
            "tailscale": ts_ip[0] if ts_ip else ""}

def sample_services():
    docker = []
    out = sh(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}"], timeout=10)
    for line in out.splitlines():
        if "\t" in line:
            name, state = line.split("\t", 1)
            docker.append({"name": name, "state": state})
    nas = read_json("/var/lib/travel-nas/nas-backup.status.json", {})
    prog = read_json("/var/run/travel-nas/backup-progress.json", {})
    return {"docker": docker, "nas_backup": nas, "progress": prog}

def read_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default

def sampler_fast():
    while True:
        s = sample_fast()
        with _lock:
            SAMPLE["system"].update(s); SAMPLE["ts"] = int(time.time())
        time.sleep(CONF["STREAM_SEC"])

def sampler_slow():
    while True:
        try:
            st, nw, sv = sample_storage(), sample_network(), sample_services()
            with _lock:
                SAMPLE["storage"], SAMPLE["network"], SAMPLE["services"] = st, nw, sv
        except Exception as e:
            print("slow sampler:", e)
        time.sleep(15)

# =============================================================================
# История (SQLite на /mnt/storage). Пишем cpu/temp/mem/disk каждые SAMPLE_SEC.
# =============================================================================
def db():
    Path(CONF["HISTORY_DB"]).parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(CONF["HISTORY_DB"], timeout=5)
    c.execute("CREATE TABLE IF NOT EXISTS m (ts INT, cpu REAL, temp REAL, "
              "mem REAL, disk REAL, net_rx REAL, net_tx REAL)")
    return c

def sampler_history():
    while True:
        time.sleep(CONF["SAMPLE_SEC"])
        try:
            with _lock:
                s, st = dict(SAMPLE["system"]), dict(SAMPLE["storage"])
            if not s:
                continue
            c = db()
            c.execute("INSERT INTO m VALUES (?,?,?,?,?,?,?)",
                      (int(time.time()), s.get("cpu", 0), s.get("temp", 0),
                       s.get("mem_used", 0), st.get("pct", 0),
                       s.get("net_rx", 0), s.get("net_tx", 0)))
            # ретенция: 8 дней
            c.execute("DELETE FROM m WHERE ts < ?", (int(time.time()) - 8 * 86400,))
            c.commit(); c.close()
        except Exception as e:
            print("history:", e)

# =============================================================================
# Действия (sudo NOPASSWD ставит модуль 27-webdash). Белый список — без shell.
# =============================================================================
ACTIONS = {
    "reboot":      ["sudo", "-n", "/usr/sbin/reboot"],
    "poweroff":    ["sudo", "-n", "/usr/sbin/poweroff"],
    "update":      ["sudo", "-n", "/usr/local/bin/travel-nas-update"],
    "nas-backup":  ["sudo", "-n", "/usr/local/bin/nas-backup.sh"],
    "cpu-boost":   ["sudo", "-n", "/usr/local/bin/cpu-boost.sh", "on"],
}
def power_mode(mode):
    if mode in ("auto", "normal", "saver"):
        return ["sudo", "-n", "/usr/local/bin/power-mode.sh", mode]
    return None

# =============================================================================
# Routes
# =============================================================================
@app.route("/")
def index():
    return send_from_directory(STATIC, "index.html")

@app.route("/static/<path:p>")
def static_files(p):
    return send_from_directory(STATIC, p)

def snapshot():
    with _lock:
        return dict(SAMPLE)

@app.route("/api/snapshot")
def api_snapshot():
    return jsonify(snapshot())

@app.route("/api/stream")
def api_stream():
    def gen():
        while True:
            yield "data: " + json.dumps(snapshot()) + "\n\n"
            time.sleep(CONF["STREAM_SEC"])
    return Response(gen(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

@app.route("/api/history")
def api_history():
    m = request.args.get("m", "temp")
    rng = request.args.get("range", "24h")
    secs = {"1h": 3600, "24h": 86400, "7d": 7 * 86400}.get(rng, 86400)
    cols = {"cpu", "temp", "mem", "disk", "net_rx", "net_tx"}
    if m not in cols:
        return jsonify({"error": "bad metric"}), 400
    try:
        c = db()
        rows = c.execute(f"SELECT ts,{m} FROM m WHERE ts>=? ORDER BY ts",
                         (int(time.time()) - secs,)).fetchall()
        c.close()
        return jsonify({"t": [r[0] for r in rows], "v": [r[1] for r in rows]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/action/<name>", methods=["POST"])
def api_action(name):
    if name == "power-mode":
        cmd = power_mode(request.json.get("mode") if request.is_json else None)
    elif name == "screen":
        return api_screen()
    else:
        cmd = ACTIONS.get(name)
    if not cmd:
        return jsonify({"error": "unknown action"}), 400
    detach = name in ("reboot", "poweroff", "update", "nas-backup")
    try:
        if detach:
            subprocess.Popen(cmd)
            return jsonify({"ok": True, "detached": True})
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return jsonify({"ok": out.returncode == 0, "out": out.stdout[-500:],
                        "err": out.stderr[-500:]})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

def api_screen():
    """Яркость/поворот/гашение/выход из kiosk."""
    d = request.json or {}
    if "brightness" in d:
        subprocess.run(["/usr/local/bin/dsi-backlight.sh", str(d["brightness"])])
    if d.get("backlight") in ("on", "off"):
        subprocess.run(["/usr/local/bin/dsi-backlight.sh", d["backlight"]])
    if "rotate" in d:
        subprocess.Popen(["sudo", "-n", "/usr/local/bin/dsi-rotate.sh", str(d["rotate"])])
    if d.get("exit_kiosk"):
        subprocess.Popen(["pkill", "-f", "chromium.*localhost:%d" % CONF["PORT"]])
    return jsonify({"ok": True})

if __name__ == "__main__":
    for fn in (sampler_fast, sampler_slow, sampler_history):
        threading.Thread(target=fn, daemon=True).start()
    time.sleep(0.5)
    app.run(host="127.0.0.1", port=CONF["PORT"], threaded=True)
