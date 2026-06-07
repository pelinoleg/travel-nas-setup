#!/usr/bin/env python3
# =============================================================================
# travel-nas web dashboard — backend (Flask). См. README раздела webdash.
#   /                      → SPA
#   /api/snapshot          → текущий снимок (system/storage/network/services)
#   /api/stream            → SSE (пуш каждые STREAM_SEC)
#   /api/history?m=&range= → ряд из SQLite (1h/24h/7d)
#   /api/processes         → топ процессов (cpu/mem)
#   /api/logs?src=         → хвост журналов
#   /api/docker  (POST)    → start/stop/restart проекта compose
#   /api/action/<name>     → reboot/poweroff/update/nas-backup/cpu-boost/power-mode
#   /api/action/screen     → яркость/поворот/гашение/выход из kiosk
# История пишется в SQLite на /mnt/storage (не на microSD).
# =============================================================================
import json, os, pwd, re, sqlite3, subprocess, threading, time, glob, gzip, hashlib, shutil, urllib.request, zipfile
from pathlib import Path
from flask import Flask, Response, request, jsonify, send_from_directory, send_file

BASE = Path(__file__).resolve().parent
STATIC = BASE / "static"
CONF = {"PORT": 8090, "STREAM_SEC": 2, "SAMPLE_SEC": 30, "BIND": "127.0.0.1",
        "HISTORY_DB": "/mnt/storage/.travel-nas/metrics.db", "STORAGE_MOUNT": "/mnt/storage"}
def load_conf():
    p = Path("/etc/travel-nas/webdash.conf")
    if p.exists():
        for line in p.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = (x.strip().strip('"').strip("'") for x in line.split("=", 1))
                if k in CONF and v:
                    CONF[k] = int(v) if v.isdigit() else v
load_conf()
app = Flask(__name__, static_folder=None)

def sh(cmd, timeout=8):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""
def read(path, d=""):
    # errors="replace": один битый байт в конфиге не должен обнулять весь read
    try: return Path(path).read_text(errors="replace").strip()
    except Exception: return d
def read_json(path, d):
    try: return json.loads(Path(path).read_text())
    except Exception: return d

SAMPLE = {"ts": 0, "system": {}, "storage": {}, "network": {}, "services": {}}
_lock = threading.Lock()

# ---- быстрые метрики --------------------------------------------------------
_prev_cpu = None; _prev_net = None
def cpu_percent():
    global _prev_cpu
    try:
        v = list(map(int, read("/proc/stat").splitlines()[0].split()[1:]))
        idle, total = v[3] + v[4], sum(v)
        pct = 0
        if _prev_cpu:
            dt, di = total - _prev_cpu[0], idle - _prev_cpu[1]
            pct = round(100 * (dt - di) / dt, 1) if dt > 0 else 0
        _prev_cpu = (total, idle); return pct
    except Exception: return 0
def net_rate():
    global _prev_net
    rx = tx = 0
    try:
        for line in read("/proc/net/dev").splitlines():
            if ":" not in line: continue
            iface, data = line.split(":", 1); iface = iface.strip()
            if iface == "lo" or iface.startswith(("veth", "br-", "docker")): continue
            f = data.split(); rx += int(f[0]); tx += int(f[8])
        now = time.time(); rrx = rtx = 0
        if _prev_net:
            dt = now - _prev_net[2]
            if dt > 0: rrx, rtx = (rx - _prev_net[0]) / dt, (tx - _prev_net[1]) / dt
        _prev_net = (rx, tx, now)
        return round(rrx / 1e3, 1), round(rtx / 1e3, 1)   # KB/s (фронт авто KB↔MB)
    except Exception: return 0, 0
def sample_fast():
    t = read("/sys/class/thermal/thermal_zone0/temp")
    temp = round(int(t) / 1000, 1) if t.isdigit() else 0
    mem = {}
    for line in read("/proc/meminfo").splitlines():
        k, _, val = line.partition(":")
        if val.strip(): mem[k] = int(val.strip().split()[0])
    mt, ma = mem.get("MemTotal", 0) / 1e6, mem.get("MemAvailable", 0) / 1e6
    thr = sh(["vcgencmd", "get_throttled"]).replace("throttled=", "")
    freq = read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
    fmax = read("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")
    rrx, rtx = net_rate()
    bright = None; screen_on = True
    for bd in glob.glob("/sys/class/backlight/*/"):
        try:
            b = int(read(bd + "brightness")); m = int(read(bd + "max_brightness"))
            if m: bright = round(b / m * 100)
            screen_on = read(bd + "bl_power", "0") in ("0", "")
        except Exception: pass
        break
    return {"cpu": cpu_percent(), "temp": temp, "bright": bright, "screen_on": screen_on,
            "mem_used": round(mt - ma, 2), "mem_total": round(mt, 2),
            "throttled": thr, "throttled_now": thr not in ("", "0x0"),
            "governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "?"),
            "pmode": read("/var/lib/travel-nas/power-mode-pref", "auto"),
            "freq_mhz": round(int(freq) / 1000) if freq.isdigit() else 0,
            "freq_max": round(int(fmax) / 1000) if fmax.isdigit() else 0,
            "uptime": int(float(read("/proc/uptime").split()[0] or 0)),
            "load": read("/proc/loadavg").split()[:3], "net_rx": rrx, "net_tx": rtx}

# ---- диски (SD + USB), визуально --------------------------------------------
_smart_dtype = {}
def smart_type(dev):
    # smartctl --scan определяет правильный -d (для USB-мостов: sntasmedia/sntjmicron/sat).
    # Без него USB-NVMe (Samsung T7) детектится как scsi → нет температуры.
    if dev not in _smart_dtype:
        t = ""
        for line in sh(["sudo", "-n", "smartctl", "--scan"], timeout=8).splitlines():
            if line.startswith(dev + " ") and " -d " in line:
                t = line.split(" -d ", 1)[1].split()[0]; break
        _smart_dtype[dev] = t
    return _smart_dtype[dev]
def smart_cmd(dev):
    t = smart_type(dev)
    return ["sudo", "-n", "smartctl", "-a"] + (["-d", t] if t else []) + [dev]
def smart_of(dev):
    temp = None; health = "?"
    out = sh(smart_cmd(dev), timeout=10)
    for line in out.splitlines():
        low = line.lower()
        if disk_kw(low, "temperature") and temp is None:
            for tok in line.replace("(", " ").split():
                if tok.isdigit() and 0 < int(tok) < 120: temp = int(tok); break
        if "overall-health" in low: health = line.split(":")[-1].strip()
    return temp, health
def disk_kw(s, kw): return kw in s and "temperature_" not in s
def sample_disks():
    out = sh(["lsblk", "-J", "-b", "-o", "NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,TRAN,MODEL"])
    disks = []
    try:
        data = json.loads(out)
    except Exception:
        data = {"blockdevices": []}
    for d in data.get("blockdevices", []):
        if d.get("type") != "disk": continue
        name = d["name"]
        if name.startswith("zram"): continue
        kind = "SD" if name.startswith("mmcblk") else ("USB" if d.get("tran") == "usb" else (d.get("tran") or "disk").upper())
        parts = []
        for ch in d.get("children", []) or [{"name": name, **d}]:
            mp = ch.get("mountpoint")
            used = total = pct = None
            if mp:
                df = sh(["df", "-B1", "--output=size,used,pcent", mp]).splitlines()
                if len(df) >= 2:
                    f = df[1].split()
                    try: total, used, pct = int(f[0]), int(f[1]), int(f[2].rstrip("%"))
                    except Exception: pass
            parts.append({"name": ch.get("name"), "fstype": ch.get("fstype"),
                          "label": ch.get("label"), "mount": mp,
                          "used": used, "total": total, "pct": pct})
        temp = health = None
        if not name.startswith("mmcblk"):
            temp, health = smart_of("/dev/" + name)
        disks.append({"name": name, "kind": kind, "size": d.get("size"),
                      "model": (d.get("model") or "").strip(), "temp": temp,
                      "health": health, "parts": parts})
    return disks
def sample_storage():
    disks = sample_disks()
    # сводка по /mnt/storage для карточки Overview
    prim = {}
    for d in disks:
        for p in d["parts"]:
            if p["mount"] == CONF["STORAGE_MOUNT"]:
                prim = {"pct": p["pct"], "used": p["used"], "size": p["total"],
                        "disk_temp": d["temp"], "health": d["health"],
                        "mounted": True, "device": "/dev/" + p["name"]}
    if not prim:
        prim = {"pct": None}
    prim["mounted"] = os.path.ismount(CONF["STORAGE_MOUNT"])   # авторитетно, не из lsblk
    ro = False                                                  # read-only / ext4 emergency
    for line in read("/proc/mounts").splitlines():
        f = line.split()
        if len(f) >= 4 and f[1] == CONF["STORAGE_MOUNT"]:
            o = "," + f[3] + ","
            ro = "emergency_ro" in o or "shutdown" in o or ",ro," in o
    prim["readonly"] = ro
    prim["disks"] = disks
    return prim

def sample_network():
    ips = sh(["hostname", "-I"]).split()
    ssid = next((l.split(":", 1)[1] for l in sh(["nmcli", "-t", "-f", "active,ssid", "dev", "wifi"]).splitlines()
                 if l.startswith("yes:")), "")
    signal = ""
    for line in read("/proc/net/wireless").splitlines():
        if ":" in line and "wlan" in line:
            p = line.split()
            if len(p) > 3: signal = p[3].rstrip(".")
    ts = sh(["tailscale", "ip", "-4"], timeout=5).splitlines()
    ts_up = False; ts_peers = 0
    try:
        j = json.loads(sh(["tailscale", "status", "--json"], timeout=5) or "{}")
        ts_up = j.get("BackendState") == "Running"; ts_peers = len(j.get("Peer") or {})
    except Exception:
        pass
    iw = sh(["iw", "dev", "wlan0", "info"])
    mode = "AP" if "type AP" in iw else ("client" if "type managed" in iw else "?")
    ap_name = comitup_state = ""
    for line in sh(["/usr/sbin/comitup-cli", "i"], timeout=4).splitlines():
        if line.startswith("Host"):
            ap_name = line.split()[1].replace(".local", "") if len(line.split()) > 1 else ""
        elif "state" in line.lower():
            comitup_state = line.split()[0].strip("'")
    # AP-имя/пароль из comitup.conf (некомментированные ap_name/ap_password)
    cfg_name = cfg_pass = ""
    for line in read("/etc/comitup.conf").splitlines():
        l = line.strip()
        if l.startswith("ap_name:"): cfg_name = l.split(":", 1)[1].strip()
        elif l.startswith("ap_password:"): cfg_pass = l.split(":", 1)[1].strip()
    ap_ssid = ssid if mode == "AP" else (ap_name or cfg_name or "comitup-XXXX")
    return {"host": sh(["hostname"]) or "nas", "ip": ips[0] if ips else "?",
            "ssid": ssid, "signal": signal, "mode": mode, "tailscale": ts[0] if ts else "",
            "ap_name": ap_name, "comitup": comitup_state, "ts_up": ts_up, "ts_peers": ts_peers,
            "ap_ssid": ap_ssid, "ap_pass": cfg_pass or "open (no password)"}

def sample_services():
    raw = sh(["docker", "ps", "-a", "--format",
              '{{.Names}}\t{{.State}}\t{{.Label "com.docker.compose.project"}}'], timeout=10)
    projs = {}
    for line in raw.splitlines():
        p = line.split("\t")
        if len(p) < 2: continue
        proj = p[2] if len(p) > 2 and p[2] else "other"
        projs.setdefault(proj, []).append({"name": p[0], "state": p[1]})
    projects = [{"project": k, "containers": v,
                 "running": sum(1 for c in v if c["state"] == "running"), "total": len(v)}
                for k, v in sorted(projs.items())]
    photo = {}
    try:
        dirs = sorted(glob.glob("/mnt/storage/usb-imports/*/"), key=os.path.getmtime, reverse=True)
        if dirs:
            d = dirs[0]
            photo = {"last": time.strftime("%d.%m %H:%M", time.localtime(os.path.getmtime(d))),
                     "name": os.path.basename(d.rstrip("/"))}
            try: photo["bytes"] = int(sh(["du", "-sb", d]).split()[0])
            except Exception: pass
            try:
                n = 0
                for _, _, fs in os.walk(d): n += len(fs)
                photo["files"] = n
            except Exception: pass
    except Exception: pass
    prog = read_json("/var/run/travel-nas/backup-progress.json", {})
    # kind — авторитетно: source-поле писателя (photo|nas) + проверка transient-unit
    # nas-backup-runtime (как в старом дашборде). НЕ угадываем по подстроке пути.
    nas_run = sh(["systemctl", "is-active", "nas-backup-runtime"]) == "active"
    if prog:
        prog["active"] = (time.time() - prog.get("updated", 0)) < 30
        src = prog.get("source", "")
        prog["kind"] = "nas" if (src == "nas" or nas_run) else "photo"
    yt = {}
    try:
        with urllib.request.urlopen("http://localhost:8081/api/queue/status", timeout=3) as r:
            yt = json.loads(r.read())
        with urllib.request.urlopen("http://localhost:8081/api/stats", timeout=3) as r:
            yt.update(json.loads(r.read()))   # videos, total_bytes, channels
        with urllib.request.urlopen("http://localhost:8081/api/videos", timeout=4) as r:
            vids = json.loads(r.read())
            yt["music"] = sum(1 for v in vids if v.get("is_music") or v.get("is_music_via_playlist"))
    except Exception:
        pass
    return {"projects": projects, "photo": photo, "yt": yt,
            "nas_backup": read_json("/var/lib/travel-nas/nas-backup-status.json", {}),
            "nas_sched": sh(["/usr/local/bin/nas-schedule.sh", "status"]) or "off",
            "progress": prog,
            "thermal": read_json("/var/lib/travel-nas/thermal-guard.state.json", {})}

def sampler_fast():
    while True:
        s = sample_fast()
        with _lock: SAMPLE["system"].update(s); SAMPLE["ts"] = int(time.time())
        time.sleep(CONF["STREAM_SEC"])
def sampler_slow():
    while True:
        try:
            st, nw, sv = sample_storage(), sample_network(), sample_services()
            with _lock: SAMPLE["storage"], SAMPLE["network"], SAMPLE["services"] = st, nw, sv
        except Exception as e: print("slow:", e)
        time.sleep(15)

# ---- история ----------------------------------------------------------------
def db():
    Path(CONF["HISTORY_DB"]).parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(CONF["HISTORY_DB"], timeout=5)
    c.execute("CREATE TABLE IF NOT EXISTS m (ts INT, cpu REAL, temp REAL, mem REAL, "
              "disk REAL, net_rx REAL, net_tx REAL, dtemp REAL)")
    try: c.execute("ALTER TABLE m ADD COLUMN dtemp REAL")   # миграция старой БД
    except Exception: pass
    return c
def sampler_history():
    while True:
        time.sleep(CONF["SAMPLE_SEC"])
        try:
            with _lock: s, st = dict(SAMPLE["system"]), dict(SAMPLE["storage"])
            if not s: continue
            c = db()
            c.execute("INSERT INTO m VALUES (?,?,?,?,?,?,?,?)",
                      (int(time.time()), s.get("cpu", 0), s.get("temp", 0), s.get("mem_used", 0),
                       st.get("pct") or 0, s.get("net_rx", 0), s.get("net_tx", 0), st.get("disk_temp") or 0))
            c.execute("DELETE FROM m WHERE ts < ?", (int(time.time()) - 8 * 86400,))
            c.commit(); c.close()
        except Exception as e: print("history:", e)

# ---- действ", docker, логи, процессы ----------------------------------------
ACTIONS = {
    "reboot": ["sudo", "-n", "/usr/sbin/reboot"],
    "poweroff": ["sudo", "-n", "/usr/sbin/poweroff"],
    "update": ["sudo", "-n", "/usr/local/bin/travel-nas-update"],
    "nas-backup": ["sudo", "-n", "/usr/local/bin/nas-backup.sh", "--run"],
    "nas-dry": ["sudo", "-n", "/usr/local/bin/nas-backup.sh", "--dry-run"],
    "nas-diff": ["sudo", "-n", "/usr/local/bin/nas-backup.sh", "--diff"],
    "nas-stop": ["sudo", "-n", "/usr/bin/systemctl", "stop", "nas-backup-runtime"],
    "nas-sched-off": ["sudo", "-n", "/usr/local/bin/nas-schedule.sh", "off"],
    "pi-backup": ["sudo", "-n", "/usr/local/bin/pi-config-backup.sh"],
    "cpu-boost": ["sudo", "-n", "/usr/local/bin/cpu-boost.sh", "on"],
    "force-ap": ["sudo", "-n", "/usr/sbin/comitup-cli", "d"],
    "tailscale-up": ["sudo", "-n", "/usr/bin/tailscale", "up"],
    "tailscale-down": ["sudo", "-n", "/usr/bin/tailscale", "down"],
    "wifi-reconnect": ["sudo", "-n", "/usr/bin/nmcli", "device", "reconnect", "wlan0"],
    "verify-run": ["sudo", "-n", "/usr/bin/systemctl", "start", "--no-block", "nas-verify.service"],
    "restart-tg": ["sudo", "-n", "/usr/bin/systemctl", "restart", "tg-listener.service"],
    "restart-dash": ["sudo", "-n", "/usr/bin/systemctl", "--no-block", "restart", "travel-nas-webdash.service"],
}
UPDATE_LOG = "/var/run/travel-nas/webdash-update.log"
def compose_file(project):
    for c in (f"/opt/stacks/{project}/compose.yaml", "/opt/dockge/compose.yaml"):
        if os.path.exists(c): return c
    for c in glob.glob("/opt/stacks/*/compose.yaml"):
        if f"name: {project}" in read(c): return c
    return None

@app.after_request
def _nocache(resp):
    # kiosk локальный — не кэшируем, чтобы свежий код после travel-nas-update
    # подхватывался без перезапуска Chromium (раньше ловили старый app.js).
    resp.headers["Cache-Control"] = "no-store"
    return resp

@app.route("/")
def index(): return send_from_directory(STATIC, "index.html")
@app.route("/static/<path:p>")
def static_files(p): return send_from_directory(STATIC, p)
@app.route("/favicon.ico")
def favicon(): return ("", 204)
def snapshot():
    with _lock: return dict(SAMPLE)
@app.route("/api/snapshot")
def api_snapshot(): return jsonify(snapshot())
@app.route("/api/stream")
def api_stream():
    def gen():
        while True:
            yield "data: " + json.dumps(snapshot()) + "\n\n"; time.sleep(CONF["STREAM_SEC"])
    return Response(gen(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
@app.route("/api/history")
def api_history():
    m, rng = request.args.get("m", "temp"), request.args.get("range", "1h")
    secs = {"5m": 300, "1h": 3600, "24h": 86400, "7d": 7 * 86400}.get(rng, 3600)
    if m not in {"cpu", "temp", "mem", "disk", "net_rx", "net_tx", "dtemp"}:
        return jsonify({"error": "bad"}), 400
    try:
        c = db(); rows = c.execute(f"SELECT ts,{m} FROM m WHERE ts>=? ORDER BY ts",
                                   (int(time.time()) - secs,)).fetchall(); c.close()
        return jsonify({"t": [r[0] for r in rows], "v": [r[1] for r in rows]})
    except Exception as e: return jsonify({"error": str(e)}), 500
@app.route("/api/processes")
def api_processes():
    def top(by):
        rows = []
        for line in sh(["ps", "-eo", "pid,comm,pcpu,pmem", "--sort=-" + by, "--no-headers"]).splitlines()[:8]:
            f = line.split(None, 3)
            if len(f) >= 4:
                rows.append({"pid": f[0], "cmd": f[1], "cpu": f[2], "mem": f[3]})
        return rows
    return jsonify({"cpu": top("pcpu"), "mem": top("pmem")})
@app.route("/api/logs")
def api_logs():
    units = ["travel-nas-webdash", "nas-backup-runtime", "thermal-guard", "comitup"]
    cmd = ["journalctl", "-n", "150", "--no-pager", "-o", "short-iso"]
    for u in units: cmd += ["-u", u + ".service"]
    out = sh(cmd, timeout=10) or sh(["journalctl", "-n", "120", "--no-pager"], timeout=10)
    return Response(out, mimetype="text/plain")
@app.route("/api/services")
def api_services():
    nw = snapshot().get("network", {})
    host, ip = (nw.get("host") or "nas") + ".local", nw.get("ip", "")
    items = []
    p = Path("/etc/travel-nas/services.conf")
    if p.exists():
        for raw in p.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or raw[:1] in (" ", "\t") or "=" not in line:
                continue
            name, url = line.lstrip(">").split("=", 1)
            url = url.strip().replace("{host}", host).replace("{ip}", ip)
            if url.startswith("http"):
                items.append({"name": name.strip(), "url": url})
    return jsonify(items)

IMPORTS = "/mnt/storage/usb-imports"
@app.route("/api/imports")
def api_imports():
    items = []; total = 0
    for d in sorted(glob.glob(IMPORTS + "/*"), reverse=True):
        if os.path.isdir(d):
            sz = sh(["du", "-sb", d]).split("\t")[0]
            sz = int(sz) if sz.isdigit() else 0
            total += sz
            items.append({"name": os.path.basename(d), "size": sz, "mtime": int(os.path.getmtime(d))})
    return jsonify({"total": total, "items": items})
@app.route("/api/imports/delete", methods=["POST"])
def api_imports_delete():
    name = (request.json or {}).get("name", "")
    p = os.path.join(IMPORTS, name)
    if name and "/" not in name and ".." not in name and os.path.isdir(p):
        shutil.rmtree(p, ignore_errors=True); return jsonify({"ok": True})
    return jsonify({"ok": False}), 400

@app.route("/api/yt", methods=["POST"])
def api_yt():
    act = (request.json or {}).get("action")
    if act not in ("pause", "resume"):
        return jsonify({"error": "bad"}), 400
    try:
        urllib.request.urlopen(urllib.request.Request(
            "http://localhost:8081/api/queue/" + act, method="POST"), timeout=5)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/api/maint")
def api_maint():
    nv = ""
    for line in sh(["systemctl", "list-timers", "nas-verify.timer", "--no-pager"]).splitlines():
        if "nas-verify" in line:
            nv = " ".join(line.split()[0:3])
    return jsonify({"verify_next": nv})

@app.route("/api/today")
def api_today():
    return jsonify(read_json("/var/lib/travel-nas/daily-summary.json", {}))

def send_photo(token, chat, path):
    boundary = "----webdashshot"
    with open(path, "rb") as f:
        img = f.read()
    body = b""
    for k, v in (("chat_id", chat),):
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)).encode()
    body += ("--%s\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"shot.png\"\r\nContent-Type: image/png\r\n\r\n" % boundary).encode()
    body += img + ("\r\n--%s--\r\n" % boundary).encode()
    req = urllib.request.Request("https://api.telegram.org/bot%s/sendPhoto" % token, data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    urllib.request.urlopen(req, timeout=20)

@app.route("/api/screenshot", methods=["POST"])
def api_screenshot():
    shot = "/tmp/webdash-shot.png"
    env = dict(os.environ, WAYLAND_DISPLAY="wayland-0", XDG_RUNTIME_DIR="/run/user/1000")
    try:
        subprocess.run(["grim", shot], env=env, timeout=10, capture_output=True)
        if not os.path.exists(shot):
            return jsonify({"ok": False, "error": "grim failed (no wayland?)"}), 500
        tok = chat = ""
        for line in read("/etc/travel-nas/tg-notify.conf").splitlines():
            if line.startswith("TG_BOT_TOKEN="): tok = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("TG_CHAT_ID="): chat = line.split("=", 1)[1].strip().strip('"')
        if not tok or not chat:
            return jsonify({"ok": False, "error": "no telegram config"}), 400
        send_photo(tok, chat, shot)
        return jsonify({"ok": True})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/api/configs")
def api_configs():
    DESC = {"tg-notify.conf": "Telegram bot token + chat", "nas-backup.conf": "NAS host/user/pass",
            "services.conf": "Dashboard service URLs", "photo-backup.conf": "USB/SD import settings",
            "storage-info.conf": "Storage disk UUID", "yt-archiver.conf": "YT-Archiver CPU limit",
            "webdash.conf": "Dashboard settings", "thermal-guard.conf": "Thermal thresholds",
            "cpu-boost.conf": "CPU boost minutes", "display.conf": "Screen type"}
    out = []
    for p in sorted(glob.glob("/etc/travel-nas/*.conf")):
        n = os.path.basename(p)
        out.append({"name": n, "desc": DESC.get(n, ""),
                    "size": os.path.getsize(p), "mtime": int(os.path.getmtime(p))})
    return jsonify(out)

def _tg_creds():
    tok = chat = ""
    for line in read("/etc/travel-nas/tg-notify.conf").splitlines():
        if line.startswith("TG_BOT_TOKEN="): tok = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("TG_CHAT_ID="): chat = line.split("=", 1)[1].strip().strip('"')
    return tok, chat
def send_document(token, chat, path):
    b = "----webdashdoc"; fn = os.path.basename(path)
    with open(path, "rb") as f: data = f.read()
    body = ("--%s\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n%s\r\n" % (b, chat)).encode()
    body += ("--%s\r\nContent-Disposition: form-data; name=\"document\"; filename=\"%s\"\r\nContent-Type: application/zip\r\n\r\n" % (b, fn)).encode()
    body += data + ("\r\n--%s--\r\n" % b).encode()
    req = urllib.request.Request("https://api.telegram.org/bot%s/sendDocument" % token, data=body,
                                 headers={"Content-Type": "multipart/form-data; boundary=" + b})
    urllib.request.urlopen(req, timeout=30)

ICON_CACHE = {}
@app.route("/api/appicon")
def api_appicon():
    u = request.args.get("u", "")
    if not u.startswith("http"): return ("", 404)
    base = u.rstrip("/")
    if base in ICON_CACHE:
        d, ct = ICON_CACHE[base]; return Response(d, mimetype=ct)
    def fetch(url):
        with urllib.request.urlopen(url, timeout=4) as r:
            return r.read(300000), r.headers.get("Content-Type", "image/png")
    try:
        html = ""
        try: html = fetch(base + "/")[0].decode("utf-8", "ignore")
        except Exception: pass
        href = ""
        for tag in re.findall(r'<link[^>]+rel="[^"]*icon[^"]*"[^>]*>', html, re.I):
            m = re.search(r'href="([^"]+)"', tag)
            if m:
                href = m.group(1)
                if re.search(r'apple-touch|android-chrome|192|180', href, re.I): break
        if href.startswith("http"): iu = href
        elif href.startswith("/"): iu = base + href
        elif href: iu = base + "/" + href
        else: iu = base + "/favicon.ico"
        data, ct = fetch(iu)
        if "image" not in ct and "icon" not in ct and data[:4] != b"\x89PNG":
            data, ct = fetch(base + "/favicon.ico")
        ICON_CACHE[base] = (data, ct); return Response(data, mimetype=ct)
    except Exception:
        return ("", 404)

@app.route("/api/smart")
def api_smart():
    src = sh(["findmnt", "-n", "-o", "SOURCE", "--target", CONF["STORAGE_MOUNT"]])
    dev = re.sub(r'p?\d+$', '', src) if src else ''
    if not dev: return jsonify({"error": "no device"}), 404
    out = sh(smart_cmd(dev), timeout=12)
    def g(*pats):
        for p in pats:
            m = re.search(p, out, re.I | re.M)
            if m: return m.group(1).strip()
        return None
    return jsonify({"device": dev,
        "model": g(r'(?:Device Model|Model Number):\s*(.+)'),
        "capacity": g(r'User Capacity:.*\[(.+?)\]', r'Total NVM Capacity:.*\[(.+?)\]', r'Namespace 1 Size.*\[(.+?)\]'),
        "health": g(r'overall-health[^:]*:\s*(\w+)'),
        "temp": g(r'Temperature[_ ]?Celsius.*?(\d+)', r'Temperature:\s*(\d+)'),
        "power_on_hours": g(r'Power[_ ]On[_ ]Hours.*?(\d[\d,]*)', r'Power On Hours:\s*([\d,]+)'),
        "power_cycles": g(r'Power[_ ]Cycle[_ ]Count.*?(\d+)', r'Power Cycles:\s*([\d,]+)'),
        "wear": g(r'Percentage Used:\s*(\d+%?)', r'Wear_Leveling_Count.*?(\d+)\s*$'),
        "realloc": g(r'Reallocated_Sector_Ct.*?(\d+)\s*$'),
        "spare": g(r'Available Spare:\s*(\d+%)')})

LOGDIR = "/mnt/storage/_logs"
@app.route("/api/logfiles")
def api_logfiles():
    out = []
    for p in sorted(glob.glob(LOGDIR + "/*.log")):
        try: out.append({"name": os.path.basename(p), "size": os.path.getsize(p)})
        except Exception: pass
    return jsonify(out)
@app.route("/api/logfile")
def api_logfile():
    name = request.args.get("name", "")
    if not re.match(r"^[\w.\-]+\.log$", name): return ("bad name", 400)
    p = os.path.join(LOGDIR, name)
    if not os.path.isfile(p): return ("not found", 404)
    return Response(sh(["tail", "-n", "400", p]), mimetype="text/plain")
@app.route("/api/naslog")
def api_naslog():
    return Response(sh(["journalctl", "-u", "nas-backup-runtime", "-n", "300", "--no-pager", "-o", "cat"], timeout=10),
                    mimetype="text/plain")
@app.route("/api/pibackup")
def api_pibackup():
    files = sorted(glob.glob("/mnt/storage/pi-config-backups/*"), key=lambda p: os.path.getmtime(p), reverse=True)
    if not files: return jsonify({"count": 0})
    f = files[0]
    return jsonify({"count": len(files), "last": os.path.basename(f),
                    "when": time.strftime("%d.%m %H:%M", time.localtime(os.path.getmtime(f))),
                    "bytes": os.path.getsize(f)})

@app.route("/api/nas-conf")
def api_nas_conf():
    p = "/etc/travel-nas/nas-backup.conf"
    if not os.path.isfile(p): return jsonify({"configured": False})
    txt = read(p)
    def val(k):
        m = re.search(r'^\s*%s=\"?([^\"\n]*)\"?' % k, txt, re.M)
        return m.group(1).strip() if m else ""
    def arr(k):
        m = re.search(r'%s=\((.*?)\)' % k, txt, re.S)
        # терпимо к «умным» кавычкам (“ ” „) — частая опечатка при правке на тач-экране
        return re.findall(u'[“”„"]([^“”„"]+)[“”„"]', m.group(1)) if m else []
    return jsonify({"configured": True, "host": val("NAS_HOST"), "user": val("NAS_USER"),
                    "dest": val("DEST"), "modules": arr("MODULES"), "excludes": arr("EXCLUDES"),
                    "auto": val("AUTO_BACKUP"), "freq": val("AUTO_BACKUP_FREQ"), "time": val("AUTO_BACKUP_TIME")})

UICONF = os.path.expanduser("~/.local/share/travel-nas-webdash-ui.json")
@app.route("/api/ui", methods=["GET", "POST"])
def api_ui():
    # UI-настройки (период графиков, accent, фон, яркость…) — на сервере, чтобы
    # переживали ребут (localStorage в kiosk-Chromium теряется при kill'е).
    if request.method == "GET":
        return jsonify(read_json(UICONF, {}))
    d = read_json(UICONF, {}); d.update(request.json or {})
    try:
        os.makedirs(os.path.dirname(UICONF), exist_ok=True)
        with open(UICONF, "w") as f: json.dump(d, f)
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500
    return jsonify({"ok": True})

@app.route("/api/events")
def api_events():
    ev = []
    ds = read_json("/var/lib/travel-nas/daily-summary.json", {})
    for s in (ds.get("events") or []):
        m = re.match(r"(\d\d)-(\d\d)-(\d{4})\s+(\d\d):(\d\d)\s+(.*)", s)
        if not m: continue
        d, mo, y, hh, mm, txt = m.groups()
        try: ts = int(time.mktime((int(y), int(mo), int(d), int(hh), int(mm), 0, 0, 0, -1)))
        except Exception: ts = 0
        low = txt.lower()
        lvl = "crit" if ("❌" in txt or "fail" in low or "error" in low) else ("warn" if "⚠" in txt else "ok")
        txt = re.sub(r"[\U0001F000-\U0001FAFF☀-➿⬀-⯿←-⇿]\s*", "", txt).strip()
        ev.append({"ts": ts, "type": "system", "title": txt, "level": lvl})
    for d in sorted(glob.glob("/mnt/storage/usb-imports/*/"), key=os.path.getmtime, reverse=True)[:10]:
        ev.append({"ts": int(os.path.getmtime(d)), "type": "photo", "title": "Photo import",
                   "sub": os.path.basename(d.rstrip("/")), "level": "ok"})
    nb = read_json("/var/lib/travel-nas/nas-backup-status.json", {})
    for m in (nb.get("modules") if isinstance(nb, dict) else []) or []:
        if m.get("last_run"):
            ev.append({"ts": m["last_run"], "type": "nas", "title": "NAS backup: " + (m.get("name") or "?"),
                       "sub": m.get("size", ""), "level": "crit" if m.get("status") == "fail" else "ok"})
    th = read_json("/var/lib/travel-nas/thermal-guard.state.json", {})
    if th.get("last_action") and th.get("last_ts"):
        ev.append({"ts": int(th["last_ts"]), "type": "thermal", "title": "Thermal: " + str(th.get("last_action")), "level": "warn"})
    # диагностики, отправленные в Telegram
    for z in glob.glob("/mnt/storage/_logs/diag-*.zip"):
        ev.append({"ts": int(os.path.getmtime(z)), "type": "system", "title": "Diagnostics exported", "sub": os.path.basename(z), "level": "ok"})
    # последний boot
    try:
        boot = int(time.time() - float(open("/proc/uptime").read().split()[0]))
        ev.append({"ts": boot, "type": "system", "title": "System booted", "level": "ok"})
    except Exception:
        pass
    # apt-история — установки/апгрейды (что менялось на устройстве)
    def _pkgnames(s, n=4):
        ps = [p.strip().split(":")[0].split(" ")[0] for p in s.split("),") if p.strip()]
        ps = [p for p in ps if p]
        return ", ".join(ps[:n]) + (f" +{len(ps) - n} more" if len(ps) > n else "")
    for f in glob.glob("/var/log/apt/history.log*"):
        try:
            txt = gzip.open(f, "rt", errors="replace").read() if f.endswith(".gz") else open(f, errors="replace").read()
        except Exception:
            continue
        for blk in txt.split("Start-Date:")[1:]:
            lines = blk.splitlines()
            try:
                ts = int(time.mktime(time.strptime(" ".join(lines[0].split())[:19], "%Y-%m-%d %H:%M:%S")))
            except Exception:
                ts = 0
            inst = upg = cmd = ""
            for ln in lines:
                t = ln.strip()
                if t.startswith("Install:"): inst = t[8:]
                elif t.startswith("Upgrade:"): upg = t[8:]
                elif t.startswith("Commandline:"): cmd = t[12:]
            if upg:
                cnt = upg.count("),") + 1
                title = f"Upgraded {cnt} package" + ("s" if cnt != 1 else "")
                if "linux-image" in upg: title += " (kernel)"
            elif inst and "update-packages" not in cmd:
                title = "Installed " + _pkgnames(inst)
            else:
                continue
            ev.append({"ts": ts, "type": "system", "title": title, "sub": "apt", "level": "ok"})
    ev = [e for e in ev if e.get("ts")]
    ev.sort(key=lambda e: e.get("ts", 0), reverse=True)
    return jsonify(ev[:120])

# ===== Photos (JPG-просмотр/отбор импортов) =====
PHOTO_ROOT = CONF["STORAGE_MOUNT"] + "/usb-imports"
THUMB_DIR = CONF["STORAGE_MOUNT"] + "/.travel-nas/photo-thumbs"
_thumb_sem = threading.Semaphore(2)   # не больше 2 vips разом — иначе Pi4 захлёбывается
def _is_jpg(n): return n.lower().endswith((".jpg", ".jpeg"))
def _safe_photo(rel):
    root = os.path.realpath(PHOTO_ROOT)
    p = os.path.realpath(os.path.join(root, rel or ""))
    return p if (p == root or p.startswith(root + os.sep)) else None

@app.route("/api/photos/sessions")
def api_photo_sessions():
    out = []
    if os.path.isdir(PHOTO_ROOT):
        for date in os.listdir(PHOTO_ROOT):
            dp = os.path.join(PHOTO_ROOT, date)
            if not os.path.isdir(dp) or date[0] in "._": continue
            for run in os.listdir(dp):
                rp = os.path.join(dp, run)
                if not os.path.isdir(rp) or run.endswith(".incomplete"): continue
                cnt = sum(sum(1 for f in fs if _is_jpg(f)) for _, _, fs in os.walk(rp))
                if cnt:
                    out.append({"id": date + "/" + run, "name": run.split("_USB_")[0],
                                "date": date, "count": cnt, "ts": int(os.path.getmtime(rp))})
    out.sort(key=lambda s: s["ts"], reverse=True)
    return jsonify(out)

@app.route("/api/photos/list")
def api_photo_list():
    base = _safe_photo(request.args.get("session", ""))
    if not base or not os.path.isdir(base): return jsonify([])
    root = os.path.realpath(PHOTO_ROOT); files = []
    for dp, dirs, fs in os.walk(base):
        dirs[:] = [d for d in dirs if d[0] not in "._" and not d.endswith(".incomplete")]
        for f in fs:
            if _is_jpg(f):
                ap = os.path.join(dp, f)
                files.append({"f": os.path.relpath(ap, root), "name": f, "ts": int(os.path.getmtime(ap))})
    files.sort(key=lambda x: x["name"])
    return jsonify(files)

@app.route("/api/photos/img")
def api_photo_img():
    ap = _safe_photo(request.args.get("f", "")); size = request.args.get("s", "")
    if not ap or not os.path.isfile(ap): return ("", 404)
    if size == "full" or not size: return send_file(ap, mimetype="image/jpeg")
    try: sz = max(80, min(2400, int(size)))
    except Exception: sz = 400
    key = hashlib.sha1(("%s|%d|%d" % (request.args.get("f"), int(os.path.getmtime(ap)), sz)).encode()).hexdigest()[:20]
    tp = os.path.join(THUMB_DIR, key + ".jpg")
    if not os.path.isfile(tp):
        with _thumb_sem:                       # сериализуем генерацию (макс 2)
            if not os.path.isfile(tp):         # пока ждали — мог уже сгенериться
                os.makedirs(THUMB_DIR, exist_ok=True)
                tmp = tp.replace(".jpg", ".%d.tmp.jpg" % os.getpid())   # атомарно: temp → rename
                try:
                    subprocess.run(["vipsthumbnail", ap, "--size", "%dx%d" % (sz, sz), "-o", tmp + "[Q=82,strip]"],
                                   timeout=40, capture_output=True)
                    if os.path.isfile(tmp): os.replace(tmp, tp)
                except Exception:
                    try: os.path.isfile(tmp) and os.remove(tmp)
                    except Exception: pass
    return send_file(tp if os.path.isfile(tp) else ap, mimetype="image/jpeg")

@app.route("/api/photos/exif")
def api_photo_exif():
    ap = _safe_photo(request.args.get("f", ""))
    if not ap or not os.path.isfile(ap): return jsonify({})
    out = sh(["exiftool", "-j", "-Make", "-Model", "-LensModel", "-FNumber", "-ExposureTime",
              "-ISO", "-FocalLength", "-DateTimeOriginal", "-ImageSize", ap], timeout=10)
    try: return jsonify(json.loads(out)[0])
    except Exception: return jsonify({})

@app.route("/api/photos/action", methods=["POST"])
def api_photo_action():
    b = request.json or {}; ap = _safe_photo(b.get("f", "")); act = b.get("action", "")
    if not ap or not os.path.isfile(ap) or act not in ("delete", "save"): return jsonify({"ok": False}), 400
    args = ["sudo", "-n", "/usr/local/bin/photo-cull.sh", act, ap]
    if act == "save" and b.get("tg"): args.append("tg")
    r = subprocess.run(args, capture_output=True, text=True, timeout=40)
    return jsonify({"ok": r.returncode == 0, "out": (r.stdout + r.stderr).strip()})

@app.route("/api/failed")
def api_failed():
    units = []
    for line in sh(["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"]).splitlines():
        f = line.split()
        if f and f[0].endswith(".service"): units.append(f[0])
    return jsonify(units)

@app.route("/api/wifi/scan")
def api_wifi_scan():
    out = sh(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "yes"], timeout=12)
    nets = []; seen = set()
    for line in out.splitlines():
        p = line.split(":")
        if len(p) < 4 or not p[1] or p[1] in seen: continue
        seen.add(p[1])
        nets.append({"ssid": p[1], "signal": int(p[2]) if p[2].isdigit() else 0,
                     "sec": ":".join(p[3:]), "active": p[0] == "*"})
    nets.sort(key=lambda n: -n["signal"])
    return jsonify(nets)

@app.route("/api/tailscale")
def api_tailscale():
    try: j = json.loads(sh(["tailscale", "status", "--json"], timeout=6) or "{}")
    except Exception: j = {}
    peers = []
    for _, p in (j.get("Peer") or {}).items():
        peers.append({"name": (p.get("HostName") or p.get("DNSName", "")).split(".")[0],
                      "ip": (p.get("TailscaleIPs") or ["?"])[0],
                      "online": p.get("Online", False), "os": p.get("OS", "")})
    peers.sort(key=lambda x: (not x["online"], x["name"]))
    return jsonify({"up": j.get("BackendState") == "Running", "peers": peers})

@app.route("/api/ts-ping", methods=["POST"])
def api_ts_ping():
    ip = (request.json or {}).get("ip", "")
    if not re.match(r"^[\d.:a-fA-F]+$", ip): return jsonify({"error": "bad"}), 400
    return jsonify({"out": sh(["tailscale", "ping", "-c", "2", ip], timeout=10)[-200:] or "no reply"})

@app.route("/api/recent")
def api_recent():
    out = sh(["find", CONF["STORAGE_MOUNT"], "-type", "f", "-mmin", "-1440",
              "-not", "-path", "*/.*", "-printf", "%T@ %s %p\n"], timeout=15)
    rows = []
    for line in out.splitlines():
        try:
            t, sz, path = line.split(" ", 2); rows.append((float(t), int(sz), path))
        except Exception: pass
    rows.sort(reverse=True)
    items = [{"path": p.replace(CONF["STORAGE_MOUNT"] + "/", ""), "size": sz} for _, sz, p in rows[:40]]
    return jsonify({"count": len(rows), "items": items})

@app.route("/api/diag", methods=["POST"])
def api_diag():
    ts = time.strftime("%Y%m%d-%H%M%S")
    zpath = "%s/_logs/diag-%s.zip" % (CONF["STORAGE_MOUNT"], ts)
    try:
        os.makedirs(os.path.dirname(zpath), exist_ok=True)
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("journal.log", sh(["journalctl", "-n", "800", "--no-pager", "-o", "short-iso"], timeout=20))
            z.writestr("kernel.log", sh(["journalctl", "-k", "-n", "300", "--no-pager"], timeout=15))
            z.writestr("failed.txt", sh(["systemctl", "--failed", "--no-pager"]))
            z.writestr("snapshot.json", json.dumps(snapshot(), indent=2))
            for jf in glob.glob("/var/lib/travel-nas/*.json"):
                try: z.write(jf, "state/" + os.path.basename(jf))
                except Exception: pass
        tok, chat = _tg_creds(); sent = False
        if tok and chat:
            try: send_document(tok, chat, zpath); sent = True
            except Exception: pass
        return jsonify({"ok": True, "path": zpath, "sent": sent})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

def _conf_path(name):
    if not name or "/" in name or ".." in name or not name.endswith(".conf"):
        return None
    return "/etc/travel-nas/" + name
@app.route("/api/config")
def api_config_get():
    p = _conf_path(request.args.get("name", ""))
    if not p: return jsonify({"error": "bad name"}), 400
    if not os.path.exists(p): return jsonify({"error": "not found"}), 404
    return jsonify({"name": os.path.basename(p), "content": read(p)})
@app.route("/api/config", methods=["POST"])
def api_config_save():
    d = request.json or {}
    p = _conf_path(d.get("name", ""))
    if not p: return jsonify({"error": "bad name"}), 400
    # нормализуем «умные» кавычки/тире (тач-клавиатура их вставляет → ломает bash-конфиг)
    content = (d.get("content", "") or "").translate({0x201c: '"', 0x201d: '"', 0x201e: '"',
               0x2018: "'", 0x2019: "'", 0x2013: "-", 0x2014: "-", 0x00a0: " "})
    try:
        r = subprocess.run(["sudo", "-n", "tee", p], input=content,
                           capture_output=True, text=True, timeout=10)
        return jsonify({"ok": r.returncode == 0, "err": r.stderr[-200:]})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 500

@app.route("/api/update/run", methods=["POST"])
def update_run():
    Path(UPDATE_LOG).parent.mkdir(parents=True, exist_ok=True)
    Path(UPDATE_LOG).write_text("Starting update…\n")
    subprocess.Popen("sudo -n /usr/local/bin/travel-nas-update >> %s 2>&1" % UPDATE_LOG, shell=True)
    return jsonify({"ok": True})

@app.route("/api/update/log")
def update_log():
    return Response(read(UPDATE_LOG, "(no run yet)"), mimetype="text/plain")

@app.route("/api/docker", methods=["POST"])
def api_docker():
    d = request.json or {}
    proj, act = d.get("project"), d.get("action")
    if act not in ("start", "stop", "restart") or not proj:
        return jsonify({"error": "bad"}), 400
    f = compose_file(proj)
    try:
        if f:
            subprocess.Popen(["docker", "compose", "-f", f, act])
        else:
            subprocess.Popen(["docker", act] + [c["name"] for c in
                              next((p["containers"] for p in snapshot()["services"]["projects"]
                                    if p["project"] == proj), [])])
        return jsonify({"ok": True})
    except Exception as e: return jsonify({"ok": False, "error": str(e)}), 500
@app.route("/api/action/<name>", methods=["POST"])
def api_action(name):
    if name == "screen": return api_screen()
    if name == "osk":   # показать/скрыть тач-клавиатуру (squeekboard) по фокусу поля
        show = "true" if (request.json or {}).get("show", True) else "false"
        uid = os.getuid()
        env = dict(os.environ, XDG_RUNTIME_DIR="/run/user/%d" % uid,
                   DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/%d/bus" % uid)
        try:
            subprocess.run(["busctl", "--user", "call", "sm.puri.OSK0", "/sm/puri/OSK0",
                            "sm.puri.OSK0", "SetVisible", "b", show], env=env, timeout=4,
                           stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        except Exception: pass
        return jsonify({"ok": True})
    if name == "power-mode":
        m = (request.json or {}).get("mode")
        cmd = ["sudo", "-n", "/usr/local/bin/power-mode.sh", m] if m in ("auto", "normal", "saver") else None
    elif name == "cpu-boost":
        mn = str((request.json or {}).get("min", ""))
        cmd = ["sudo", "-n", "/usr/local/bin/cpu-boost.sh", "on"] + ([mn] if mn.isdigit() else [])
    elif name == "restart-unit":
        u = (request.json or {}).get("unit", "")
        cmd = ["sudo", "-n", "/usr/bin/systemctl", "restart", u] if re.match(r"^[\w@.\-]+\.service$", u) else None
    elif name == "wifi-connect":
        d = request.json or {}; ssid = d.get("ssid", ""); pw = d.get("password", "")
        cmd = (["sudo", "-n", "/usr/bin/nmcli", "device", "wifi", "connect", ssid]
               + (["password", pw] if pw else [])) if ssid else None
    elif name == "nas-sched-set":
        d = request.json or {}; freq = d.get("freq", ""); tm = d.get("time", "")
        cmd = ["sudo", "-n", "/usr/local/bin/nas-schedule.sh", "set", freq, tm] \
            if freq in ("daily", "weekly") and re.match(r"^([01]\d|2[0-3]):[0-5]\d$", tm) else None
    else:
        cmd = ACTIONS.get(name)
    if not cmd: return jsonify({"error": "unknown"}), 400
    detach = name in ("reboot", "poweroff", "update", "nas-backup", "nas-dry", "nas-diff", "pi-backup", "restart-dash", "restart-tg", "force-ap")
    try:
        if detach:
            subprocess.Popen(cmd); return jsonify({"ok": True, "detached": True})
        o = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return jsonify({"ok": o.returncode == 0, "out": o.stdout[-400:], "err": o.stderr[-400:]})
    except Exception as e: return jsonify({"ok": False, "error": str(e)}), 500
def api_screen():
    d = request.json or {}
    if "brightness" in d: subprocess.run(["/usr/local/bin/dsi-backlight.sh", str(d["brightness"])])
    if d.get("backlight") in ("on", "off"):
        env = dict(os.environ, XDG_RUNTIME_DIR="/run/user/1000")
        subprocess.run(["/usr/local/bin/screen-blank.sh", d["backlight"]], env=env)
    if "rotate" in d: subprocess.Popen(["sudo", "-n", "/usr/local/bin/dsi-rotate.sh", str(d["rotate"])])
    if d.get("exit_kiosk"): subprocess.Popen(["pkill", "-f", "chromium.*localhost:%d" % CONF["PORT"]])
    return jsonify({"ok": True})

if __name__ == "__main__":
    for fn in (sampler_fast, sampler_slow, sampler_history):
        threading.Thread(target=fn, daemon=True).start()
    time.sleep(0.5)
    app.run(host=CONF["BIND"], port=CONF["PORT"], threaded=True)
