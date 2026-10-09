#!/usr/bin/env python3
"""homelab-host: host side of the Home Lab app.

The Mac app pipes this file to `python3 - <command>` over SSH, with its parameters
prepended as HOMELAB_PARAMS, so nothing has to be installed. Installed from the
.deb it is also a small CLI:

  homelab-host setup     prepare this machine (GNOME Remote Desktop, virtual screen)
  homelab-host status    print what the app sees, as JSON

Every command prints one JSON object. Secrets arrive in HOMELAB_PARAMS or from a
prompt; they are never written to disk, argv or logs.
"""
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

VERSION = "1.3"
RDP_SCHEMA = "org.gnome.desktop.remote-desktop.rdp"
SECRETS = "org.freedesktop.secrets"
KEYRING_INTERNAL = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"

uid = os.getuid()
os.environ.setdefault("XDG_RUNTIME_DIR", "/run/user/%d" % uid)
os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/user/%d/bus" % uid)


def sh(*cmd, timeout=6, stdin=None):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=stdin).stdout.strip()
    except Exception:
        return ""


def session_bus():
    from gi.repository import Gio
    return Gio.bus_get_sync(Gio.BusType.SESSION)


def call(bus, dest, path, iface, method, args=None, timeout=4000):
    return bus.call_sync(dest, path, iface, method, args, None, 0, timeout, None).unpack()


def get_property(bus, dest, path, iface, name):
    from gi.repository import GLib
    return call(bus, dest, path, "org.freedesktop.DBus.Properties", "Get", GLib.Variant("(ss)", (iface, name)))[0]


# --------------------------------------------------------------------- status

def grd_status(system=False, password=None):
    """Parses `grdctl status`; `system` reads the remote login daemon, which needs sudo."""
    if system:
        text = sudo_run(password, ["grdctl", "--system", "status"], timeout=10)[1]
    else:
        text = sh("grdctl", "status")
    info, in_rdp = {}, False
    for line in text.splitlines():
        stripped = line.strip()
        if not line.startswith(("\t", " ")):
            in_rdp = stripped.startswith("RDP")
            continue
        if in_rdp and ":" in stripped:
            key, value = stripped.split(":", 1)
            info[key.strip()] = value.strip()
    result = {"enabled": info.get("Status") == "enabled"}
    if info.get("Port", "").isdigit():
        result["port"] = int(info["Port"])
    if info.get("TLS fingerprint"):
        result["fingerprint"] = info["TLS fingerprint"].replace(":", "").lower()
    result["hasCredentials"] = info.get("Username", "(empty)") not in ("(empty)", "")
    return result


def keyrings(bus):
    result = []
    for path in get_property(bus, SECRETS, "/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "Collections"):
        iface = "org.freedesktop.Secret.Collection"
        label = get_property(bus, SECRETS, path, iface, "Label")
        if path.endswith("/session"):
            continue
        result.append({"path": path, "label": label or os.path.basename(path),
                       "locked": bool(get_property(bus, SECRETS, path, iface, "Locked")),
                       "items": len(get_property(bus, SECRETS, path, iface, "Items"))})
    return result


def graphical_session():
    for line in sh("loginctl", "list-sessions", "--no-legend").splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[1] != str(uid):
            continue
        if sh("loginctl", "show-session", parts[0], "-p", "Type", "--value") in ("wayland", "x11"):
            return parts[0]
    return None


def polkit_open():
    """True when admin actions are authorized for this user without a dialog."""
    try:
        return subprocess.run(["pkcheck", "--action-id", "org.freedesktop.policykit.exec", "--process", str(os.getpid())],
                              capture_output=True, timeout=4).returncode == 0
    except Exception:
        return None


def metrics():
    m = {}

    def attempt(fn):
        try:
            fn()
        except Exception:
            pass

    def cpu_sample():
        with open("/proc/stat") as f:
            v = list(map(int, f.readline().split()[1:]))
        return v[3] + v[4], sum(v)

    def net_sample():
        rx = tx = 0
        for dev in os.listdir("/sys/class/net"):
            if not os.path.exists("/sys/class/net/%s/device" % dev):
                continue
            with open("/sys/class/net/%s/statistics/rx_bytes" % dev) as f:
                rx += int(f.read())
            with open("/sys/class/net/%s/statistics/tx_bytes" % dev) as f:
                tx += int(f.read())
        return rx, tx

    c0, n0, t0 = cpu_sample(), net_sample(), time.time()

    def system():
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    m["osName"] = line.split("=", 1)[1].strip().strip('"')
        m["kernel"] = os.uname().release
        m["cpuCores"] = os.cpu_count()
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    m["cpuModel"] = line.split(":", 1)[1].strip()
                    break
        m["loads"] = list(os.getloadavg())

    def temperature():
        for hw in glob.glob("/sys/class/hwmon/hwmon*"):
            with open(hw + "/name") as f:
                if f.read().strip() in ("k10temp", "coretemp", "zenpower"):
                    with open(hw + "/temp1_input") as t:
                        m["cpuTemp"] = int(t.read()) / 1000.0
                    return

    def memory():
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":")
                info[k] = int(v.split()[0]) / 1024.0
        m["memTotalMB"] = info["MemTotal"]
        m["memUsedMB"] = info["MemTotal"] - info["MemAvailable"]
        m["swapTotalMB"] = info["SwapTotal"]
        m["swapUsedMB"] = info["SwapTotal"] - info["SwapFree"]

    def disks():
        seen, result = set(), []
        with open("/proc/mounts") as f:
            for line in f:
                dev, mount, fs = line.split()[:3]
                if not dev.startswith("/dev/") or dev in seen or mount.startswith("/boot") or "/snap/" in mount:
                    continue
                if fs not in ("ext4", "ext3", "xfs", "btrfs", "zfs", "ntfs3", "fuseblk", "exfat", "f2fs"):
                    continue
                seen.add(dev)
                st = os.statvfs(mount.replace("\\040", " "))
                total = st.f_blocks * st.f_frsize / 1e9
                result.append({"mount": mount, "totalGB": total, "usedGB": total - st.f_bavail * st.f_frsize / 1e9})
        m["disks"] = result

    def gpu():
        line = sh("nvidia-smi", "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed",
                  "--format=csv,noheader,nounits").splitlines()[0]
        f = [x.strip() for x in line.split(",")]

        def num(x):
            try:
                return float(x)
            except ValueError:
                return None
        m["gpu"] = {"name": f[0].replace("NVIDIA ", "").replace("GeForce ", ""), "util": num(f[1]) or 0.0,
                    "memUsedMB": num(f[2]) or 0.0, "memTotalMB": num(f[3]) or 0.0,
                    "temp": num(f[4]), "power": num(f[5]), "fan": num(f[6])}

    def addresses():
        m.update(addresses_info())

    def services():
        units = sorted(os.path.basename(p) for p in glob.glob(os.path.expanduser("~/.config/systemd/user/*.service")))
        result = []
        if units:
            text = sh("systemctl", "--user", "show", "-p", "Id,ActiveState,SubState", *units)
            for block in text.split("\n\n"):
                kv = dict(l.split("=", 1) for l in block.splitlines() if "=" in l)
                if "Id" in kv:
                    result.append({"name": kv["Id"].rsplit(".service", 1)[0],
                                   "active": kv.get("ActiveState", ""), "sub": kv.get("SubState", "")})
        m["services"] = result
        m["failedSystem"] = len(sh("systemctl", "--failed", "--no-legend", "--plain").splitlines())
        m["failedUser"] = len(sh("systemctl", "--user", "--failed", "--no-legend", "--plain").splitlines())

    def containers():
        r = subprocess.run(["docker", "ps", "-q"], capture_output=True, text=True, timeout=4)
        if r.returncode == 0:
            m["containers"] = len(r.stdout.split())

    def top():
        rows = []
        for line in sh("ps", "-eo", "pid,pcpu,rss,comm", "--sort=-pcpu", "--no-headers").splitlines()[:7]:
            pid, cpu, rss, name = line.split(None, 3)
            if int(pid) == os.getpid() or name == "ps":   # this probe and its own ps are not news
                continue
            rows.append({"pid": int(pid), "name": name, "cpu": float(cpu), "memMB": int(rss) / 1024.0})
        m["top"] = rows[:5]

    for fn in (system, temperature, memory, disks, gpu, addresses, services, containers, top):
        attempt(fn)

    time.sleep(max(0.0, 0.3 - (time.time() - t0)))

    def rates():
        c1, n1, dt = cpu_sample(), net_sample(), time.time() - t0
        if c1[1] > c0[1]:
            m["cpuPercent"] = 100.0 * (1 - (c1[0] - c0[0]) / (c1[1] - c0[1]))
        m["rxKbps"] = (n1[0] - n0[0]) / 1024.0 / dt
        m["txKbps"] = (n1[1] - n0[1]) / 1024.0 / dt
    attempt(rates)
    return m


def addresses_info():
    info = {}
    for line in sh("ip", "-4", "-o", "addr", "show", "scope", "global").splitlines():
        parts = line.split()
        dev, addr = parts[1], parts[3].split("/")[0]
        if dev == "tailscale0":
            info["tailscaleIP"] = addr
        elif not dev.startswith(("br-", "docker", "veth", "virbr")) and "lanIP" not in info:
            info["lanIP"] = addr
    return info


def cmd_probe(p):
    out = {"hostname": os.uname().nodename, "monitors": [], "physicalConnected": [], "locked": None,
           "agentVersion": VERSION, "packageInstalled": os.path.exists("/usr/bin/homelab-host"),
           "user": os.environ.get("USER", ""), "home": os.path.expanduser("~")}
    with open("/proc/uptime") as f:
        out["uptimeSeconds"] = int(float(f.read().split()[0]))
    with open("/proc/loadavg") as f:
        out["load"] = f.read().split()[0]
    out["remoteDesktopActive"] = sh("systemctl", "--user", "is-active", "gnome-remote-desktop.service") == "active"
    out["shareMode"] = sh("gsettings", "get", RDP_SCHEMA, "screen-share-mode").strip("'")
    for path in sorted(glob.glob("/sys/class/drm/card*-*/status")):
        with open(path) as f:
            if f.read().strip() == "connected":
                out["physicalConnected"].append(os.path.basename(os.path.dirname(path)).split("-", 1)[1])
    port = p.get("sessionPort", 3390)
    lines = sh("ss", "-Htn", "state", "established", "( sport = :%d )" % port).splitlines()
    out["rdpClients"] = len([l for l in lines if l.strip()])
    listening = sh("ss", "-Hltn")
    out["listening"] = sorted({int(l.split()[3].rsplit(":", 1)[1]) for l in listening.splitlines()
                               if len(l.split()) > 3 and l.split()[3].rsplit(":", 1)[1] in
                               [str(x) for x in p.get("ports", [3389, 3390])]})
    out["polkitOpen"] = polkit_open()
    out["sudoNeedsPassword"] = not sudo_passwordless()
    try:
        bus = session_bus()
        _, monitors, logical, _ = call(bus, "org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                                       "org.gnome.Mutter.DisplayConfig", "GetCurrentState")
        primary = set()
        for lm in logical:
            if lm[4]:
                primary.update(spec[0] for spec in lm[5])
        for spec, modes, props in monitors:
            current = next((m for m in modes if m[6].get("is-current")), None)
            if current is None:
                continue
            product = spec[2] if spec[2] and spec[2] != "unknown" else props.get("display-name", spec[0])
            out["monitors"].append({"connector": spec[0], "name": product, "width": current[1], "height": current[2],
                                    "virtual": spec[0].startswith("Meta-"), "primary": spec[0] in primary})
        try:
            out["locked"] = bool(call(bus, "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
                                      "org.gnome.ScreenSaver", "GetActive")[0])
        except Exception:
            pass
        try:
            out["keyrings"] = keyrings(bus)
        except Exception:
            pass
    except Exception:
        pass
    try:
        out["metrics"] = metrics()
    except Exception:
        pass
    return out


# ---------------------------------------------------------------------- files

def cmd_ls(p):
    path = os.path.abspath(os.path.expanduser(p.get("path") or "~"))
    limit = int(p.get("limit", 400))
    out = {"path": path, "parent": os.path.dirname(path), "entries": [], "truncated": False}
    try:
        names = sorted(os.listdir(path), key=str.lower)
    except OSError as e:
        out["error"] = e.strerror or str(e)
        return out
    if not p.get("hidden"):
        names = [n for n in names if not n.startswith(".")]
    rows = []
    for name in names:
        full = os.path.join(path, name)
        try:
            st = os.lstat(full)
            link = os.path.islink(full)
            is_dir = os.path.isdir(full)
            rows.append({"name": name, "dir": is_dir, "link": link,
                         "size": 0 if is_dir else (os.stat(full).st_size if link and os.path.exists(full) else st.st_size),
                         "mtime": int(st.st_mtime)})
        except OSError:
            rows.append({"name": name, "dir": False, "link": False, "size": 0, "mtime": 0})
    rows.sort(key=lambda r: (not r["dir"], r["name"].lower()))
    out["truncated"] = len(rows) > limit
    out["entries"] = rows[:limit]
    return out


# ------------------------------------------------------------- authentication

def cmd_unlock_screen(p):
    session = graphical_session()
    if session is None:
        return {"ok": False, "error": "no graphical session"}
    r = subprocess.run(["loginctl", "unlock-session", session], capture_output=True, text=True, timeout=6)
    return {"ok": r.returncode == 0, "error": r.stderr.strip()}


def cmd_unlock_keyring(p):
    from gi.repository import GLib
    bus = session_bus()
    password = p.get("password", "")
    wanted = p.get("paths")
    _, session = call(bus, SECRETS, "/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "OpenSession",
                      GLib.Variant("(sv)", ("plain", GLib.Variant("s", ""))))
    results = []
    locked = [r for r in keyrings(bus) if r["locked"] and (not wanted or r["path"] in wanted)]
    # Keyrings with a blank password, or one the login keyring remembers, open without any prompt.
    opened, _ = call(bus, SECRETS, "/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "Unlock",
                     GLib.Variant("(ao)", ([r["path"] for r in locked],))) if locked else ([], "/")
    for ring in locked:
        if ring["path"] in opened:
            results.append({"label": ring["label"], "ok": True})
            continue
        if not password:
            results.append({"label": ring["label"], "ok": False})
            continue
        try:
            # The plain session only crosses the local session bus; the password is not stored.
            call(bus, SECRETS, "/org/freedesktop/secrets", KEYRING_INTERNAL, "UnlockWithMasterPassword",
                 GLib.Variant("(o(oayays))", (ring["path"], (session, [], list(password.encode()), "text/plain"))),
                 timeout=15000)
            results.append({"label": ring["label"], "ok": True})
        except Exception:
            results.append({"label": ring["label"], "ok": False})
    return {"ok": all(r["ok"] for r in results), "auth": all(r["ok"] for r in results) or not results,
            "results": results, "keyrings": keyrings(bus)}


def sudo_env():
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    return env


def sudo_passwordless():
    return subprocess.run(["sudo", "-n", "true"], capture_output=True, env=sudo_env()).returncode == 0


def sudo_check(password):
    """True when sudo will run: either it asks for nothing, or the password is right."""
    if sudo_passwordless():
        return True
    if not password:
        return False
    r = subprocess.run(["sudo", "-S", "-k", "-p", "", "true"], input=password + "\n", capture_output=True,
                       text=True, timeout=20, env=sudo_env())
    return r.returncode == 0


def sudo_run(password, argv, timeout=120, extra_env=None):
    passwordless = sudo_passwordless()
    cmd = ["sudo", "-n"] if passwordless else ["sudo", "-S", "-p", ""]
    if extra_env:
        cmd += ["env"] + ["%s=%s" % kv for kv in extra_env.items()]
    try:
        r = subprocess.run(cmd + list(argv), input=None if passwordless else (password or "") + "\n",
                           stdin=subprocess.DEVNULL if passwordless else None,
                           capture_output=True, text=True, timeout=timeout, env=sudo_env())
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ds" % timeout


def tail(text, lines=40):
    return "\n".join(text.splitlines()[-lines:])


def cmd_sudo(p):
    password = p.get("password", "")
    if not sudo_check(password):
        return {"ok": False, "auth": False, "code": 1, "output": ""}
    argv = p.get("argv") or ["sh", "-c", p.get("shell", "true")]
    code, output = sudo_run(password, argv, timeout=int(p.get("timeout", 120)), extra_env=p.get("env"))
    return {"ok": code == 0, "auth": True, "code": code, "output": tail(output)}


def polkit_rule_path():
    return "/etc/polkit-1/rules.d/49-homelab-%s.rules" % os.environ.get("USER", str(uid))


def cmd_polkit(p):
    """Installs or removes a rule that authorizes admin actions for this user without a dialog."""
    password = p.get("password", "")
    if not sudo_check(password):
        return {"ok": False, "auth": False}
    user = os.environ.get("USER") or sh("id", "-un")
    dest = polkit_rule_path()
    if p.get("enable"):
        rule = ("// Installed by homelab-host. Remove this file to get the password dialogs back.\n"
                "polkit.addRule(function(action, subject) {\n"
                "    if (subject.user == %s) { return polkit.Result.YES; }\n"
                "});\n" % json.dumps(user))
        tmp = os.path.join(os.environ["XDG_RUNTIME_DIR"], "homelab-polkit.rules")
        with open(tmp, "w") as f:
            f.write(rule)
        code, output = sudo_run(password, ["install", "-m", "644", "-o", "root", "-g", "root", tmp, dest])
        os.unlink(tmp)
    else:
        code, output = sudo_run(password, ["rm", "-f", dest])
    time.sleep(0.5)  # polkitd reloads its rules on change
    return {"ok": code == 0, "auth": True, "output": tail(output, 5), "polkitOpen": polkit_open()}


# ------------------------------------------------- services, containers, processes

UNIT_RE = re.compile(r"^[A-Za-z0-9@_.:\\-]+\.(service|timer)$")
CONTAINER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
UNIT_ACTIONS = ("start", "stop", "restart", "enable", "disable", "reset-failed")
UNIT_PROPS = "Id,Description,ActiveState,SubState,UnitFileState,ActiveEnterTimestampMonotonic,MemoryCurrent,MainPID,NRestarts,Result,TriggeredBy,FragmentPath"


def systemctl(scope):
    return ["systemctl", "--user"] if scope == "user" else ["systemctl"]


def uptime_seconds():
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def describe_units(scope, names, custom=()):
    """State, memory, restarts and timer of each unit, read in one systemctl call."""
    if not names:
        return []
    up, units = uptime_seconds(), []
    text = sh(*systemctl(scope), "show", "-p", UNIT_PROPS, *names, timeout=12)
    for block in text.split("\n\n"):
        kv = dict(l.split("=", 1) for l in block.splitlines() if "=" in l)
        if "Id" not in kv:
            continue
        unit = {"scope": scope, "name": kv["Id"], "description": kv.get("Description", ""),
                "active": kv.get("ActiveState", ""), "sub": kv.get("SubState", ""),
                "enabled": kv.get("UnitFileState", ""), "custom": kv["Id"] in custom,
                "result": kv.get("Result", ""), "restarts": int(kv.get("NRestarts") or 0)}
        mono = int(kv.get("ActiveEnterTimestampMonotonic") or 0)
        if mono and unit["active"] in ("active", "activating"):
            unit["activeSeconds"] = max(0, int(up - mono / 1e6))
        if (kv.get("MemoryCurrent") or "").isdigit():
            unit["memoryMB"] = int(kv["MemoryCurrent"]) / 1048576.0
        if (kv.get("MainPID") or "0") != "0":
            unit["pid"] = int(kv["MainPID"])
        if kv.get("FragmentPath"):
            unit["file"] = kv["FragmentPath"]
        timer = next((t for t in kv.get("TriggeredBy", "").split() if t.endswith(".timer")), None)
        if timer:
            unit["timer"] = timer
        units.append(unit)
    timers = sorted({u["timer"] for u in units if "timer" in u})
    if timers:
        text = sh(*systemctl(scope), "show", "-p", "Id,NextElapseUSecRealtime,ActiveState", *timers)
        info = {}
        for block in text.split("\n\n"):
            kv = dict(l.split("=", 1) for l in block.splitlines() if "=" in l)
            if "Id" in kv:
                info[kv["Id"]] = kv
        for u in units:
            kv = info.get(u.get("timer"))
            if kv:
                u["timerActive"] = kv.get("ActiveState") == "active"
                if kv.get("NextElapseUSecRealtime"):
                    u["nextRun"] = kv["NextElapseUSecRealtime"]
    return units


def cmd_services(p):
    """User services (the ones in ~/.config/systemd/user are marked custom) and loaded system services."""
    custom = {os.path.basename(f) for f in glob.glob(os.path.expanduser("~/.config/systemd/user/*.service"))}
    loaded = [l.split()[0] for l in sh("systemctl", "--user", "list-units", "--type=service", "--all",
                                         "--plain", "--no-legend").splitlines() if l.split()]
    user = describe_units("user", sorted(custom | set(loaded)), custom)
    system_names = [l.split()[0] for l in sh("systemctl", "list-units", "--type=service", "--plain",
                                              "--no-legend").splitlines() if l.split()]
    system = describe_units("system", sorted(set(system_names)))
    order = {"failed": 0, "activating": 1, "active": 2}
    for group in (user, system):
        group.sort(key=lambda u: (order.get(u["active"], 3), u["name"]))
    return {"units": user + system}


def cmd_service_action(p):
    scope, unit, action = p.get("scope"), p.get("unit", ""), p.get("action")
    if scope not in ("user", "system") or action not in UNIT_ACTIONS or not UNIT_RE.match(unit):
        return {"ok": False, "auth": True, "output": "invalid request"}
    if scope == "user":
        r = subprocess.run(systemctl("user") + [action, unit], capture_output=True, text=True, timeout=60)
        return {"ok": r.returncode == 0, "auth": True, "output": tail((r.stdout + r.stderr).strip(), 8)}
    password = p.get("password", "")
    if not sudo_check(password):
        return {"ok": False, "auth": False, "output": ""}
    code, output = sudo_run(password, ["systemctl", action, unit], timeout=60)
    return {"ok": code == 0, "auth": True, "output": tail(output, 8)}


def cmd_service_logs(p):
    scope, unit = p.get("scope"), p.get("unit", "")
    if scope not in ("user", "system") or not UNIT_RE.match(unit):
        return {"ok": False, "text": "invalid request"}
    lines = str(max(10, min(int(p.get("lines", 150)), 1000)))
    cmd = ["journalctl"] + (["--user"] if scope == "user" else []) + ["-u", unit, "-n", lines, "--no-pager", "-o", "short-iso"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    return {"ok": r.returncode == 0, "text": (r.stdout or r.stderr).strip()}


def cmd_containers(p):
    r = subprocess.run(["docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}"], capture_output=True, text=True, timeout=10)
    if r.returncode != 0:
        return {"available": False, "containers": [], "error": tail(r.stderr.strip(), 2)}
    rows = []
    for line in r.stdout.splitlines():
        try:
            c = json.loads(line)
        except ValueError:
            continue
        labels = dict(kv.split("=", 1) for kv in c.get("Labels", "").split(",") if "=" in kv)
        rows.append({"id": c.get("ID", "")[:12], "name": c.get("Names", ""), "image": c.get("Image", ""),
                     "state": c.get("State", ""), "status": c.get("Status", ""), "ports": c.get("Ports", ""),
                     "project": labels.get("com.docker.compose.project", "")})
    rows.sort(key=lambda c: (c["project"] == "", c["project"], c["name"]))
    return {"available": True, "containers": rows}


def cmd_container_action(p):
    name, action = p.get("name", ""), p.get("action")
    if action not in ("start", "stop", "restart") or not CONTAINER_RE.match(name):
        return {"ok": False, "auth": True, "output": "invalid request"}
    r = subprocess.run(["docker", action, name], capture_output=True, text=True, timeout=90)
    return {"ok": r.returncode == 0, "auth": True, "output": tail((r.stdout + r.stderr).strip(), 8)}


def cmd_container_detail(p):
    """Recent logs plus one reading of CPU and memory (the reading takes a second or two)."""
    name = p.get("name", "")
    if not CONTAINER_RE.match(name):
        return {"ok": False, "text": "invalid request"}
    lines = str(max(10, min(int(p.get("lines", 150)), 1000)))
    r = subprocess.run(["docker", "logs", "--tail", lines, name], capture_output=True, text=True, timeout=15, errors="replace")
    out = {"ok": r.returncode == 0, "text": (r.stdout + r.stderr).strip()}
    try:
        s = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{json .}}", name],
                           capture_output=True, text=True, timeout=8)
        stats = json.loads(s.stdout.splitlines()[0])
        out["cpu"], out["memory"] = stats.get("CPUPerc", ""), stats.get("MemUsage", "")
    except Exception:
        pass
    return out


def cmd_processes(p):
    """Busiest processes right now: CPU is measured over a short interval, not averaged since start."""
    import pwd
    tick, page, me = os.sysconf("SC_CLK_TCK"), os.sysconf("SC_PAGE_SIZE"), os.getpid()

    def sample():
        data = {}
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open("/proc/%s/stat" % pid) as f:
                    raw = f.read()
                name = raw[raw.index("(") + 1:raw.rindex(")")]
                rest = raw[raw.rindex(")") + 2:].split()
                data[int(pid)] = (name, int(rest[11]) + int(rest[12]), int(rest[19]), int(rest[21]))
            except (OSError, ValueError, IndexError):
                pass
        return data

    first, t0 = sample(), time.time()
    time.sleep(0.5)
    second, dt, up = sample(), time.time() - t0, uptime_seconds()
    rows = []
    for pid, (name, ticks, start, rss) in second.items():
        if pid == me or pid not in first:
            continue
        rows.append({"pid": pid, "name": name, "cpu": 100.0 * (ticks - first[pid][1]) / tick / dt,
                     "memMB": rss * page / 1048576.0, "seconds": max(0, int(up - start / tick))})
    key = "memMB" if p.get("sort") == "mem" else "cpu"
    rows.sort(key=lambda r: -r[key])
    rows = rows[:int(p.get("limit", 40))]
    for row in rows:
        try:
            uid_ = os.stat("/proc/%d" % row["pid"]).st_uid
            row["user"] = pwd.getpwuid(uid_).pw_name
            row["own"] = uid_ == uid
            with open("/proc/%d/cmdline" % row["pid"], "rb") as f:
                row["command"] = f.read().replace(b"\0", b" ").decode(errors="replace").strip()[:300]
        except (OSError, KeyError):
            row.setdefault("user", "?")
            row.setdefault("own", False)
        row.setdefault("command", "")
    return {"processes": rows, "cores": os.cpu_count()}


def cmd_process_kill(p):
    import signal
    pid, name = int(p.get("pid", 0)), p.get("signal", "TERM")
    if pid <= 1 or name not in ("TERM", "KILL"):
        return {"ok": False, "auth": True, "output": "invalid request"}
    try:
        owner = os.stat("/proc/%d" % pid).st_uid
    except OSError:
        return {"ok": False, "auth": True, "output": "process is gone"}
    if owner == uid:
        try:
            os.kill(pid, getattr(signal, "SIG" + name))
            return {"ok": True, "auth": True, "output": ""}
        except OSError as e:
            return {"ok": False, "auth": True, "output": e.strerror or str(e)}
    password = p.get("password", "")
    if not sudo_check(password):
        return {"ok": False, "auth": False, "output": ""}
    code, output = sudo_run(password, ["kill", "-s", name, str(pid)])
    return {"ok": code == 0, "auth": True, "output": tail(output, 3)}


# ------------------------------------------------------------------- docker, deeper

SECRET_KEY_RE = re.compile(r"(SECRET|PASSWORD|PASSWD|TOKEN|API_?KEY|PRIVATE|CREDENTIAL)", re.I)


def docker(*args, timeout=30, cwd=None):
    r = subprocess.run(["docker"] + list(args), capture_output=True, text=True, timeout=timeout, cwd=cwd, errors="replace")
    return r.returncode, (r.stdout + r.stderr).strip()


def cmd_docker_inspect(p):
    name = p.get("name", "")
    if not CONTAINER_RE.match(name):
        return {"ok": False, "error": "invalid request"}
    code, text = docker("inspect", name)
    if code != 0:
        return {"ok": False, "error": tail(text, 2)}
    c = json.loads(text)[0]
    cfg, host, labels = c.get("Config", {}), c.get("HostConfig", {}), c.get("Config", {}).get("Labels") or {}
    env = []
    for item in cfg.get("Env") or []:
        key, _, value = item.partition("=")
        # Values that look like secrets are not sent to the Mac at all.
        env.append({"key": key, "value": "••••••" if SECRET_KEY_RE.search(key) and value else value})
    ports = []
    for inside, binds in (c.get("NetworkSettings", {}).get("Ports") or {}).items():
        for b in binds or []:
            ports.append("%s:%s → %s" % (b.get("HostIp") or "0.0.0.0", b.get("HostPort"), inside))
        if not binds:
            ports.append("%s (não publicada)" % inside)
    return {"ok": True, "image": cfg.get("Image", ""), "created": c.get("Created", "")[:19].replace("T", " "),
            "command": " ".join((cfg.get("Entrypoint") or []) + (cfg.get("Cmd") or [])),
            "restart": (host.get("RestartPolicy") or {}).get("Name", ""),
            "health": ((c.get("State") or {}).get("Health") or {}).get("Status", ""),
            "env": sorted(env, key=lambda e: e["key"]),
            "mounts": ["%s → %s%s" % (m.get("Source") or m.get("Name", ""), m.get("Destination", ""), "" if m.get("RW") else " (somente leitura)")
                       for m in c.get("Mounts") or []],
            "networks": ["%s %s" % (n, v.get("IPAddress", "")) for n, v in (c.get("NetworkSettings", {}).get("Networks") or {}).items()],
            "ports": ports,
            "project": labels.get("com.docker.compose.project", ""),
            "composeFiles": [f for f in labels.get("com.docker.compose.project.config_files", "").split(",") if f],
            "workingDir": labels.get("com.docker.compose.project.working_dir", "")}


def compose_context(project):
    code, names = docker("ps", "-a", "--filter", "label=com.docker.compose.project=" + project, "--format", "{{.Names}}")
    first = names.splitlines()[0] if code == 0 and names else None
    if not first:
        return None
    info = cmd_docker_inspect({"name": first})
    return info if info.get("ok") and info.get("composeFiles") else None


def cmd_docker_compose(p):
    """Runs one compose verb on a project, with the same files and folder it was started from."""
    project, action = p.get("project", ""), p.get("action")
    verbs = {"up": ["up", "-d"], "down": ["down"], "restart": ["restart"], "stop": ["stop"], "start": ["start"], "pull": ["pull"]}
    if action not in verbs or not CONTAINER_RE.match(project):
        return {"ok": False, "auth": True, "output": "invalid request"}
    ctx = compose_context(project)
    if ctx is None:
        return {"ok": False, "auth": True, "output": "projeto sem arquivos compose conhecidos"}
    args = ["compose", "-p", project]
    for f in ctx["composeFiles"]:
        args += ["-f", f]
    cwd = ctx["workingDir"] if os.path.isdir(ctx["workingDir"]) else None
    code, output = docker(*(args + verbs[action]), timeout=900, cwd=cwd)
    return {"ok": code == 0, "auth": True, "output": tail(output, 14)}


def cmd_docker_remove(p):
    name = p.get("name", "")
    if not CONTAINER_RE.match(name):
        return {"ok": False, "auth": True, "output": "invalid request"}
    code, output = docker(*(["rm"] + (["-f"] if p.get("force") else []) + [name]), timeout=60)
    return {"ok": code == 0, "auth": True, "output": tail(output, 4)}


def cmd_docker_exec(p):
    name, command = p.get("name", ""), p.get("command", "")
    if not CONTAINER_RE.match(name) or not command.strip():
        return {"ok": False, "auth": True, "output": "invalid request"}
    try:
        code, output = docker("exec", name, "sh", "-c", command, timeout=int(p.get("timeout", 30)))
    except subprocess.TimeoutExpired:
        return {"ok": False, "auth": True, "output": "tempo esgotado"}
    return {"ok": code == 0, "auth": True, "output": tail(output, 80) or "(sem saída)"}


def cmd_docker_images(p):
    code, text = docker("images", "--format", "{{json .}}")
    if code != 0:
        return {"available": False, "images": []}
    used = set(docker("ps", "-a", "--format", "{{.Image}}")[1].split())
    rows = []
    for line in text.splitlines():
        try:
            i = json.loads(line)
        except ValueError:
            continue
        name = "%s:%s" % (i.get("Repository"), i.get("Tag"))
        rows.append({"id": i.get("ID", ""), "name": name, "size": i.get("Size", ""), "created": i.get("CreatedSince", ""),
                     "inUse": name in used or i.get("Repository") in used or i.get("ID", "") in used})
    return {"available": True, "images": rows}


def cmd_docker_image_remove(p):
    image = p.get("id", "")
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.:/@-]*$", image):
        return {"ok": False, "auth": True, "output": "invalid request"}
    code, output = docker("rmi", image, timeout=120)
    return {"ok": code == 0, "auth": True, "output": tail(output, 4)}


# ----------------------------------------------------------------- remote files

MAX_EDIT_BYTES = 300 * 1024


def cmd_file_read(p):
    path = os.path.abspath(os.path.expanduser(p.get("path", "")))
    if not os.path.isfile(path):
        return {"ok": False, "path": path, "error": "não é um arquivo"}
    try:
        size = os.path.getsize(path)
        if size > MAX_EDIT_BYTES:
            return {"ok": False, "path": path, "error": "arquivo grande demais para editar aqui (%d KB)" % (size // 1024)}
        if os.access(path, os.R_OK):
            with open(path, "rb") as f:
                raw = f.read()
        else:
            if not sudo_check(p.get("password", "")):
                return {"ok": False, "auth": False, "path": path, "error": "sem permissão de leitura"}
            r = subprocess.run((["sudo", "-n"] if sudo_passwordless() else ["sudo", "-S", "-p", ""]) + ["cat", path],
                               input=None if sudo_passwordless() else (p.get("password", "") + "\n").encode(),
                               capture_output=True, timeout=20)
            raw = r.stdout
        content = raw.decode("utf-8")
    except UnicodeDecodeError:
        return {"ok": False, "path": path, "error": "arquivo binário"}
    except OSError as e:
        return {"ok": False, "path": path, "error": e.strerror or str(e)}
    return {"ok": True, "auth": True, "path": path, "content": content, "writable": os.access(path, os.W_OK),
            "backup": os.path.exists(path + ".homelab-bak")}


def cmd_file_write(p):
    """Saves a text file. The first save keeps the original beside it as <name>.homelab-bak."""
    path, content, password = os.path.abspath(os.path.expanduser(p.get("path", ""))), p.get("content", ""), p.get("password", "")
    if not os.path.isfile(path) or len(content.encode()) > MAX_EDIT_BYTES:
        return {"ok": False, "auth": True, "output": "invalid request"}
    st, backup = os.stat(path), path + ".homelab-bak"
    direct = os.access(path, os.W_OK) and os.access(os.path.dirname(path), os.W_OK)
    if not direct and not sudo_check(password):
        return {"ok": False, "auth": False, "output": ""}
    tmp = os.path.join(os.path.dirname(path) if direct else os.environ["XDG_RUNTIME_DIR"], ".homelab-edit-%d" % os.getpid())
    with open(tmp, "w") as f:
        f.write(content)
    try:
        if direct:
            if not os.path.exists(backup):
                shutil.copy2(path, backup)
            os.chmod(tmp, st.st_mode & 0o7777)
            os.replace(tmp, path)
            code, output = 0, ""
        else:
            if not os.path.exists(backup):
                sudo_run(password, ["cp", "-p", path, backup])
            code, output = sudo_run(password, ["install", "-m", "%o" % (st.st_mode & 0o7777), "-o", str(st.st_uid),
                                               "-g", str(st.st_gid), tmp, path])
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    if code == 0 and p.get("reload") == "user":
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True, timeout=30)
    elif code == 0 and p.get("reload") == "system":
        sudo_run(password, ["systemctl", "daemon-reload"])
    return {"ok": code == 0, "auth": True, "output": tail(output, 4)}


# ------------------------------------------------------------ ports and firewall

def tailscale_ips():
    return set(sh("tailscale", "ip").split()) if shutil.which("tailscale") else set()


def exposure_of(address, ts_ips):
    bare = address.strip("[]").split("%")[0]
    if bare.startswith("127.") or bare == "::1":
        return "local"
    if bare in ts_ips or "%tailscale" in address:
        return "tailnet"
    return "public"


def unit_of(pid):
    try:
        with open("/proc/%d/cgroup" % pid) as f:
            names = re.findall(r"/([^/]+\.service)", f.read())
        names = [n for n in names if not n.startswith("user@")]
        return names[-1] if names else ""
    except OSError:
        return ""


def ufw_state(password=None):
    """ufw's status and the ports it allows; needs sudo to read."""
    if not shutil.which("ufw") or not sudo_check(password or ""):
        return {"state": "unknown", "allowed": [], "rules": []}
    text = sudo_run(password or "", ["ufw", "status"], timeout=10)[1]
    state = "active" if "Status: active" in text else ("inactive" if "Status: inactive" in text else "unknown")
    rules = [l.strip() for l in text.splitlines()[4:] if l.strip()]
    allowed = sorted({int(m.group(1)) for l in rules if "ALLOW" in l for m in [re.match(r"^(\d+)(/\w+)?\s", l)] if m})
    return {"state": state, "allowed": allowed, "rules": rules[:60]}


def cmd_ports(p):
    """Listening sockets with who owns them (process, systemd unit, container) and how far they reach."""
    ts_ips, owners = tailscale_ips(), {}
    code, text = docker("ps", "--format", "{{.Names}}\t{{.Ports}}") if shutil.which("docker") else (1, "")
    if code == 0:
        for line in text.splitlines():
            name, _, ports = line.partition("\t")
            for m in re.finditer(r":(\d+)->", ports):
                owners[int(m.group(1))] = name
    ss = (["sudo", "-n"] if sudo_passwordless() else []) + ["ss", "-H", "-lnp"]
    merged = {}
    for proto, flag in (("tcp", "-t"), ("udp", "-u")):
        for line in sh(*(ss + [flag]), timeout=8).splitlines():
            f = line.split()
            if len(f) < 5:
                continue
            address, _, port = f[4 if proto == "udp" and f[0] != "UNCONN" else 3].rpartition(":")
            if not port.isdigit():
                address, _, port = f[3].rpartition(":")
            if not port.isdigit():
                continue
            m = re.search(r'\(\("([^"]+)",pid=(\d+)', line)
            process, pid = (m.group(1), int(m.group(2))) if m else ("", 0)
            reach = exposure_of(address, ts_ips)
            key = (proto, int(port), reach)
            row = merged.setdefault(key, {"proto": proto, "port": int(port), "exposure": reach, "addresses": [],
                                          "process": process, "pid": pid, "unit": unit_of(pid) if pid else "",
                                          "container": owners.get(int(port), "")})
            if address not in row["addresses"]:
                row["addresses"].append(address)
    rows = sorted(merged.values(), key=lambda r: (r["proto"] != "tcp", r["port"]))
    fw = ufw_state(p.get("password"))
    for r in rows:
        r["ufwAllowed"] = r["port"] in fw["allowed"]
    return {"ports": rows, "firewall": fw}


def cmd_ufw_action(p):
    port, proto, action, password = int(p.get("port", 0)), p.get("proto", "tcp"), p.get("action"), p.get("password", "")
    if not (1 <= port <= 65535) or proto not in ("tcp", "udp") or action not in ("allow", "remove"):
        return {"ok": False, "auth": True, "output": "invalid request"}
    if not sudo_check(password):
        return {"ok": False, "auth": False, "output": ""}
    spec = "%d/%s" % (port, proto)
    argv = ["ufw", "allow", spec] if action == "allow" else ["ufw", "delete", "allow", spec]
    code, output = sudo_run(password, argv, timeout=30)
    return {"ok": code == 0, "auth": True, "output": tail(output, 3)}


# -------------------------------------------------------------------- tailscale

def read_url(argv, pattern, seconds=12, sudo_password=None):
    """Starts a login command, waits for the URL it prints and leaves it running until the user is done."""
    cmd = list(argv)
    if sudo_password is not None:
        cmd = (["sudo", "-n"] if sudo_passwordless() else ["sudo", "-S", "-p", ""]) + cmd
    log = os.path.join(os.environ["XDG_RUNTIME_DIR"], "homelab-login-%d.log" % os.getpid())
    with open(log, "w") as out:
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    if sudo_password is not None and not sudo_passwordless():
        proc.stdin.write((sudo_password + "\n").encode())
        proc.stdin.flush()
    deadline, text = time.time() + seconds, ""
    while time.time() < deadline:
        with open(log) as f:
            text = f.read()
        m = re.search(pattern, text)
        if m:
            return m.group(0), text
        if proc.poll() is not None:
            break
        time.sleep(0.4)
    return None, text


def cmd_tailscale(p):
    out = {"installed": shutil.which("tailscale") is not None, "serve": [], "peers": []}
    if not out["installed"]:
        return out
    out["version"] = sh("tailscale", "version").splitlines()[0] if sh("tailscale", "version") else ""
    try:
        st = json.loads(sh("tailscale", "status", "--json", timeout=8))
    except ValueError:
        out["state"] = "Stopped"
        return out
    me = st.get("Self") or {}
    out.update({"state": st.get("BackendState", ""), "name": (me.get("DNSName") or "").rstrip("."),
                "ips": st.get("TailscaleIPs") or [], "tailnet": (st.get("CurrentTailnet") or {}).get("Name", ""),
                "health": st.get("Health") or [], "authURL": st.get("AuthURL", "")})
    for peer in (st.get("Peer") or {}).values():
        out["peers"].append({"name": peer.get("HostName", ""), "ip": (peer.get("TailscaleIPs") or [""])[0],
                             "os": peer.get("OS", ""), "online": bool(peer.get("Online"))})
    out["peers"].sort(key=lambda x: (not x["online"], x["name"].lower()))
    try:
        serve = json.loads(sh("tailscale", "serve", "status", "--json", timeout=8) or "{}")
    except ValueError:
        serve = {}
    funnel = serve.get("AllowFunnel") or {}
    for hostport, web in (serve.get("Web") or {}).items():
        host, _, port = hostport.rpartition(":")
        for path, handler in (web.get("Handlers") or {}).items():
            out["serve"].append({"port": int(port), "path": path, "funnel": bool(funnel.get(hostport)),
                                 "target": handler.get("Proxy") or handler.get("Path") or "texto",
                                 "url": "https://%s%s%s" % (host, "" if port == "443" else ":" + port, path)})
    for port, cfg in (serve.get("TCP") or {}).items():
        if cfg.get("TCPForward"):
            out["serve"].append({"port": int(port), "path": "", "funnel": False, "target": "tcp://" + cfg["TCPForward"],
                                 "url": "%s:%s" % (out["name"], port)})
    out["serve"].sort(key=lambda e: (e["port"], e["path"]))
    return out


def cmd_tailscale_action(p):
    action, password = p.get("action"), p.get("password", "")

    def run(argv, timeout=30):
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        text = (r.stdout + r.stderr).strip()
        if r.returncode != 0 and re.search(r"access denied|operator|permission", text, re.I) and sudo_check(password):
            return sudo_run(password, argv, timeout=timeout)   # host without an operator set
        return r.returncode, text

    if action == "install":
        if not sudo_check(password):
            return {"ok": False, "auth": False, "output": ""}
        code, output = sudo_run(password, ["sh", "-c", "curl -fsSL https://tailscale.com/install.sh | sh"], timeout=420)
        return {"ok": code == 0, "auth": True, "output": tail(output, 8)}
    if not shutil.which("tailscale"):
        return {"ok": False, "auth": True, "output": "tailscale não instalado"}
    if action == "up":
        if not sudo_check(password):
            return {"ok": False, "auth": False, "output": ""}
        user = os.environ.get("USER") or sh("id", "-un")
        url, text = read_url(["tailscale", "up", "--operator=" + user], r"https://login\.tailscale\.com/\S+", sudo_password=password)
        return {"ok": True, "auth": True, "output": tail(text, 4), "url": url or ""}
    if action == "down":
        code, output = run(["tailscale", "down"])
        return {"ok": code == 0, "auth": True, "output": tail(output, 3)}
    if action in ("serve-add", "serve-remove"):
        port = int(p.get("port", 0))
        if not (1 <= port <= 65535):
            return {"ok": False, "auth": True, "output": "invalid request"}
        if action == "serve-remove":
            code, output = run(["tailscale", "funnel" if p.get("funnel") else "serve", "--https=%d" % port, "off"])
            return {"ok": code == 0, "auth": True, "output": tail(output, 3)}
        target = str(p.get("target", "")).strip()
        if target.isdigit():
            target = "http://127.0.0.1:" + target
        if not re.match(r"^https?(\+insecure)?://(127\.0\.0\.1|localhost)(:\d{1,5})?(/[\w./-]*)?$", target):
            return {"ok": False, "auth": True, "output": "destino deve ser um endereço local, como http://127.0.0.1:3000"}
        code, output = run(["tailscale", "funnel" if p.get("funnel") else "serve", "--bg", "--https=%d" % port, target])
        return {"ok": code == 0, "auth": True, "output": tail(output, 4)}
    return {"ok": False, "auth": True, "output": "invalid request"}


# ------------------------------------------------------------------- cloudflare

CF_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$")
CF_HOST_RE = re.compile(r"^(?=.{4,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,}$")
CF_QUICK_URL = r"https://[a-z0-9-]+\.trycloudflare\.com"


def quick_tunnels():
    rows = []
    for line in sh("systemctl", "--user", "list-units", "homelab-cf-*.service", "--plain", "--no-legend", "--all").splitlines():
        unit = line.split()[0]
        m = re.match(r"homelab-cf-(\d+)\.service", unit)
        if not m or "running" not in line:
            continue
        log = sh("journalctl", "--user", "-u", unit, "-n", "120", "--no-pager", "-o", "cat")
        urls = re.findall(CF_QUICK_URL, log)
        rows.append({"port": int(m.group(1)), "url": urls[-1] if urls else ""})
    return rows


def cmd_cloudflare(p):
    binary = shutil.which("cloudflared")
    out = {"installed": binary is not None, "tunnels": [], "quick": []}
    if not binary:
        return out
    out["version"] = (sh("cloudflared", "--version").split("version")[-1].split("(")[0]).strip()
    out["service"] = sh("systemctl", "is-active", "cloudflared.service") or "inactive"
    out["serviceInstalled"] = bool(sh("systemctl", "list-unit-files", "cloudflared.service", "--no-legend"))
    out["loggedIn"] = os.path.exists(os.path.expanduser("~/.cloudflared/cert.pem"))
    for candidate in ("~/.cloudflared/config.yml", "~/.cloudflared/config.yaml", "/etc/cloudflared/config.yml"):
        if os.path.exists(os.path.expanduser(candidate)):
            out["config"] = os.path.expanduser(candidate)
            break
    if out["loggedIn"]:
        try:
            r = subprocess.run(["cloudflared", "tunnel", "list", "--output", "json"], capture_output=True, text=True, timeout=20)
            for t in json.loads(r.stdout or "[]") or []:
                out["tunnels"].append({"id": t.get("id", ""), "name": t.get("name", ""), "created": (t.get("created_at") or "")[:10],
                                       "connections": len(t.get("connections") or [])})
        except Exception as e:
            out["error"] = str(e)[:160]
    out["quick"] = quick_tunnels()
    return out


def cmd_cloudflare_action(p):
    action, password = p.get("action"), p.get("password", "")

    def result(code, output, **extra):
        return dict({"ok": code == 0, "auth": True, "output": tail(output, 6)}, **extra)

    def run(*argv, timeout=60):
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()

    if action == "install":
        if not sudo_check(password):
            return {"ok": False, "auth": False, "output": ""}
        arch = sh("dpkg", "--print-architecture") or "amd64"
        deb = "/tmp/cloudflared-%d.deb" % os.getpid()
        code, output = run("curl", "-fsSL", "-o", deb,
                           "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-%s.deb" % arch, timeout=180)
        if code == 0:
            code, output = sudo_run(password, ["dpkg", "-i", deb], timeout=180)
        if os.path.exists(deb):
            os.unlink(deb)
        return result(code, output)
    if not shutil.which("cloudflared"):
        return {"ok": False, "auth": True, "output": "cloudflared não instalado"}
    if action == "login":
        url, text = read_url(["cloudflared", "tunnel", "login"], r"https://dash\.cloudflare\.com/argotunnel\S+")
        return {"ok": url is not None, "auth": True, "output": tail(text, 3), "url": url or ""}
    if action == "quick-start":
        port = int(p.get("port", 0))
        if not (1 <= port <= 65535):
            return {"ok": False, "auth": True, "output": "invalid request"}
        unit = "homelab-cf-%d" % port
        code, output = run("systemd-run", "--user", "--unit=" + unit, "--collect", shutil.which("cloudflared"),
                           "tunnel", "--no-autoupdate", "--url", "http://localhost:%d" % port)
        url = ""
        for _ in range(40):
            if code != 0:
                break
            found = re.findall(CF_QUICK_URL, sh("journalctl", "--user", "-u", unit + ".service", "-n", "120", "--no-pager", "-o", "cat"))
            if found:
                url = found[-1]
                break
            time.sleep(0.5)
        return result(code if url or code else 1, output if code else (url or "o túnel não informou o endereço"), url=url)
    if action == "quick-stop":
        port = int(p.get("port", 0))
        return result(*run("systemctl", "--user", "stop", "homelab-cf-%d.service" % port))
    if action == "tunnel-create" and CF_NAME_RE.match(p.get("name", "")):
        return result(*run("cloudflared", "tunnel", "create", p["name"]))
    if action == "tunnel-delete" and CF_NAME_RE.match(p.get("name", "")):
        return result(*run("cloudflared", "tunnel", "delete", p["name"]))
    if action == "route-dns" and CF_NAME_RE.match(p.get("name", "")) and CF_HOST_RE.match(p.get("hostname", "")):
        return result(*run("cloudflared", "tunnel", "route", "dns", p["name"], p["hostname"]))
    if action in ("service-install", "service-uninstall"):
        if not sudo_check(password):
            return {"ok": False, "auth": False, "output": ""}
        if action == "service-uninstall":
            return result(*sudo_run(password, ["cloudflared", "service", "uninstall"], timeout=60))
        token = p.get("token", "")
        if not re.match(r"^[A-Za-z0-9_=-]{20,}$", token):
            return {"ok": False, "auth": True, "output": "token inválido"}
        # cloudflared itself takes the token as an argument and writes it into its unit file.
        return result(*sudo_run(password, ["cloudflared", "service", "install", token], timeout=90))
    return {"ok": False, "auth": True, "output": "invalid request"}


# ------------------------------------------------------------- system controls

def cmd_system(p):
    """Slow-changing facts for the overview: pending updates, reboot flag, power profile, cache size."""
    out = {"rebootRequired": os.path.exists("/var/run/reboot-required")}
    try:
        r = subprocess.run(["/usr/lib/update-notifier/apt-check"], capture_output=True, text=True, timeout=20)
        total, security = (r.stderr or r.stdout).strip().split(";")[:2]
        out["updates"], out["securityUpdates"] = int(total), int(security)
    except Exception:
        pass
    if shutil.which("powerprofilesctl"):
        out["powerProfile"] = sh("powerprofilesctl", "get")
        out["powerProfiles"] = [l.strip(" *:") for l in sh("powerprofilesctl", "list").splitlines()
                                if l.rstrip().endswith(":") and not l.startswith("    ")]
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":")
                info[k] = int(v.split()[0]) / 1024.0
        out["cacheMB"] = info.get("Cached", 0) + info.get("Buffers", 0)
    except Exception:
        pass
    out["failedUser"] = len(sh("systemctl", "--user", "--failed", "--no-legend", "--plain").splitlines())
    out["failedSystem"] = len(sh("systemctl", "--failed", "--no-legend", "--plain").splitlines())
    out["sessions"] = len(sh("who").splitlines())
    return out


def cmd_system_action(p):
    """A fixed menu of maintenance actions; nothing here takes free text."""
    action, password = p.get("action"), p.get("password", "")

    def done(code, output):
        return {"ok": code == 0, "auth": True, "output": tail(output, 12)}

    def plain(*argv, timeout=60):
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()

    if action == "restart-sharing":
        return done(*plain("systemctl", "--user", "restart", "gnome-remote-desktop.service"))
    if action == "power-profile":
        profile = p.get("profile", "")
        if profile not in ("performance", "balanced", "power-saver"):
            return {"ok": False, "auth": True, "output": "invalid request"}
        return done(*plain("powerprofilesctl", "set", profile))
    if action == "docker-prune":
        code1, out1 = plain("docker", "image", "prune", "-f", timeout=120)
        code2, out2 = plain("docker", "builder", "prune", "-f", timeout=120)
        lines = [l for l in (out1 + "\n" + out2).splitlines() if "reclaimed" in l.lower()]
        return done(code1 or code2, "\n".join(lines) or out1 or out2)
    if action in ("drop-caches", "reset-failed", "suspend"):
        if not sudo_check(password):
            return {"ok": False, "auth": False, "output": ""}
        if action == "drop-caches":
            return done(*sudo_run(password, ["sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"], timeout=60))
        if action == "suspend":
            return done(*sudo_run(password, ["systemctl", "suspend"], timeout=30))
        plain("systemctl", "--user", "reset-failed")
        return done(*sudo_run(password, ["systemctl", "reset-failed"], timeout=30))
    return {"ok": False, "auth": True, "output": "invalid request"}


# ---------------------------------------------------------------------- setup

def cmd_detect(p):
    out = {"user": os.environ.get("USER") or sh("id", "-un"), "hostname": os.uname().nodename,
           "home": os.path.expanduser("~"), "agentVersion": VERSION,
           "packageInstalled": os.path.exists("/usr/bin/homelab-host")}
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    out["osName"] = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    out["desktop"] = sh("gnome-shell", "--version")
    out["graphicalSession"] = graphical_session() is not None
    out["hasGrd"] = shutil.which("grdctl") is not None
    out["hasOpenssl"] = shutil.which("openssl") is not None
    out["hasApt"] = shutil.which("apt-get") is not None
    try:
        import gi  # noqa: F401
        out["hasGi"] = True
    except Exception:
        out["hasGi"] = False
    out.update(addresses_info())
    if shutil.which("tailscale"):
        try:
            me = json.loads(sh("tailscale", "status", "--json"))["Self"]
            out["tailscaleName"] = me["DNSName"].rstrip(".")
        except Exception:
            pass
    out["sudoNeedsPassword"] = not sudo_passwordless()
    if out["hasGrd"]:
        out["rdp"] = grd_status()
        password = p.get("password")
        if sudo_check(password):
            login = grd_status(system=True, password=password)
            if login.get("enabled") and login.get("fingerprint"):
                out["loginRdp"] = login
    out["smbShares"] = [l.split("|")[1] for l in sh("smbclient", "-gNL", "localhost").splitlines()
                        if l.startswith("Disk|") and not l.split("|")[1].endswith("$")]
    return out


def cmd_install_package(p):
    """Installs the uploaded .deb with apt, so its dependencies come along."""
    password = p.get("password", "")
    if not sudo_check(password):
        return {"ok": False, "auth": False}
    deb = os.path.abspath(os.path.expanduser(p["path"]))
    code, output = sudo_run(password, ["apt-get", "install", "-y", deb], timeout=600,
                            extra_env={"DEBIAN_FRONTEND": "noninteractive"})
    try:
        os.unlink(deb)
    except OSError:
        pass
    return {"ok": code == 0, "auth": True, "output": tail(output, 15)}


def set_credentials(user, password):
    """Answers grdctl's own prompts through a pty, so the credentials stay out of argv."""
    import pty
    master, slave = pty.openpty()
    proc = subprocess.Popen(["grdctl", "rdp", "set-credentials"], stdin=slave, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)
    os.close(slave)
    try:
        for line in (user, password):
            time.sleep(0.4)
            os.write(master, line.encode() + b"\n")
        return proc.wait(timeout=20) == 0
    except Exception:
        proc.kill()
        return False
    finally:
        os.close(master)


def cmd_setup(p):
    """Turns on desktop sharing with a virtual screen. Safe to run again: an existing certificate is kept."""
    steps = []

    def step(name, ok, detail=""):
        steps.append({"name": name, "ok": bool(ok), "detail": detail})
        return ok

    if shutil.which("grdctl") is None:
        step("gnome-remote-desktop", False, "grdctl not found; install the homelab-host package first")
        return {"ok": False, "steps": steps}
    status = grd_status()
    port = int(p.get("port") or status.get("port") or 3390)

    if not status.get("fingerprint"):
        folder = os.path.expanduser("~/.local/share/gnome-remote-desktop/homelab")
        os.makedirs(folder, mode=0o700, exist_ok=True)
        crt, key = os.path.join(folder, "tls.crt"), os.path.join(folder, "tls.key")
        r = subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:4096", "-days", "3650", "-nodes", "-x509",
                            "-subj", "/CN=" + os.uname().nodename, "-out", crt, "-keyout", key],
                           capture_output=True, text=True, timeout=120)
        ok = r.returncode == 0
        if ok:
            os.chmod(key, 0o600)
            ok = subprocess.run(["grdctl", "rdp", "set-tls-cert", crt]).returncode == 0 \
                and subprocess.run(["grdctl", "rdp", "set-tls-key", key]).returncode == 0
        if not step("certificate", ok, "created" if ok else r.stderr.strip()[-200:]):
            return {"ok": False, "steps": steps}
    else:
        step("certificate", True, "kept")

    if p.get("rdpUser") and p.get("rdpPassword"):
        if not step("credentials", set_credentials(p["rdpUser"], p["rdpPassword"]) and grd_status().get("hasCredentials")):
            return {"ok": False, "steps": steps}
    elif not step("credentials", status.get("hasCredentials"), "kept" if status.get("hasCredentials") else "missing"):
        return {"ok": False, "steps": steps}

    commands = [("port", ["grdctl", "rdp", "set-port", str(port)]),
                ("control", ["grdctl", "rdp", "disable-view-only"]),
                ("enable", ["grdctl", "rdp", "enable"]),
                ("virtual screen", ["gsettings", "set", RDP_SCHEMA, "screen-share-mode", "extend"]),
                ("service", ["systemctl", "--user", "enable", "--now", "gnome-remote-desktop.service"])]
    for name, argv in commands:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        if not step(name, r.returncode == 0, r.stderr.strip()[-200:]):
            return {"ok": False, "steps": steps}
    final = grd_status()
    return {"ok": bool(final.get("enabled") and final.get("fingerprint")), "steps": steps, "rdp": final}


# ------------------------------------------------------------------------ cli

COMMANDS = {"probe": cmd_probe, "ls": cmd_ls, "unlock-screen": cmd_unlock_screen,
            "unlock-keyring": cmd_unlock_keyring, "sudo": cmd_sudo, "polkit": cmd_polkit,
            "detect": cmd_detect, "install-package": cmd_install_package, "setup": cmd_setup,
            "services": cmd_services, "service-action": cmd_service_action, "service-logs": cmd_service_logs,
            "containers": cmd_containers, "container-action": cmd_container_action,
            "container-detail": cmd_container_detail, "processes": cmd_processes, "process-kill": cmd_process_kill,
            "system": cmd_system, "system-action": cmd_system_action,
            "docker-inspect": cmd_docker_inspect, "docker-compose": cmd_docker_compose, "docker-remove": cmd_docker_remove,
            "docker-exec": cmd_docker_exec, "docker-images": cmd_docker_images, "docker-image-remove": cmd_docker_image_remove,
            "file-read": cmd_file_read, "file-write": cmd_file_write, "ports": cmd_ports, "ufw-action": cmd_ufw_action,
            "tailscale": cmd_tailscale, "tailscale-action": cmd_tailscale_action,
            "cloudflare": cmd_cloudflare, "cloudflare-action": cmd_cloudflare_action}


def interactive_setup():
    import getpass
    print("Home Lab: preparar este computador para acesso remoto\n")
    status = grd_status() if shutil.which("grdctl") else {}
    params = {}
    if status.get("hasCredentials"):
        print("Já existe uma credencial RDP configurada; ela será mantida.")
    else:
        params["rdpUser"] = input("Usuário RDP (novo): ").strip()
        params["rdpPassword"] = getpass.getpass("Senha RDP (nova): ")
    result = cmd_setup(params)
    for s in result["steps"]:
        print("  [%s] %s %s" % ("ok" if s["ok"] else "FALHOU", s["name"], s["detail"]))
    if result["ok"]:
        info = cmd_detect({})
        print("\nPronto. No app Home Lab do Mac, adicione um ambiente com:")
        print("  SSH:          %s@%s" % (info["user"], info.get("tailscaleName") or info.get("lanIP") or info["hostname"]))
        print("  Porta RDP:    %s" % result["rdp"].get("port"))
        print("  Fingerprint:  %s" % result["rdp"].get("fingerprint"))
    return 0 if result["ok"] else 1


def main():
    raw = globals().get("HOMELAB_PARAMS")
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if raw is None and command == "setup" and sys.stdin.isatty():
        return interactive_setup()
    if raw is None and command == "status":
        command = "probe"
    if command not in COMMANDS:
        print(__doc__.strip() if "__doc__" in globals() and __doc__ else "usage: homelab-host setup|status")
        return 2
    params = json.loads(base64.b64decode(raw)) if raw else {}
    try:
        print(json.dumps(COMMANDS[command](params)))
    except Exception as e:
        print(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
