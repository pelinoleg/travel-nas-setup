#!/usr/bin/env python3
# =============================================================================
# thermal-guard.py — sustained-temperature защита для Pi
# =============================================================================
# Запускается systemd timer'ом каждую минуту. Если CPU temp держится высоко
# подряд несколько минут — поэтапно ограничивает / морозит / стопит docker
# контейнер с максимальным CPU. Когда остынет — возвращает всё назад.
#
# Стадии (по возрастанию температуры):
#   1) throttle  → `docker update --cpus=0.5`   (мягко зажимаем)
#   2) pause     → `docker pause`               (заморозка cgroup'ом)
#   3) stop      → `docker stop`                (последний ресорт)
#
# Restore автоматический когда температура < COOLDOWN_TEMP подряд COOLDOWN_MIN
# минут. Восстанавливаем cpu-limit / unpause / start обратно.
#
# Modes:
#   warn  — только TG-алёрт, никаких действий
#   auto  — реально эскалирует
#
# Команды:
#   thermal-guard.py             # обычный tick
#   thermal-guard.py --status    # JSON статус (last temp, actions)
#   thermal-guard.py --restore   # форс-restore всего что было сделано
# =============================================================================

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CONF        = Path("/etc/travel-nas/thermal-guard.conf")
STATE       = Path("/var/lib/travel-nas/thermal-guard.state.json")
LOG         = Path("/mnt/t7/_logs/thermal-guard.log")
TG_NOTIFY   = Path("/usr/local/bin/tg-notify.sh")
BACKUP_UNIT = "nas-backup-runtime"

DEFAULTS = {
    "ENABLED":               "true",
    "MODE":                  "warn",           # warn | auto
    "SUSTAINED_MIN":         "3",
    "THROTTLE_TEMP":         "80",
    "PAUSE_TEMP":            "82",
    "STOP_TEMP":             "85",
    "COOLDOWN_TEMP":         "70",
    "COOLDOWN_MIN":          "5",
    # Database-контейнеры по умолчанию защищены — stop/pause может потерять данные.
    # CasaOS отвечает за управление другими контейнерами — её не трогаем.
    "EXCLUDE_REGEX":         r"-db(-\d+)?$|^casaos",
    "EXCLUDE_DURING_BACKUP": "true",
    "CPUS_THROTTLE":         "0.5",
}


def log(msg):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def read_conf():
    """Парсит KEY=VALUE из /etc/travel-nas/thermal-guard.conf поверх дефолтов."""
    out = dict(DEFAULTS)
    if CONF.exists():
        try:
            for ln in CONF.read_text().splitlines():
                ln = ln.strip()
                if not ln or ln.startswith("#"):
                    continue
                m = re.match(r'^([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$', ln)
                if m:
                    out[m.group(1)] = m.group(2)
        except Exception as e:
            log(f"WARN: failed to parse {CONF}: {e}")
    return out


def cpu_temp():
    try:
        out = subprocess.check_output(["vcgencmd", "measure_temp"],
                                      timeout=2, stderr=subprocess.DEVNULL).decode()
        return int(float(out.split("=")[1].split("'")[0]))
    except Exception:
        return None


def nas_backup_active():
    try:
        r = subprocess.run(["systemctl", "is-active", "--quiet", BACKUP_UNIT], timeout=2)
        return r.returncode == 0
    except Exception:
        return False


def load_state():
    if not STATE.exists():
        return {"hot_consec": 0, "cool_consec": 0,
                "actions": [], "last_temp": None}
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {"hot_consec": 0, "cool_consec": 0,
                "actions": [], "last_temp": None}


def save_state(s):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(s, indent=2))
    os.replace(tmp, STATE)
    try: os.chmod(STATE, 0o644)
    except Exception: pass


def docker_top_cpu(exclude_re):
    """Возвращает [(name, cpu_pct, nano_cpus), ...] отсортированный по CPU desc.
    Фильтрует exclude_re. nano_cpus = текущий лимит (0 = no limit)."""
    try:
        out = subprocess.check_output(
            ["docker", "stats", "--no-stream",
             "--format", "{{.Name}}\t{{.CPUPerc}}"],
            timeout=10, stderr=subprocess.DEVNULL,
        ).decode()
    except Exception as e:
        log(f"docker stats failed: {e}")
        return []
    rows = []
    for ln in out.splitlines():
        parts = ln.split("\t")
        if len(parts) < 2:
            continue
        name = parts[0].strip()
        if exclude_re.search(name):
            continue
        try:
            cpu = float(parts[1].rstrip("%").strip() or "0")
        except Exception:
            cpu = 0
        # NanoCpus — текущий cpu-limit. 500_000_000 = 0.5 cpu, 0 = unlimited.
        try:
            nc = int(subprocess.check_output(
                ["docker", "inspect", "--format", "{{.HostConfig.NanoCpus}}", name],
                timeout=3, stderr=subprocess.DEVNULL,
            ).decode().strip() or "0")
        except Exception:
            nc = 0
        rows.append((name, cpu, nc))
    rows.sort(key=lambda r: r[1], reverse=True)
    return rows


def docker_action(verb, name, *extra):
    """`docker {verb} {extra} {name}`. Возвращает True если OK."""
    try:
        subprocess.run(["docker", verb, *extra, name],
                       timeout=30, check=True, capture_output=True)
        return True
    except Exception as e:
        log(f"docker {verb} {name} failed: {e}")
        return False


def tg_alert(level, title, body):
    if not TG_NOTIFY.exists():
        return
    try:
        subprocess.run([str(TG_NOTIFY), "-l", level, title, body],
                       timeout=15, check=False)
    except Exception:
        pass


def restore_all(state, dry=False):
    """Откатывает все actions. stop → start, pause → unpause, throttle → reset cpus.
    Reverse order — сначала отменяем последнюю эскалацию."""
    restored = []
    for act in reversed(state["actions"]):
        name = act["container"]
        stage = act["stage"]
        if dry:
            restored.append(f"{name} ({stage})")
            continue
        if stage == "stop":
            if docker_action("start", name):
                restored.append(f"{name} restarted")
        elif stage == "pause":
            if docker_action("unpause", name):
                restored.append(f"{name} unpaused")
        elif stage == "throttle":
            orig = act.get("original_nano_cpus", 0)
            cpus = (orig / 1e9) if orig > 0 else 0
            # docker update --cpus=0 = убрать лимит
            if docker_action("update", name, "--cpus", str(cpus)):
                restored.append(f"{name} cpu-limit restored ({cpus or 'unlimited'})")
    if not dry:
        state["actions"] = []
    return restored


def stage_for_temp(temp, conf):
    if temp >= int(conf["STOP_TEMP"]):     return "stop"
    if temp >= int(conf["PAUSE_TEMP"]):    return "pause"
    if temp >= int(conf["THROTTLE_TEMP"]): return "throttle"
    return None


STAGE_ORDER = {None: 0, "throttle": 1, "pause": 2, "stop": 3}


def find_next_target(candidates, current_actions, target_stage):
    """Берёт top-cpu кандидата у которого ещё нет такой или более тяжёлой стадии."""
    acted = {a["container"]: a["stage"] for a in current_actions}
    for name, cpu, nc in candidates:
        if STAGE_ORDER[acted.get(name)] < STAGE_ORDER[target_stage]:
            return (name, cpu, nc, acted.get(name))
    return None


def apply_stage(stage, name, cpus_throttle):
    if stage == "throttle":
        return docker_action("update", name, "--cpus", str(cpus_throttle))
    if stage == "pause":
        return docker_action("pause", name)
    if stage == "stop":
        return docker_action("stop", name)
    return False


def cmd_tick():
    conf = read_conf()
    if conf.get("ENABLED", "true").lower() != "true":
        return
    mode = conf.get("MODE", "warn").lower()
    state = load_state()
    temp = cpu_temp()
    state["last_temp"] = temp
    if temp is None:
        log("WARN: cant read CPU temp, skip")
        save_state(state)
        return

    # Backup-interlock — пока nas-backup идёт, в дела не лезем.
    if conf.get("EXCLUDE_DURING_BACKUP", "true").lower() == "true" and nas_backup_active():
        log(f"temp={temp}°C, but nas-backup-runtime active → skip")
        state["hot_consec"] = 0
        save_state(state)
        return

    sustained_min = int(conf["SUSTAINED_MIN"])
    cool_t        = int(conf["COOLDOWN_TEMP"])
    cool_min      = int(conf["COOLDOWN_MIN"])
    throttle_t    = int(conf["THROTTLE_TEMP"])

    # Обновляем счётчики
    if temp >= throttle_t:
        state["hot_consec"]  = state.get("hot_consec", 0) + 1
        state["cool_consec"] = 0
    elif temp <= cool_t:
        state["cool_consec"] = state.get("cool_consec", 0) + 1
        # hot_consec НЕ обнуляем — даём шанс восстановить только через cool
    # между cool_t и throttle_t — neutral, не трогаем счётчики

    save_state(state)
    log(f"temp={temp}°C  hot={state['hot_consec']}  cool={state['cool_consec']}  "
        f"actions={len(state['actions'])}  mode={mode}")

    # === Restore: остыли надолго → возвращаем всё ===
    if state["actions"] and state["cool_consec"] >= cool_min:
        restored = restore_all(state)
        state["cool_consec"] = 0
        save_state(state)
        if restored:
            msg = f"Pi cooled to {temp}°C — restored:\n• " + "\n• ".join(restored)
            log("RECOVERY: " + msg.replace("\n", " | "))
            tg_alert("success", "🌡 Thermal recovery", msg)
        return

    # === Escalation: hot подряд sustained_min минут ===
    if state["hot_consec"] < sustained_min:
        return

    target_stage = stage_for_temp(temp, conf)
    if target_stage is None:
        return

    exclude_re = re.compile(conf.get("EXCLUDE_REGEX", "") or "(?!)")
    candidates = docker_top_cpu(exclude_re)
    if not candidates:
        log(f"high temp {temp}°C but no eligible containers")
        return

    pick = find_next_target(candidates, state["actions"], target_stage)
    if not pick:
        log(f"high temp {temp}°C but everything is already at max stage")
        return

    name, cpu, nano_cpus, cur_stage = pick

    if mode == "warn":
        log(f"WARN-mode: would escalate {name} ({cpu}% CPU) "
            f"{cur_stage or 'normal'} → {target_stage} at {temp}°C")
        tg_alert("warning",
                 f"⚠ Thermal alert: {temp}°C × {state['hot_consec']}min",
                 f"Top CPU: `{name}` ({cpu}%)\n"
                 f"Would escalate to: `{target_stage}`.\n\n"
                 f"Действие: `MODE=auto` в `/etc/travel-nas/thermal-guard.conf` "
                 f"если хочешь автомат.")
        state["hot_consec"] = 0   # антиспам — раз в sustained_min минут
        save_state(state)
        return

    # AUTO mode → действуем
    ok = apply_stage(target_stage, name, float(conf["CPUS_THROTTLE"]))
    if ok:
        existing = next((a for a in state["actions"] if a["container"] == name), None)
        if existing:
            existing["stage"]      = target_stage
            existing["applied_ts"] = int(time.time())
        else:
            state["actions"].append({
                "container":          name,
                "stage":              target_stage,
                "original_nano_cpus": nano_cpus,
                "applied_ts":         int(time.time()),
            })
        log(f"ESCALATE: {name} ({cpu}% CPU) → {target_stage} at {temp}°C")
        cpus_info = (conf["CPUS_THROTTLE"] if target_stage == "throttle" else "—")
        tg_alert("warning",
                 f"🌡 Thermal escalation → {target_stage}",
                 f"Temp: {temp}°C × {state['hot_consec']}min\n"
                 f"Container: `{name}` ({cpu}% CPU)\n"
                 f"Action: `{target_stage}` (cpus={cpus_info})\n\n"
                 f"Restore when ≤ {cool_t}°C × {cool_min}min.")
        state["hot_consec"] = 0
        save_state(state)
    else:
        log(f"FAILED: {target_stage} on {name}")


def cmd_status():
    state = load_state()
    conf  = read_conf()
    out = {
        "enabled":   conf.get("ENABLED") == "true",
        "mode":      conf.get("MODE"),
        "last_temp": state.get("last_temp"),
        "hot_consec":  state.get("hot_consec", 0),
        "cool_consec": state.get("cool_consec", 0),
        "thresholds": {
            "throttle":    int(conf["THROTTLE_TEMP"]),
            "pause":       int(conf["PAUSE_TEMP"]),
            "stop":        int(conf["STOP_TEMP"]),
            "cool":        int(conf["COOLDOWN_TEMP"]),
            "sustained_m": int(conf["SUSTAINED_MIN"]),
            "cool_m":      int(conf["COOLDOWN_MIN"]),
        },
        "actions":   state.get("actions", []),
    }
    print(json.dumps(out, indent=2))


def cmd_restore():
    state = load_state()
    if not state["actions"]:
        print("nothing to restore")
        return
    restored = restore_all(state)
    save_state(state)
    log("MANUAL RESTORE: " + ", ".join(restored))
    print(json.dumps({"restored": restored}, indent=2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    if args.status:
        cmd_status(); return
    if args.restore:
        if os.geteuid() != 0:
            sys.stderr.write("--restore нуждается в root\n"); sys.exit(1)
        cmd_restore(); return

    if os.geteuid() != 0:
        sys.stderr.write("must run as root\n"); sys.exit(1)
    cmd_tick()


if __name__ == "__main__":
    main()
