#!/usr/bin/env python3
import argparse
import base64
import gzip
import hashlib
import json
import math
import os
import random
import secrets
import shlex
import shutil
import subprocess
import threading
import sys
import time
import urllib.request

import alerts

CLOUD = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(CLOUD, "..", "..", ".."))
sys.path.insert(0, CLOUD)
from common import (Api, ApiError, CAP_EUR, CREDIT_EUR, LABEL, billed_hours, box_cost, deadline_offset, iso,
                    ledger_spent, load_json, next_hour_boundary, parse_time, read_token, save_json)
from safety import (GUARD, Interrupted, StepFailed, gen_host_key, host_keys_cloud_config, known_hosts_path, nap,
                    run_cmd, ssh_opts, ssh_user, wait_ssh, write_known_hosts)

CONF = os.environ.get("BOTSIM_CONFIG", os.path.expanduser("~/.config/botsim"))
LEDGER = os.environ.get("BOTSIM_LEDGER", os.path.join(CLOUD, "spend.json"))
SPEND_MD = os.path.join(os.path.dirname(LEDGER), "SPEND.md")
CURRENT = os.path.join(CONF, "current_run.json")
RESULTS = os.environ.get("BOTSIM_RESULTS", os.path.join(REPO, "tools", "botsim", "results"))
SSH_KEY_NAME = "botsim-hetzner"
SSH_KEY = os.path.expanduser(os.environ.get("BOTSIM_SSH_KEY", "~/.ssh/botsim_hetzner"))
IMAGE = "ubuntu-24.04"
DEFAULT_TYPES = "cpx62,ccx33"
DEFAULT_LOCATIONS = "fsn1,nbg1,hel1"
LIMITS = {"shared": 17, "dedicated": 144}
FATAL_CODES = {"unauthorized", "forbidden", "resource_limit_exceeded", "rate_limit_exceeded", "invalid_input", "uniqueness_error"}


def server_loc(s):
    return (s.get("location") or (s.get("datacenter") or {}).get("location") or {}).get("name", "?")

def api():
    return Api(read_token())


def say(*a):
    print(*a, flush=True)


SHARED_REMOTE = os.environ.get("BOTSIM_SHARED_REMOTE", "git@github.com:JupiterianSoul/botlatro-results.git")
SHARED_CACHE = os.environ.get("BOTSIM_SHARED_CACHE", os.path.join(CONF, "shared-results"))
SHARED_PATH = "ledger/spend.json"
SHARED_BRANCH = "main"
SHARED_PENDING = os.path.join(CONF, "shared_ledger_pending")
SHARED = {"read": False, "ok": False, "error": None, "data": None}
GIT_AUTHOR = ["-c", "user.name=Gabriel Quart", "-c", "user.email=gabriel.quart.15@gmail.com"]


def shared_off():
    return os.environ.get("BOTSIM_SHARED_LEDGER") == "off"


def adj_id(x):
    if x.get("id"):
        return str(x["id"])
    raw = "%s|%s|%s" % (x.get("date", ""), x.get("note", ""), float(x.get("eur", 0)))
    return "adj-" + hashlib.sha1(raw.encode()).hexdigest()[:12]


def merge_server(x, y):
    out = dict(y)
    out.update({k: v for k, v in x.items() if v is not None})
    dx, dy = x.get("deleted"), y.get("deleted")
    if dx and dy:
        ex, ey = bool(x.get("deleted_estimated")), bool(y.get("deleted_estimated"))
        if ex != ey:
            pick = y if ex else x
        else:
            pick = x if float(dx) >= float(dy) else y
    else:
        pick = x if dx else y
    out["deleted"] = pick.get("deleted")
    if pick.get("deleted_estimated"):
        out["deleted_estimated"] = True
    else:
        out.pop("deleted_estimated", None)
    return out


def union_ledgers(a, b):
    if not b:
        a = dict(a)
        a["adjustments"] = [dict(x, id=adj_id(x)) for x in a.get("adjustments", [])]
        return a
    out = {"cap_eur": min(float(a.get("cap_eur", CAP_EUR)), float(b.get("cap_eur", CAP_EUR))),
           "credit_eur": float(a.get("credit_eur", b.get("credit_eur", CREDIT_EUR)))}
    servers = {}
    for e in list(b.get("servers", [])) + list(a.get("servers", [])):
        servers[e["id"]] = merge_server(e, servers[e["id"]]) if e["id"] in servers else dict(e)
    out["servers"] = sorted(servers.values(), key=lambda e: (float(e.get("created") or 0), str(e["id"])))
    adj = {}
    for x in list(b.get("adjustments", [])) + list(a.get("adjustments", [])):
        adj[adj_id(x)] = dict(x, id=adj_id(x))
    out["adjustments"] = list(adj.values())
    for k, v in list(b.items()) + list(a.items()):
        if k not in out:
            out[k] = v
    return out


def git_env():
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    if ":" in SHARED_REMOTE and not os.path.exists(SHARED_REMOTE):
        key = os.path.join(CONF, "results_deploy_key")
        kh = os.path.join(CONF, "github_known_hosts")
        env["GIT_SSH_COMMAND"] = "ssh -i %s -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes" % (
            shlex.quote(key), shlex.quote(kh))
    return env


def sgit(*args, check=True):
    r = subprocess.run(["git"] + GIT_AUTHOR + list(args), cwd=SHARED_CACHE, env=git_env(), capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise StepFailed("git %s: %s" % (args[0], (r.stderr or r.stdout).strip()[-300:]))
    return r


def fetch_shared():
    if ":" in SHARED_REMOTE and not os.path.exists(SHARED_REMOTE):
        for need in ("results_deploy_key", "github_known_hosts"):
            if not os.path.isfile(os.path.join(CONF, need)):
                raise StepFailed("missing %s" % os.path.join(CONF, need))
    os.makedirs(SHARED_CACHE, exist_ok=True)
    if not os.path.isdir(os.path.join(SHARED_CACHE, ".git")):
        sgit("init", "-q")
        sgit("remote", "add", "origin", SHARED_REMOTE)
    sgit("remote", "set-url", "origin", SHARED_REMOTE)
    r = sgit("fetch", "-q", "origin", SHARED_BRANCH, check=False)
    if r.returncode != 0:
        ls = sgit("ls-remote", "--heads", "origin", check=False)
        if ls.returncode != 0 or ("refs/heads/" + SHARED_BRANCH) in ls.stdout:
            raise StepFailed("git fetch: %s" % (r.stderr or r.stdout).strip()[-300:])
        sgit("checkout", "-q", "-B", SHARED_BRANCH)
        return None
    sgit("checkout", "-q", "-f", "-B", SHARED_BRANCH, "origin/" + SHARED_BRANCH)
    sgit("reset", "-q", "--hard", "origin/" + SHARED_BRANCH)
    return load_json(os.path.join(SHARED_CACHE, SHARED_PATH), None)


def read_shared(force=False):
    if shared_off():
        return None
    if SHARED["read"] and not force:
        return SHARED["data"]
    SHARED["read"] = True
    try:
        SHARED["data"] = fetch_shared()
        SHARED["ok"], SHARED["error"] = True, None
    except (StepFailed, OSError, subprocess.SubprocessError, ValueError) as e:
        SHARED["ok"], SHARED["error"], SHARED["data"] = False, str(e), None
    return SHARED["data"]


def require_shared():
    if shared_off():
        return
    read_shared(force=True)
    if not SHARED["ok"]:
        raise SystemExit("REFUSED: the shared ledger (%s in %s) cannot be read: %s. Nothing was created." % (SHARED_PATH, SHARED_REMOTE, SHARED["error"]))


def push_shared(led):
    for attempt in range(4):
        remote = fetch_shared()
        merged = union_ledgers(led, remote)
        path = os.path.join(SHARED_CACHE, SHARED_PATH)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if remote == merged:
            return merged
        save_json(path, merged)
        sgit("add", SHARED_PATH)
        sgit("commit", "-q", "-m", "ledger: %.2f EUR spent" % ledger_spent(merged), check=False)
        r = sgit("push", "-q", "origin", "HEAD:" + SHARED_BRANCH, check=False)
        if r.returncode == 0:
            return merged
        led = merged
        nap(1 + attempt, "ledger push")
    raise StepFailed("git push kept failing")


def sync_shared(led):
    if shared_off():
        return led
    try:
        merged = push_shared(led)
        SHARED.update(read=True, ok=True, error=None, data=merged)
        if os.path.exists(SHARED_PENDING):
            os.remove(SHARED_PENDING)
        return merged
    except (StepFailed, OSError, subprocess.SubprocessError, ValueError) as e:
        os.makedirs(CONF, exist_ok=True)
        with open(SHARED_PENDING, "w") as f:
            f.write("%s %s\n" % (iso(time.time()), e))
        say("warning: could not push the shared ledger (%s); kept locally, retried at the next call" % e)
        return led


def local_ledger():
    return load_json(LEDGER, None) or {"cap_eur": CAP_EUR, "credit_eur": CREDIT_EUR, "servers": [], "adjustments": []}


def ledger():
    led = local_ledger()
    shared = read_shared()
    led = union_ledgers(led, shared)
    if SHARED["ok"] and (os.path.exists(SHARED_PENDING) or shared != led):
        led = sync_shared(led)
    return led


def write_ledger(led):
    led = union_ledgers(led, read_shared())
    save_json(LEDGER, led)
    if not shared_off():
        led = sync_shared(led)
        save_json(LEDGER, led)
    now = time.time()
    spent = ledger_spent(led, now)
    cap = float(led.get("cap_eur", CAP_EUR))
    lines = [
        "# botsim Hetzner spending",
        "",
        "Generated by `hz.py` from `spend.json`. Do not edit by hand; add corrections to `adjustments` in `spend.json`.",
        "",
        "Hard cap: **%.2f EUR total, VAT included**. The %.2f EUR prepaid credit counts toward it, it is not extra." % (cap, float(led.get("credit_eur", CREDIT_EUR))),
        "Hetzner bills every started hour, so each box costs `started hours x gross hourly price` (server plus its IPv4 address).",
        "",
        "| | EUR |",
        "| --- | ---: |",
        "| spent so far (as of %s) | %.2f |" % (iso(now), spent),
        "| left under the cap | %.2f |" % (cap - spent),
        "",
        "## Servers",
        "",
        "| run | name | type | location | EUR/h gross | created (UTC) | deleted (UTC) | hours | EUR |",
        "| --- | --- | --- | --- | ---: | --- | --- | ---: | ---: |",
    ]
    for e in led.get("servers", []):
        end = e.get("deleted") or now
        deleted = iso(e["deleted"]) + (" (est.)" if e.get("deleted_estimated") else "") if e.get("deleted") else "still running"
        lines.append("| %s | %s | %s | %s | %.4f | %s | %s | %d | %.4f |" % (
            e.get("run", ""), e["name"], e["type"], e.get("location", ""), e["price_hourly_gross"], iso(e["created"]), deleted,
            billed_hours(e["created"], end), box_cost(e["created"], end, e["price_hourly_gross"])))
    if not led.get("servers"):
        lines.append("| | none yet | | | | | | | |")
    if led.get("adjustments"):
        lines += ["", "## Adjustments", "", "| date | note | EUR |", "| --- | --- | ---: |"]
        for a in led["adjustments"]:
            lines.append("| %s | %s | %.2f |" % (a.get("date", ""), a.get("note", ""), float(a.get("eur", 0))))
    lines += ["", "\"est.\" means the box was gone when the ledger was synced (deleted by its own watchdog or the dashboard Stop); the end time is then the earlier of the sync time and its deadline plus 5 minutes, so the figure errs high.", ""]
    with open(SPEND_MD, "w") as f:
        f.write("\n".join(lines))


def sync_ledger(a, led=None, servers=None):
    led = led or ledger()
    if servers is None:
        servers = a.servers()
    live = {s["id"] for s in servers}
    now = time.time()
    changed = False
    for e in led.get("servers", []):
        if not e.get("deleted") and e["id"] not in live:
            e["deleted"] = min(now, float(e.get("deadline") or now) + 300)
            e["deleted_estimated"] = True
            changed = True
    known = {e["id"] for e in led.get("servers", [])}
    for s in servers:
        if s["id"] not in known:
            say("warning: server %s (%s) is labeled botsim=1 but not in the ledger, adding it" % (s["name"], s["id"]))
            led["servers"].append({"id": s["id"], "name": s["name"], "run": s.get("labels", {}).get("botsim-run", "?"),
                                   "type": s["server_type"]["name"], "location": server_loc(s),
                                   "price_hourly_gross": price_of_server(s), "created": parse_time(s["created"]),
                                   "deadline": float(s.get("labels", {}).get("botsim-deadline") or 0) or None, "deleted": None})
            changed = True
    if changed:
        write_ledger(led)
    return led


def price_of_server(s):
    loc = server_loc(s)
    for p in s["server_type"].get("prices", []):
        if p["location"] == loc:
            return float(p["price_hourly"]["gross"]) + 0.00096
    return 0.0


def catalog(a):
    types = {t["name"]: t for t in a.get("/server_types?per_page=50")["server_types"]}
    pricing = a.get("/pricing")["pricing"]
    ipv4 = {}
    for pi in pricing.get("primary_ips", []):
        if pi.get("type") == "ipv4":
            for p in pi["prices"]:
                ipv4[p["location"]] = float(p["price_hourly"]["gross"])
    return types, ipv4, pricing


def location_open(t, loc):
    if "locations" not in t:
        return True
    for l in t["locations"]:
        if l.get("name") == loc:
            return bool(l.get("available", True)) and not l.get("deprecation")
    return False


def cheapest_available(types, ipv4, locs, cpu_type=None, arch="x86"):
    best = None
    for t in types.values():
        if t.get("deprecated") or t.get("deprecation") or (cpu_type and t.get("cpu_type") != cpu_type) or t.get("architecture", arch) != arch:
            continue
        for p in t.get("prices", []):
            if p["location"] in locs and location_open(t, p["location"]):
                price = float(p["price_hourly"]["gross"]) + ipv4.get(p["location"], 0.0)
                if best is None or price < best[1]:
                    best = (t["name"], price)
    return best


def parse_types(spec):
    out = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        name, _, n = part.partition(":")
        out += [name.lower()] * int(n or 1)
    return out


def make_plan(a, args):
    types, ipv4, pricing = catalog(a)
    locs = [x.strip() for x in args.locations.split(",") if x.strip()]
    boxes = []
    for name in parse_types(args.types):
        t = types.get(name)
        if not t:
            raise SystemExit("unknown server type: %s" % name)
        if t.get("deprecated") or t.get("deprecation"):
            raise SystemExit("server type %s is deprecated" % name)
        prices = {p["location"]: float(p["price_hourly"]["gross"]) for p in t["prices"]}
        options = [(l, prices[l] + ipv4.get(l, 0.0)) for l in locs if l in prices and location_open(t, l)]
        if not options:
            alt = cheapest_available(types, ipv4, locs, t.get("cpu_type"))
            raise SystemExit("%s is not available in %s right now (Hetzner lists it as sold out or not offered there)%s" % (
                name, ",".join(locs), ("; cheapest available %s type: %s at %.4f EUR/h" % (t.get("cpu_type"), alt[0], alt[1])) if alt else ""))
        loc, price = options[0]
        boxes.append({"type": name, "cores": t["cores"], "cpu_type": t["cpu_type"], "memory": t["memory"], "location": loc,
                      "price_hourly_gross": round(price, 6), "fallback": [l for l, p in options[1:] if p <= price + 1e-9]})
    used = {}
    for b in boxes:
        used[b["cpu_type"]] = used.get(b["cpu_type"], 0) + b["cores"]
    limits = {"shared": args.limit_shared, "dedicated": args.limit_dedicated}
    over = [k for k, v in used.items() if v > limits.get(k, 0)]
    hours = float(args.hours)
    billed = math.ceil(hours - 1e-9)
    cost = sum(b["price_hourly_gross"] for b in boxes) * billed
    led = ledger()
    spent = ledger_spent(led)
    cap = float(led.get("cap_eur", CAP_EUR))
    return {"boxes": boxes, "hours": hours, "billed_hours": billed, "cost": cost, "spent": spent, "cap": cap,
            "credit": float(led.get("credit_eur", CREDIT_EUR)), "used": used, "limits": limits, "over_limits": over,
            "vat": pricing.get("vat_rate"), "currency": pricing.get("currency"),
            "run_cap": args.spend_cap if args.spend_cap is not None else cost}


def print_plan(p):
    say("%-4s %-7s %5s %-10s %-9s %s" % ("box", "type", "cores", "cpu", "location", "EUR/h gross (server + IPv4)"))
    for i, b in enumerate(p["boxes"]):
        say("%-4d %-7s %5d %-10s %-9s %.5f" % (i, b["type"], b["cores"], b["cpu_type"], b["location"], b["price_hourly_gross"]))
    say("")
    say("hours           %.2f (billed per started hour: %d)" % (p["hours"], p["billed_hours"]))
    say("this run        %.4f EUR incl. %s%% VAT (%d boxes x %d h)" % (p["cost"], str(p["vat"]).rstrip("0").rstrip("."), len(p["boxes"]), p["billed_hours"]))
    say("run spend cap   %.2f EUR" % p["run_cap"])
    say("spent so far    %.4f EUR (ledger)" % p["spent"])
    say("total cap       %.2f EUR incl. VAT (the %.2f EUR prepaid credit counts toward it)" % (p["cap"], p["credit"]))
    after = p["spent"] + p["cost"]
    say("after this run  %.4f EUR spent, %.4f EUR left" % (after, p["cap"] - after))
    say("limits          " + ", ".join("%s %d/%d" % (k, p["used"].get(k, 0), v) for k, v in p["limits"].items()) +
        ("  OVER: " + ",".join(p["over_limits"]) if p["over_limits"] else "  ok"))


def plan_problems(p):
    probs = []
    if p["spent"] + p["cost"] > p["cap"] + 1e-9:
        probs.append("run would bring total spend to %.2f EUR, over the %.2f EUR cap" % (p["spent"] + p["cost"], p["cap"]))
    if p["cost"] > p["run_cap"] + 1e-9:
        probs.append("run costs %.2f EUR, over its spend cap of %.2f EUR (lower --hours or fewer boxes)" % (p["cost"], p["run_cap"]))
    if p["over_limits"]:
        probs.append("core limits exceeded for %s" % ",".join(p["over_limits"]))
    if not p["boxes"]:
        probs.append("no boxes")
    return probs


UNITS = {
    "botsim-watchdog.service": "[Unit]\nDescription=botsim watchdog (deletes this server at its deadline)\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /usr/local/lib/botsim/boxctl.py tick\n",
    "botsim-watchdog.timer": "[Unit]\nDescription=botsim watchdog timer\n[Timer]\nOnBootSec=20\nOnUnitActiveSec=30\nAccuracySec=5\n[Install]\nWantedBy=timers.target\n",
    "botsim-stop.path": "[Unit]\nDescription=botsim stop request\n[Path]\nPathExists=/opt/botsim/run/STOP_REQUEST\n[Install]\nWantedBy=paths.target\n",
    "botsim-stop.service": "[Unit]\nDescription=botsim stop (save, collect, delete)\n[Service]\nType=oneshot\nTimeoutStartSec=900\nExecStart=/usr/bin/python3 /usr/local/lib/botsim/boxctl.py stop\n",
    "botsim-dashboard.service": "[Unit]\nDescription=botsim dashboard\nAfter=network-online.target\n[Service]\nUser=botsim\nEnvironment=PYTHONUNBUFFERED=1\nExecStart=/usr/bin/python3 /opt/botsim/repo/tools/botsim/cloud/dashboard.py --box\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n",
    "botsim-backup.service": "[Unit]\nDescription=botsim results backup to GitHub\n[Service]\nType=oneshot\nTimeoutStartSec=900\nExecStart=/usr/bin/python3 /usr/local/lib/botsim/boxctl.py backup\n",
    "botsim-backup.timer": "[Unit]\nDescription=botsim results backup timer\n[Timer]\nOnBootSec=10min\nOnUnitActiveSec=10min\n[Install]\nWantedBy=timers.target\n",
    "botsim-job.service": "[Unit]\nDescription=botsim job\n[Service]\nUser=botsim\nEnvironment=PYTHONUNBUFFERED=1\nEnvironmentFile=/etc/botsim/job.env\nWorkingDirectory=/opt/botsim/repo\nExecStart=/usr/bin/python3 /opt/botsim/repo/tools/botsim/cloud/jobrun.py ${BOTSIM_JOB}\nExecStopPost=+/usr/bin/python3 /usr/local/lib/botsim/boxctl.py backup\nKillMode=mixed\nTimeoutStopSec=200\nRestart=no\n",
}


def gzb64(text):
    return base64.b64encode(gzip.compress(text.encode())).decode()


RESULTS_REPO = os.environ.get("BOTSIM_RESULTS_REPO", "JupiterianSoul/botlatro-results")
RESULTS_KEY = os.path.join(CONF, "results_deploy_key")
RESULTS_KNOWN = os.path.join(CONF, "github_known_hosts")


def results_backup():
    if not (os.path.exists(RESULTS_KEY) and os.path.exists(RESULTS_KNOWN)):
        return None
    return {"remote": "git@github.com:%s.git" % RESULTS_REPO, "key": open(RESULTS_KEY).read(), "known": open(RESULTS_KNOWN).read()}


def cloud_init(box, node, token, host_key=None, backup=None):
    files = [
        ("/etc/botsim/token", "0600", token + "\n", False),
        ("/etc/botsim/box.json", "0600", json.dumps(box, indent=1) + "\n", False),
        ("/etc/botsim/node.json", "0644", json.dumps(node, indent=1) + "\n", False),
        ("/usr/local/lib/botsim/common.py", "0644", open(os.path.join(CLOUD, "common.py")).read(), True),
        ("/usr/local/lib/botsim/boxctl.py", "0755", open(os.path.join(CLOUD, "boxctl.py")).read(), True),
    ]
    if backup:
        files += [("/etc/botsim/results_key", "0600", backup["key"], False),
                  ("/etc/botsim/github_known_hosts", "0644", backup["known"], False)]
    for name, text in UNITS.items():
        files.append(("/etc/systemd/system/" + name, "0644", text, False))
    out = ["#cloud-config", "bootcmd:",
           "  - [sh, -c, 'iptables -I OUTPUT -d 169.254.169.254 -m owner ! --uid-owner 0 -j REJECT || true']",
           ]
    if host_key:
        out += host_keys_cloud_config(*host_key)
    out.append("write_files:")
    for path, mode, content, gz in files:
        out.append("  - path: %s" % path)
        out.append("    permissions: '%s'" % mode)
        out.append("    owner: root:root")
        if gz:
            out.append("    encoding: gz+b64")
            out.append("    content: %s" % gzb64(content))
        else:
            out.append("    encoding: b64")
            out.append("    content: %s" % base64.b64encode(content.encode()).decode())
    out += ["runcmd:",
            "  - [sh, -c, 'systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true; apt-get remove -y -q needrestart || true']",
            "  - [sh, -c, 'systemctl daemon-reload && systemctl enable --now botsim-watchdog.timer botsim-stop.path botsim-backup.timer']",
            "  - [sh, -c, 'id botsim || useradd --system --create-home --home-dir /home/botsim --shell /usr/sbin/nologin botsim']",
            "  - [sh, -c, 'mkdir -p /opt/botsim/run /opt/botsim/repo /opt/botsim/jobs /opt/botsim/xfer /opt/botsim/work && chown botsim:botsim /opt/botsim/run /opt/botsim/xfer /opt/botsim/work && touch /etc/botsim/job.env']",
            "  - [sh, -c, 'DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 rsync git gcc make libc6-dev']",
            "  - [sh, -c, 'systemctl enable botsim-dashboard.service']",
            ""]
    return "\n".join(out)


def current():
    c = load_json(CURRENT)
    if not c:
        raise SystemExit("no current run (%s). Start one with: hz.py up" % CURRENT)
    return c


def save_state(c):
    os.makedirs(CONF, exist_ok=True)
    save_json(CURRENT, c, 0o600)


RETRY = {"cmd": None}


def this_cmd():
    return "python3 tools/botsim/cloud/hz.py " + " ".join(shlex.quote(x) for x in sys.argv[1:])


def retry_cmd(default):
    return RETRY["cmd"] or default


def hm(t):
    return time.strftime("%H:%M", time.localtime(t))


def kept_notice(c):
    if not c or not c.get("boxes"):
        return
    now = time.time()
    for b in c["boxes"]:
        paid = next_hour_boundary(float(b["created"]), now)
        say("kept %s (%s, %s): paid until %s, deletes itself at %s" % (b["name"], b.get("type"), b.get("ip"), hm(paid),
                                                                       hm(float(b.get("deadline") or paid))))
    say("they cost nothing more until then. To give up instead: python3 tools/botsim/cloud/hz.py down")


def cmd_plan(args):
    p = make_plan(api(), args)
    probs = plan_problems(p)
    if getattr(args, "json", False):
        say(json.dumps({"cost_eur": round(p["cost"], 6), "types": [b["type"] for b in p["boxes"]], "hours": p["hours"],
                        "billed_hours": p["billed_hours"], "boxes": p["boxes"], "spent_eur": round(p["spent"], 6), "cap_eur": p["cap"],
                        "left_after_eur": round(p["cap"] - p["spent"] - p["cost"], 6), "run_cap_eur": p["run_cap"],
                        "over_limits": p["over_limits"], "problems": probs}, sort_keys=True))
        return 1 if probs else 0
    print_plan(p)
    for pr in probs:
        say("REFUSED: " + pr)
    return 1 if probs else 0


def box_index(name):
    try:
        return int(name.rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return None


def server_ip(s):
    return ((s.get("public_net") or {}).get("ipv4") or {}).get("ip")


def adopt_or_refuse(a, args, live, c):
    names = ", ".join(s["name"] for s in live)
    if args.replace:
        now = time.time()
        wasted = sum(max(0, next_hour_boundary(parse_time(s["created"]), now) - now) for s in live) / 60
        say("--replace: deleting %d existing botsim servers (%s), throwing away %d paid box-minutes" % (len(live), names, wasted))
        if cmd_down(argparse.Namespace(dry_run=False)):
            raise SystemExit("could not delete the old servers, nothing was created")
        return None
    runs = sorted({(s.get("labels") or {}).get("botsim-run", "?") for s in live})
    if len(runs) > 1:
        raise SystemExit("refusing: botsim servers from %d runs exist (%s). Delete them with hz.py down, or wait for their deadlines." % (len(runs), names))
    run = runs[0]
    now = time.time()
    deadline = min(float((s.get("labels") or {}).get("botsim-deadline") or 0) for s in live)
    paid = min(next_hour_boundary(parse_time(s["created"]), now) for s in live)
    want = parse_types(args.types)
    idx = {}
    for s in live:
        i = box_index(s["name"])
        if i is None or i in idx:
            raise SystemExit("refusing: botsim server %s does not follow the botsim-<run>-<n> naming. Check the Hetzner console, then hz.py down." % s["name"])
        idx[i] = s
    match = all(i < len(want) and want[i] == s["server_type"]["name"] for i, s in idx.items())
    have = ",".join("%d:%s" % (i, idx[i]["server_type"]["name"]) for i in sorted(idx))
    desc = "%d botsim server(s) of run %s exist (%s), paid until %s, they delete themselves at %s (%d min from now)" % (
        len(live), run, have, hm(paid), hm(deadline), (deadline - now) // 60)
    if deadline - now < args.min_left * 60:
        raise SystemExit(desc + ".\nToo little time left to reuse them (--min-left %d). Either wait until %s (they delete themselves, "
                         "nothing more is billed) and run up again, or add --replace to delete them now and start fresh." % (args.min_left, hm(deadline)))
    if not match and not args.adopt:
        raise SystemExit(desc + ".\nThey do not match --types %s. Choose one:\n  --adopt    use them as they are, create nothing new\n"
                         "  --replace  delete them and create what you asked for (a new paid hour per box)" % args.types)
    state = c if c and c.get("run") == run else None
    missing = [] if args.adopt else [(i, want[i]) for i in range(len(want)) if i not in idx]
    if not state:
        if missing:
            raise SystemExit(desc + ".\nThe local state of run %s is gone, so new boxes cannot join it. Use --adopt to keep only these boxes, "
                             "or --replace." % run)
        state = {"run": run, "secret": None, "port": None, "deadline": deadline, "hours": None, "cap": CAP_EUR, "run_cap": None,
                 "planned": [], "boxes": [], "started": min(parse_time(s["created"]) for s in live)}
    known = {}
    for b in state.get("planned", []) + state.get("boxes", []):
        known[b["name"]] = dict(known.get(b["name"], {}), **b)
    led = ledger()
    boxes = []
    for i in sorted(idx):
        s = idx[i]
        k = known.get(s["name"], {})
        lab = s.get("labels") or {}
        ent = {"id": s["id"], "name": s["name"], "run": run, "index": i, "type": s["server_type"]["name"], "location": server_loc(s),
               "price_hourly_gross": next((e["price_hourly_gross"] for e in led["servers"] if e["id"] == s["id"]), price_of_server(s)),
               "created": parse_time(s["created"]), "deadline": float(lab.get("botsim-deadline") or deadline), "deleted": None,
               "ip": server_ip(s), "role": lab.get("botsim-role", "head" if i == 0 else "node"), "cores": s["server_type"].get("cores"),
               "host_pub": k.get("host_pub")}
        same = k.get("id") == s["id"] and k.get("ip") == ent["ip"]
        for f in ("deployed", "job_started", "bench_done", "trust_new"):
            if same and k.get(f):
                ent[f] = k[f]
        if not ent["host_pub"]:
            say("note: no pinned host key for %s (local state lost), ssh will trust its key on first use, per run" % s["name"])
        boxes.append(ent)
    state["boxes"] = boxes
    say(desc + ".")
    say("adopting them into run %s%s (--hours is ignored, the deadline stays %s)" % (
        run, (", creating the %d missing box(es)" % len(missing)) if missing else "", hm(state["deadline"])))
    return state, missing


def finish_up(state):
    state["boxes"].sort(key=lambda b: b.get("index", 0))
    state["phase"] = "created"
    head = next((b for b in state["boxes"] if b.get("role") == "head"), None)
    if head and state.get("secret"):
        state["dashboard_url"] = "http://%s:%d/%s/" % (head["ip"], state["port"], state["secret"])
    save_state(state)
    write_known_hosts(CONF, state["run"], state["boxes"])
    if state.get("dashboard_url"):
        fd = os.open(os.path.join(CONF, "dashboard_url"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(state["dashboard_url"] + "\n")
        say("")
        say("dashboard (live after deploy): " + state["dashboard_url"])
        say("saved to %s. Next: hz.py deploy, then hz.py run <job>" % os.path.join(CONF, "dashboard_url"))
    else:
        say("dashboard link unknown until deploy reads it from the head. Next: hz.py deploy")


def cmd_up(args):
    if not args.dry_run:
        require_shared()
    a = api()
    live = a.servers()
    c = load_json(CURRENT)
    if not args.skip_doctor:
        probs = doctor(a, args, live=live, c=c, verbose=False)
        if probs:
            for pr in probs:
                say("REFUSED: " + pr)
            say("nothing was created. hz.py doctor shows every check.")
            return 1
    sync_ledger(a, servers=live)
    adopt = adopt_or_refuse(a, args, live, c) if live else None
    if not adopt and c and c.get("boxes") and os.path.exists(CURRENT):
        os.makedirs(CONF, exist_ok=True)
        os.replace(CURRENT, os.path.join(CONF, "last_run.json"))
    if adopt:
        state, missing = adopt
        if not missing:
            if args.dry_run:
                say("DRY RUN: would adopt %d boxes of run %s" % (len(state["boxes"]), state["run"]))
                return 0
            finish_up(state)
            return 0
        indices = [i for i, _ in missing]
        p = make_plan(a, argparse.Namespace(**dict(vars(args), types=",".join(t for _, t in missing))))
        for b in state["boxes"]:
            ct = "dedicated" if b["type"].startswith("ccx") else "shared"
            p["used"][ct] = p["used"].get(ct, 0) + int(b.get("cores") or 0)
        p["over_limits"] = [k for k, v in p["used"].items() if v > p["limits"].get(k, 0)]
    else:
        p = make_plan(a, args)
        indices = list(range(len(p["boxes"])))
        state = None
    print_plan(p)
    probs = plan_problems(p)
    if probs:
        for pr in probs:
            say("REFUSED: " + pr)
        return 1
    t_start = time.time()
    if state is None:
        duration = deadline_offset(p["hours"])
        port = int(os.environ.get("BOTSIM_DASH_PORT") or random.SystemRandom().randint(20000, 59999))
        state = {"run": "r" + time.strftime("%Y%m%d-%H%M%S"), "secret": secrets.token_urlsafe(24), "port": port,
                 "deadline": t_start + duration, "hours": p["hours"], "run_cap": p["run_cap"], "cap": p["cap"], "started": t_start,
                 "planned": [], "boxes": []}
    run, secret, port, deadline = state["run"], state["secret"], state["port"], state["deadline"]
    save_lead = min(480, max(60, int((deadline - t_start) * 0.15)))
    token = read_token()
    backup = results_backup()
    reqs = []
    for i, b in zip(indices, p["boxes"]):
        name = "botsim-%s-%d" % (run, i)
        role = "head" if i == 0 else "node"
        box = {"name": name, "run": run, "role": role, "deadline": deadline, "save_lead": save_lead,
               "price_hourly_gross": b["price_hourly_gross"], "created_hint": t_start, "secret": secret, "port": port,
               "api": a.base}
        node = {"name": name, "run": run, "role": role, "secret": secret, "port": port, "deadline": deadline}
        topic = alerts.read_topic()
        if topic and role == "head":
            node["ntfy_topic"] = topic
            node["ntfy_url"] = os.environ.get("BOTSIM_NTFY_URL") or alerts.NTFY_DEFAULT
        if backup and role == "head":
            box["results_remote"] = backup["remote"]
        body = {"name": name, "server_type": b["type"], "location": b["location"], "image": IMAGE, "ssh_keys": [SSH_KEY_NAME],
                "start_after_create": True, "public_net": {"enable_ipv4": True, "enable_ipv6": True},
                "labels": {"botsim": "1", "botsim-run": run, "botsim-role": role, "botsim-deadline": str(int(deadline))}}
        reqs.append((i, b, body, box, node))
    say("")
    say("run %s, deadline %s (boxes delete themselves then), dashboard port %d" % (run, time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(deadline)), port))
    if args.dry_run:
        os.makedirs(CONF, exist_ok=True)
        path = os.path.join(CONF, "dryrun-cloud-init.yaml")
        i, b, body, box, node = reqs[0]
        priv, pub = gen_host_key()
        priv = "-----BEGIN OPENSSH PRIVATE KEY-----\n<host key redacted>\n-----END OPENSSH PRIVATE KEY-----\n"
        text = cloud_init(box, node, token, (priv, pub), backup and dict(backup, key="<results key redacted>"))
        text = text.replace(base64.b64encode((token + "\n").encode()).decode(), "<token redacted>")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        for i, b, body, box, node in reqs:
            say("DRY RUN: POST /servers " + json.dumps(body))
        say("DRY RUN: cloud-init of box %d (token and host key body redacted) written to %s" % (reqs[0][0], path))
        return 0
    if not args.yes:
        GUARD.immediate = True
        try:
            ans = input("Create %d servers for at most %.2f EUR? Type yes: " % (len(reqs), p["cost"])).strip().lower()
        except (KeyboardInterrupt, EOFError):
            ans = ""
        GUARD.immediate = False
        if ans != "yes":
            say("cancelled, nothing was created")
            return 1
    led = ledger()
    state["phase"] = "creating"
    save_state(state)
    failed = None
    for i, b, body, box, node in reqs:
        GUARD.check("up:before_create:%d" % i)
        priv, pub = gen_host_key()
        state["planned"] = [x for x in state.get("planned", []) if x["name"] != body["name"]] + [
            {"name": body["name"], "index": i, "type": b["type"], "host_pub": pub}]
        save_state(state)
        body["user_data"] = cloud_init(box, node, token, (priv, pub), backup if box["role"] == "head" else None)
        srv = None
        try:
            for loc in [b["location"]] + b["fallback"]:
                body["location"] = loc
                try:
                    srv = a.call("POST", "/servers", body)["server"]
                    break
                except ApiError as e:
                    if e.code in FATAL_CODES:
                        raise
                    say("create %s in %s failed (%s), trying the next location" % (body["name"], loc, e))
        except ApiError as e:
            failed = "create %s failed: %s" % (body["name"], e)
            break
        if srv is None:
            failed = "could not create %s in any of %s" % (body["name"], ",".join([b["location"]] + b["fallback"]))
            break
        ent = {"id": srv["id"], "name": srv["name"], "run": run, "type": b["type"], "location": body["location"],
               "price_hourly_gross": b["price_hourly_gross"], "created": parse_time(srv["created"]), "deadline": deadline,
               "deleted": None}
        led["servers"].append(ent)
        write_ledger(led)
        ip = server_ip(srv)
        state["boxes"].append(dict(ent, ip=ip, index=i, role=body["labels"]["botsim-role"], cores=b["cores"], host_pub=pub))
        save_state(state)
        write_known_hosts(CONF, run, state["boxes"])
        say("created %s (%s, %s) %s" % (srv["name"], b["type"], body["location"], ip))
        forget_host(ip)
        GUARD.check("up:after_create:%d" % i)
    if failed:
        say("")
        say("up stopped: " + failed)
        if state["boxes"]:
            state["boxes"].sort(key=lambda x: x.get("index", 0))
            save_state(state)
            write_known_hosts(CONF, run, state["boxes"])
            kept_notice(state)
            say("retry (adopts the boxes above and creates the rest): " + retry_cmd(this_cmd()))
        else:
            say("no server was created, nothing is billed")
        return 1
    finish_up(state)
    return 0


def forget_host(ip):
    kh = os.path.join(CONF, "known_hosts")
    if ip and os.path.exists(kh):
        subprocess.run(["ssh-keygen", "-R", ip, "-f", kh], capture_output=True)


def ssh_base(box):
    return ["ssh"] + ssh_opts(CONF, box["run"], box, SSH_KEY)


def ssh_argv(box, command):
    return ssh_base(box) + ["%s@%s" % (ssh_user(), box["ip"]), command]


def ssh(box, command, dry, input_text=None, check=True, timeout=1800):
    argv = ssh_argv(box, command)
    if dry:
        say("DRY RUN: " + " ".join(shlex.quote(x) for x in argv) + ("  <<< %d bytes" % len(input_text) if input_text else ""))
        return ""
    rc, out, err = run_cmd(argv, input_text=input_text, timeout=timeout)
    GUARD.check("ssh")
    if check and rc != 0:
        raise StepFailed("ssh %s (%s) failed (%d) running %r: %s" % (box["name"], box["ip"], rc, command[:60], (err or out).strip()[-400:]))
    return out


def rsync(box, src, dst, dry, extra=(), delete=True, may_be_missing=False):
    argv = ["rsync", "-az"] + (["--delete"] if delete else []) + ["-e", " ".join(shlex.quote(x) for x in ssh_base(box))] + list(extra) + [src, dst]
    if dry:
        say("DRY RUN: " + " ".join(shlex.quote(x) for x in argv))
        return
    rc, out, err = run_cmd(argv, cwd=REPO, timeout=1800)
    GUARD.check("rsync")
    if rc == 23 and may_be_missing and "No such file or directory" in err:
        return
    if rc != 0:
        raise StepFailed("rsync %s (%s) failed (%d): %s" % (box["name"], box["ip"], rc, err.strip()[-400:]))


def wait_ready(box, dry):
    if dry:
        ssh(box, "cloud-init status --wait", True)
        return
    wait_ssh(lambda cmd: ssh_argv(box, cmd), say)
    out = ssh(box, "timeout 900 cloud-init status --wait >/dev/null 2>&1; cloud-init status", False, check=False, timeout=960)
    if "status: done" not in out:
        tail = ssh(box, "tail -n 25 /var/log/cloud-init-output.log", False, check=False, timeout=60)
        raise StepFailed("cloud-init on %s did not finish cleanly (%s). Last lines of its log:\n%s" % (
            box["name"], out.strip() or "no status", tail.rstrip()))


def run_json(c, led):
    before = sum(box_cost(e["created"], e.get("deleted") or time.time(), e["price_hourly_gross"])
                 for e in led.get("servers", []) if e.get("run") != c["run"])
    before += sum(float(x.get("eur", 0)) for x in led.get("adjustments", []))
    boxes = [{k: b.get(k) for k in ("name", "id", "ip", "type", "cores", "role", "location", "price_hourly_gross", "created", "deadline")}
             for b in c["boxes"]]
    return {"run": c["run"], "port": c["port"], "cap": c.get("cap") or CAP_EUR, "run_cap": c.get("run_cap"), "spent_before": round(before, 6), "boxes": boxes}


def recover_secret(c):
    head = next((b for b in c["boxes"] if b.get("role") == "head"), c["boxes"][0])
    box = json.loads(ssh(head, "cat /etc/botsim/box.json", False))
    c["secret"], c["port"] = box["secret"], box["port"]
    c["dashboard_url"] = "http://%s:%d/%s/" % (head["ip"], c["port"], c["secret"])
    save_state(c)
    say("read the dashboard secret back from %s" % head["name"])


def report_failures(c, what, failed, retry):
    say("")
    say("%s failed on %d of %d boxes:" % (what, len(failed), len(c["boxes"])))
    for b, why in failed:
        say("  %s (%s): %s" % (b["name"], b.get("ip"), why))
    kept_notice(c)
    say("retry (boxes already done are skipped): " + retry_cmd(retry))
    if any("hostkey" in why for _, why in failed):
        say("if the host key keeps failing, retry with --trust-new-host-keys (trusts the key the box shows now, for this run only)")


def job_needs(job):
    p = os.path.join(CLOUD, "jobs", job, "needs.json")
    if not job or not os.path.isfile(p):
        return None
    return json.load(open(p))


def needs_script(n):
    pk = " ".join(shlex.quote(x) for x in n.get("pip", []))
    apt = " ".join(shlex.quote(x) for x in n.get("apt", []))
    venv = n.get("venv", "/opt/botsim/venv")
    probe = n.get("probe", "import torch, numpy")
    return ("set -e; if %s/bin/python -c %s >/dev/null 2>&1; then echo present; else "
            "DEBIAN_FRONTEND=noninteractive apt-get install -y -q %s >/var/log/botsim-needs.log 2>&1 || { tail -n 15 /var/log/botsim-needs.log; exit 1; }; "
            "rm -rf %s; python3 -m venv %s; "
            "%s/bin/pip install --no-cache-dir -q %s --index-url %s >>/var/log/botsim-needs.log 2>&1 || { tail -n 15 /var/log/botsim-needs.log; exit 1; }; fi; "
            "%s/bin/python -c %s; chmod -R a+rX %s; echo ready") % (
        venv, shlex.quote(probe), apt, venv, venv, venv, pk, shlex.quote(n.get("index", "https://pypi.org/simple")), venv,
        shlex.quote(probe + "; print(torch.__version__)"), venv)


def box_job_needs(b, job, dry):
    n = job_needs(job)
    if not n:
        return
    t0 = time.time()
    out = ssh(b, needs_script(n), dry, timeout=1500)
    if not dry:
        if "ready" not in out:
            raise StepFailed("job %s needs failed on %s: %s" % (job, b["name"], out.strip()[-400:]))
        say("  %s needs installed on %s in %.0f s (%s)" % (job, b["name"], time.time() - t0, out.strip().splitlines()[-2] if len(out.strip().splitlines()) > 1 else "ok"))


def cmd_deploy(args):
    c = current()
    for_job = getattr(args, "for_job", None)
    if args.trust_new_host_keys:
        for b in c["boxes"]:
            if not b.get("deployed"):
                b["trust_new"] = True
        save_state(c)
        say("trusting whatever host key the boxes not deployed yet show now (first use, this run only)")
    write_known_hosts(CONF, c["run"], c["boxes"])
    failed = []
    for b in c["boxes"]:
        i = b.get("index", c["boxes"].index(b))
        if b.get("deployed") and not args.force:
            if for_job and for_job not in b.get("needs", []) and job_needs(for_job):
                say("deploy %s: installing what %s needs" % (b["name"], for_job))
                try:
                    box_job_needs(b, for_job, args.dry_run)
                except StepFailed as e:
                    say("  FAILED: %s" % e)
                    failed.append((b, str(e)))
                    continue
                if not args.dry_run:
                    b.setdefault("needs", []).append(for_job)
                    save_state(c)
            else:
                say("deploy %s: already done, skipped" % b["name"])
            continue
        say("deploy %s (%s)" % (b["name"], b["ip"]))
        if b.get("deployed") and not args.dry_run:
            b["deployed"] = False
            save_state(c)
        try:
            wait_ready(b, args.dry_run)
            GUARD.check("deploy:%d:ready" % i)
            if not c.get("secret") and not args.dry_run:
                recover_secret(c)
            rj = json.dumps(run_json(c, ledger()), indent=1)
            ssh(b, "cat > /etc/botsim/run.json && chmod 0644 /etc/botsim/run.json", args.dry_run, input_text=rj)
            rsync(b, "./assets/bot", "%s@%s:/opt/botsim/repo/" % (ssh_user(), b["ip"]), args.dry_run, ["-R", "--exclude", "*.tmp"])
            rsync(b, "./assets/functions", "%s@%s:/opt/botsim/repo/" % (ssh_user(), b["ip"]), args.dry_run, ["-R"])
            rsync(b, "./tools/botsim", "%s@%s:/opt/botsim/repo/" % (ssh_user(), b["ip"]), args.dry_run,
                  ["-R", "--exclude", "tools/botsim/results/", "--exclude", "tools/botsim/c/libbotsim.so", "--exclude", "__pycache__/", "--exclude", ".venv/", "--exclude", "tools/botsim/train/out/"])
            box_luajit_and_golden(b, args.dry_run)
            if for_job:
                box_job_needs(b, for_job, args.dry_run)
            if args.job:
                jd = os.path.abspath(args.job).rstrip("/")
                rsync(b, jd + "/", "%s@%s:/opt/botsim/jobs/%s/" % (ssh_user(), b["ip"], os.path.basename(jd)), args.dry_run)
            GUARD.check("deploy:%d:synced" % i)
            ssh(b, "chown -R root:root /opt/botsim/repo /opt/botsim/jobs && chmod -R a+rX /opt/botsim/repo /opt/botsim/jobs && "
                   "install -m 0755 /opt/botsim/repo/tools/botsim/cloud/boxctl.py /usr/local/lib/botsim/boxctl.py && "
                   "install -m 0644 /opt/botsim/repo/tools/botsim/cloud/common.py /usr/local/lib/botsim/common.py && "
                   "install -d -o botsim -g botsim /opt/botsim/xfer /opt/botsim/work && "
                   "systemctl daemon-reload && systemctl enable botsim-dashboard && systemctl restart botsim-dashboard && "
                   "systemctl is-active botsim-watchdog.timer botsim-stop.path botsim-dashboard", args.dry_run)
        except StepFailed as e:
            say("  FAILED: %s" % e)
            failed.append((b, str(e)))
            continue
        if not args.dry_run:
            b["deployed"] = True
            if for_job and job_needs(for_job):
                b["needs"] = sorted(set(b.get("needs", [])) | {for_job})
            save_state(c)
        GUARD.check("deploy:%d:done" % i)
    if failed:
        report_failures(c, "deploy", failed, "python3 tools/botsim/cloud/hz.py deploy" + (" --job " + shlex.quote(args.job) if args.job else ""))
        return 2
    say("deployed. dashboard: %s" % c.get("dashboard_url"))
    return 0


JOB_PROBE = ("echo STATE=$(systemctl is-active botsim-job); "
             "T=$(systemctl show -p ActiveEnterTimestamp --value botsim-job); echo START=$( [ -n \"$T\" ] && date -d \"$T\" +%s ); "
             "echo ENV=$(base64 -w0 /etc/botsim/job.env 2>/dev/null)")
JOB_RESTART = ("BEFORE=$(date +%s.%N); cat > /etc/botsim/job.env && rm -f /opt/botsim/run/STOP && touch /opt/botsim/run/RESTARTING && "
               "systemctl restart botsim-job; rm -f /opt/botsim/run/RESTARTING; sleep 1; echo BEFORE=$BEFORE; " + JOB_PROBE)


def parse_probe(out):
    kv = {}
    for ln in (out or "").splitlines():
        k, _, v = ln.partition("=")
        if k in ("STATE", "START", "ENV", "BEFORE"):
            kv[k] = v.strip()
    try:
        env_text = base64.b64decode(kv.get("ENV") or "").decode()
    except ValueError:
        env_text = ""
    env = {}
    for ln in env_text.splitlines():
        k, _, v = ln.partition("=")
        if k:
            env[k] = v
    num = lambda x: float(x) if x and x.replace(".", "", 1).isdigit() else None
    return {"state": kv.get("STATE") or "unknown", "start": num(kv.get("START")), "before": num(kv.get("BEFORE")), "env": env}


def env_line(env):
    return " ".join("%s=%s" % (k, v) for k, v in sorted(env.items())) or "no settings"


def when(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) if t else "unknown"


def cmd_run(args):
    c = current()
    if not os.path.isfile(os.path.join(CLOUD, "jobs", args.job, "run")) and not args.remote_job:
        raise SystemExit("no job %s in %s (use --remote-job for a job deployed with deploy --job)" % (args.job, os.path.join(CLOUD, "jobs")))
    env = ["BOTSIM_JOB=" + args.job]
    if args.workers:
        env.append("BOTSIM_WORKERS=%d" % args.workers)
    for kv in args.env or []:
        if "=" not in kv or "\n" in kv:
            raise SystemExit("bad --env %r, use KEY=VALUE" % kv)
        env.append(kv)
    if getattr(args, "delete_when_done", False) and "BOTSIM_DELETE_WHEN_DONE=1" not in env:
        env.append("BOTSIM_DELETE_WHEN_DONE=1")
    text = "\n".join(env) + "\n"
    sent = dict(x.split("=", 1) for x in env)
    lacking = [b["name"] for b in c["boxes"] if job_needs(args.job) and args.job not in b.get("needs", [])]
    if lacking and not args.dry_run:
        raise SystemExit("refusing to start %s: %s lack what it needs. Run: hz.py deploy --for-job %s" % (args.job, ", ".join(lacking), args.job))
    not_ready = [b["name"] for b in c["boxes"] if not b.get("deployed")]
    if not_ready and not args.dry_run:
        raise SystemExit("refusing to start %s: %s not deployed or failed the golden sim test. Run hz.py deploy first." % (args.job, ", ".join(not_ready)))
    res = {"started": [], "refused": [], "failed": [], "readback": {}}
    lines = {}
    failed = []
    for b in c["boxes"]:
        i = b.get("index", c["boxes"].index(b))
        name = b["name"]
        if args.dry_run:
            ssh(b, JOB_PROBE, True)
            ssh(b, JOB_RESTART, True, input_text=text)
            res["started"].append(name)
            lines[name] = "would start (dry run)"
            continue
        try:
            now = parse_probe(ssh(b, JOB_PROBE, False, timeout=60))
        except StepFailed as e:
            say("run %s on %s: FAILED reading its job state: %s" % (args.job, name, e))
            failed.append((b, str(e)))
            res["failed"].append(name)
            lines[name] = "FAILED: job state unreadable"
            continue
        if now["state"] in ("active", "activating", "reloading") and not args.force:
            say("run %s on %s: NOT STARTED, a job is already running there (since %s, %s). --force restarts it." % (
                args.job, name, when(now["start"]), env_line(now["env"])))
            res["refused"].append(name)
            res["readback"][name] = {"start": now["start"], "env": now["env"]}
            lines[name] = "NOT STARTED (running since %s)" % when(now["start"])
            continue
        say("run %s on %s (job was %s)" % (args.job, name, now["state"]))
        try:
            rb = parse_probe(ssh(b, JOB_RESTART, False, input_text=text, check=False, timeout=300))
        except StepFailed as e:
            rb = {"state": "unknown", "start": None, "before": None, "env": {}, "why": str(e)}
        res["readback"][name] = {"start": rb["start"], "env": rb["env"]}
        say("  readback %s: state %s, started %s (box clock %s), settings %s" % (
            name, rb["state"], when(rb["start"]), rb["start"], env_line(rb["env"])))
        why = rb.get("why")
        if not why and rb["state"] != "active":
            why = "job is %s after the start" % rb["state"]
        if not why and (rb["start"] is None or rb["before"] is None or rb["start"] < math.floor(rb["before"])):
            why = "start time %s is not after the restart (%s)" % (rb["start"], rb["before"])
        if not why and rb["env"] != sent:
            why = "/etc/botsim/job.env on the box does not match what was sent"
        if why:
            say("  FAILED: " + why)
            failed.append((b, why))
            res["failed"].append(name)
            lines[name] = "FAILED: " + why
            continue
        res["started"].append(name)
        lines[name] = "started at %s" % when(rb["start"])
        b["job_started"] = args.job
        save_state(c)
        GUARD.check("run:%d" % i)
    if failed:
        report_failures(c, "run", failed, this_cmd())
    say("summary: " + "; ".join("%s %s" % (n, lines[n]) for n in lines))
    if getattr(args, "json", False):
        say(json.dumps(dict(res, job=args.job, dry_run=bool(args.dry_run)), sort_keys=True))
    if res["failed"]:
        return 2
    if res["refused"]:
        return 3
    if not args.dry_run:
        say("started. dashboard: %s" % c.get("dashboard_url"))
    return 0


def head_state(c, timeout=8):
    try:
        with urllib.request.urlopen(c["dashboard_url"] + "api/state", timeout=timeout) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}


def status_json(servers, led, now):
    c = load_json(CURRENT)
    names = {s["name"] for s in servers}
    boxes = []
    for s in servers:
        boxes.append({"name": s["name"], "id": s["id"], "type": s["server_type"]["name"], "location": server_loc(s), "status": s["status"],
                      "ip": ((s.get("public_net") or {}).get("ipv4") or {}).get("ip"),
                      "deadline": float(s.get("labels", {}).get("botsim-deadline") or 0) or None, "job": None})
    by_name = {x["name"]: x for x in boxes}
    if c and c.get("boxes"):
        for b in c["boxes"]:
            if b["name"] not in names or not b.get("ip"):
                continue
            try:
                st = parse_probe(ssh(dict(b, run=c["run"]), JOB_PROBE, False, timeout=30))
                by_name[b["name"]]["job"] = {"state": st["state"], "start": st["start"], "env": st["env"]}
            except StepFailed as e:
                by_name[b["name"]]["job"] = {"state": "unreachable", "error": str(e)[-200:]}
    out = {"run": (c or {}).get("run"), "deadline": (c or {}).get("deadline"), "boxes": boxes,
           "spent_eur": round(ledger_spent(led, now), 6), "cap_eur": float(led.get("cap_eur", CAP_EUR)),
           "shared_ledger": "off" if shared_off() else ("ok" if SHARED["ok"] else "unreadable: %s" % SHARED["error"])}
    if c and servers and c.get("dashboard_url"):
        out["head"] = head_state(c)
    return out


def cmd_status(args):
    a = api()
    servers = a.servers()
    led = sync_ledger(a, servers=servers)
    now = time.time()
    if getattr(args, "json", False):
        say(json.dumps(status_json(servers, led, now), sort_keys=True))
        return 0
    say("%d botsim servers" % len(servers))
    for s in servers:
        say("  %-28s %-7s %-5s %-8s %s" % (s["name"], s["server_type"]["name"], server_loc(s), s["status"],
                                           ((s.get("public_net") or {}).get("ipv4") or {}).get("ip")))
    spent = ledger_spent(led, now)
    say("spent %.4f of %.2f EUR (%.4f left)" % (spent, float(led.get("cap_eur", CAP_EUR)), float(led.get("cap_eur", CAP_EUR)) - spent))
    c = load_json(CURRENT)
    if c and servers:
        st = head_state(c)
        if "error" in st:
            say("dashboard not reachable: %s" % st["error"])
        else:
            left = st.get("time_left")
            say("run %s: %s games, %.1f games/s, generation %s, job time left %s, state %s" % (
                st.get("run"), st.get("games"), st.get("gps") or 0, st.get("gen"),
                ("%d min" % round(left / 60)) if left is not None else "unknown", (st.get("control") or {}).get("state", "running")))
            if st.get("deadline"):
                say("boxes delete themselves at %s" % time.strftime("%H:%M:%S", time.localtime(st["deadline"])))
        say("dashboard: " + c["dashboard_url"])
    return 0


def cmd_pull(args):
    c = load_json(CURRENT) or load_json(os.path.join(CONF, "last_run.json"))
    if not c:
        raise SystemExit("no run to pull from")
    out = os.path.join(RESULTS, c["run"])
    os.makedirs(out, exist_ok=True)
    a = api()
    live = {s["name"] for s in a.servers()} if not args.dry_run else {b["name"] for b in c["boxes"]}
    head = next((b for b in c["boxes"] if b.get("role") == "head"), c["boxes"][0])
    if head["name"] in live:
        rsync(dict(head, run=c["run"]), "%s@%s:/opt/botsim/run/boxes/" % (ssh_user(), head["ip"]), out + "/", args.dry_run, delete=False, may_be_missing=True)
    for b in c["boxes"]:
        if b["name"] not in live:
            say("%s is gone, using what the head collected" % b["name"])
            continue
        rsync(dict(b, run=c["run"]), "%s@%s:/opt/botsim/run/" % (ssh_user(), b["ip"]), os.path.join(out, b["name"]) + "/", args.dry_run,
              ["--exclude", "boxes/", "--exclude", "job.pid", "--exclude", "STOP*"])
    if not args.dry_run:
        meta = run_json(c, ledger())
        save_json(os.path.join(out, "run.json"), meta)
    say("pulled to %s" % out)
    say("view: python3 tools/botsim/cloud/dashboard.py --local %s" % out)
    if args.down:
        return cmd_down(args)
    return 0


def cmd_down(args):
    a = api()
    servers = a.servers()
    if not servers:
        say("no botsim servers exist")
    now = time.time()
    left_min = sum(max(0, next_hour_boundary(parse_time(s["created"]), now) - now) for s in servers) / 60
    if servers and left_min >= 10:
        say("note: these boxes still have %d paid box-minutes; if a step failed, a retry inside that time costs nothing" % left_min)
    for s in servers:
        GUARD.check("down")
        if args.dry_run:
            say("DRY RUN: DELETE /servers/%d (%s)" % (s["id"], s["name"]))
            continue
        ok = a.delete_server(s["id"])
        say("deleted %s" % s["name"] if ok else "%s was already gone" % s["name"])
    if args.dry_run:
        return 0
    t_end = time.time() + 180
    left = servers
    while left and time.time() < t_end:
        nap(float(os.environ.get("BOTSIM_DOWN_POLL", 3)), "down")
        left = a.servers()
    led = ledger()
    now = time.time()
    gone = {s["id"] for s in servers}
    for e in led.get("servers", []):
        if not e.get("deleted") and e["id"] in gone:
            e["deleted"] = now
    write_ledger(led)
    sync_ledger(a, led, left)
    if left:
        say("WARNING: still listed after 180 s: %s. Run hz.py down again and check the Hetzner console." % ", ".join(s["name"] for s in left))
        return 1
    if os.path.exists(CURRENT):
        os.replace(CURRENT, os.path.join(CONF, "last_run.json"))
    say("verified: no botsim servers left. spent %.4f EUR of %.2f" % (ledger_spent(led), float(led.get("cap_eur", CAP_EUR))))
    return 0


def cmd_list(args):
    a = api()
    servers = a.servers()
    led = sync_ledger(a, servers=servers)
    now = time.time()
    if getattr(args, "json", False):
        say(json.dumps({"servers": [{"name": s["name"], "id": s["id"], "type": s["server_type"]["name"], "location": server_loc(s),
                                     "status": s["status"], "created": parse_time(s["created"]),
                                     "deadline": float(s.get("labels", {}).get("botsim-deadline") or 0) or None} for s in servers],
                        "spent_eur": round(ledger_spent(led, now), 6)}, sort_keys=True))
        return 0
    if not servers:
        say("no botsim servers")
    for s in servers:
        created = parse_time(s["created"])
        dl = float(s.get("labels", {}).get("botsim-deadline") or 0)
        price = next((e["price_hourly_gross"] for e in led["servers"] if e["id"] == s["id"]), price_of_server(s))
        say("%-28s id %-10s %-7s %-5s %-9s age %4d min  deadline in %4s min  %.4f EUR so far" % (
            s["name"], s["id"], s["server_type"]["name"], server_loc(s), s["status"], (now - created) // 60,
            int((dl - now) // 60) if dl else "?", box_cost(created, now, price)))
    say("ledger: spent %.4f of %.2f EUR" % (ledger_spent(led, now), float(led.get("cap_eur", CAP_EUR))))
    return 0


def gh(*args, inp=None):
    r = subprocess.run(["gh"] + list(args), input=inp, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise StepFailed("gh %s failed: %s" % (" ".join(args[:2]), (r.stderr or r.stdout).strip()[-300:]))
    return r.stdout


def cmd_results_setup(args):
    if subprocess.run(["gh", "repo", "view", RESULTS_REPO], capture_output=True).returncode == 0:
        say("ok    private repo %s exists" % RESULTS_REPO)
    else:
        gh("repo", "create", RESULTS_REPO, "--private", "--add-readme", "--description", "Bot-latro training results, pushed by the head box of each run")
        say("made  private repo %s" % RESULTS_REPO)
    if json.loads(gh("repo", "view", RESULTS_REPO, "--json", "isPrivate"))["isPrivate"] is not True:
        raise StepFailed("%s is not private, refusing to push results there" % RESULTS_REPO)
    os.makedirs(CONF, exist_ok=True)
    if not os.path.exists(RESULTS_KEY):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "botsim-results", "-f", RESULTS_KEY], check=True)
        say("made  deploy key %s" % RESULTS_KEY)
    pub = open(RESULTS_KEY + ".pub").read().split()
    keys = json.loads(gh("api", "repos/%s/keys" % RESULTS_REPO))
    if any(k["key"].split()[:2] == pub[:2] and not k["read_only"] for k in keys):
        say("ok    deploy key is on the repo with write access")
    else:
        gh("api", "-X", "POST", "repos/%s/keys" % RESULTS_REPO, "-f", "title=botsim boxes", "-f", "key=%s %s" % (pub[0], pub[1]), "-F", "read_only=false")
        say("added deploy key to %s (write access to this repo only)" % RESULTS_REPO)
    meta = json.loads(gh("api", "meta"))
    lines = ["github.com " + k for k in meta.get("ssh_keys", [])]
    if not lines:
        raise StepFailed("GitHub did not return its ssh host keys")
    with open(RESULTS_KNOWN, "w") as f:
        f.write("\n".join(lines) + "\n")
    say("ok    GitHub host keys pinned in %s" % RESULTS_KNOWN)
    say("the head box of every new run pushes runs/<run>/ to %s every 10 min and when the run stops" % RESULTS_REPO)
    return 0


def cmd_alerts_test(args):
    topic, created = alerts.ensure_topic()
    base = os.environ.get("BOTSIM_NTFY_URL") or alerts.NTFY_DEFAULT
    if created:
        say("new secret topic saved to %s (0600, never commit it)" % alerts.topic_file())
    say("ntfy server: %s" % base)
    say("topic:       %s" % topic)
    say("subscribe:   ntfy app > + > topic name above (server %s), or open %s/%s in a browser" % (base, base.rstrip("/"), topic))
    if args.dry_run:
        say("DRY RUN: no message sent")
        return 0
    try:
        alerts.send(base, topic, "Bot-latro alerts work", "Test from hz.py alerts-test. During a run the head box sends: run started, "
                    "new best generation, run finished, Stop pressed, boxes deleting themselves soon, spend at 80% and 95% of the cap.",
                    priority=3, tags="white_check_mark")
    except Exception as e:
        say("send failed: %s" % e)
        return 1
    say("test message sent. Boxes created by the next hz.py up get this topic.")
    return 0


def cmd_spend(args):
    led = ledger()
    write_ledger(led)
    if getattr(args, "json", False):
        spent = ledger_spent(led)
        cap = float(led.get("cap_eur", CAP_EUR))
        say(json.dumps({"spent_eur": round(spent, 6), "cap_eur": cap, "left_eur": round(cap - spent, 6),
                        "shared_ledger": "off" if shared_off() else ("ok" if SHARED["ok"] else "unreadable: %s" % SHARED["error"])}, sort_keys=True))
        return 0
    print(open(SPEND_MD).read())
    return 0


def cmd_watch(args):
    a = api()
    last_pull = time.time()
    say("local watchdog: Ctrl-C leaves the boxes running (their own watchdogs still delete them at the deadline)")
    while True:
        try:
            servers = a.servers()
        except Exception as e:
            say("api error: %s" % e)
            nap(args.every, "watch")
            continue
        led = sync_ledger(a, servers=servers)
        now = time.time()
        if not servers:
            say("no botsim servers left")
            return 0
        spent = ledger_spent(led, now)
        cap = float(led.get("cap_eur", CAP_EUR))
        late = [s for s in servers if float(s.get("labels", {}).get("botsim-deadline") or 0) and now > float(s["labels"]["botsim-deadline"]) + 300]
        for s in late:
            say("%s is past its deadline, deleting" % s["name"])
            if not args.dry_run:
                a.delete_server(s["id"])
        next_hour = sum(e["price_hourly_gross"] for e in led["servers"] if not e.get("deleted"))
        if spent + next_hour > cap:
            say("next started hour would pass the %.2f EUR cap (spent %.4f), pulling and deleting everything" % (cap, spent))
            if not args.dry_run and load_json(CURRENT):
                try:
                    cmd_pull(argparse.Namespace(dry_run=False, down=False))
                except (SystemExit, StepFailed) as e:
                    say("pull failed: %s" % e)
            return cmd_down(args)
        c = load_json(CURRENT)
        if c:
            st = head_state(c)
            cs = (st.get("control") or {}).get("state")
            if cs == "stopped":
                say("run stopped (%s), pulling results and deleting the boxes" % (st["control"].get("reason")))
                if not args.dry_run:
                    try:
                        cmd_pull(argparse.Namespace(dry_run=False, down=False))
                    except (SystemExit, StepFailed) as e:
                        say("pull failed: %s" % e)
                return cmd_down(args)
            if args.pull_every and now - last_pull > args.pull_every * 60 and not args.dry_run:
                try:
                    cmd_pull(argparse.Namespace(dry_run=False, down=False))
                except (SystemExit, StepFailed) as e:
                    say("pull failed: %s" % e)
                last_pull = now
            say("%s  %d boxes, spent %.4f EUR, %s games, %.1f games/s" % (time.strftime("%H:%M:%S"), len(servers), spent, st.get("games", "?"), st.get("gps") or 0))
        nap(args.every, "watch")


LUAJIT_COMMIT = "2a8e017ef1ece6a95b983ffca073d30609dce7c4"
LUAJIT_VERSION = "2.1.1791988261"
LUAJIT_SHA256 = "54705d4b1de50a9c668539b9cf0dc3170d94ffdad51fafd1cf4477e498be7144"
LUAJIT_URL = "https://github.com/LuaJIT/LuaJIT/archive/%s.tar.gz" % LUAJIT_COMMIT
GOLDEN = os.environ.get("BOTSIM_GOLDEN_TEST", "tools/botsim/test/test_econ.lua")
LUAJIT_SETUP = ("set -e; want=%s; have=$(/usr/local/bin/luajit -v 2>/dev/null | awk '{print $2}'); "
                "if [ \"$have\" != \"$want\" ]; then rm -rf /opt/botsim/luajit-src; mkdir -p /opt/botsim/luajit-src; "
                "tar -xzf /opt/botsim/luajit.tar.gz -C /opt/botsim/luajit-src --strip-components=1; "
                "make -C /opt/botsim/luajit-src -j\"$(nproc)\" PREFIX=/usr/local XCFLAGS=-ffp-contract=off >/var/log/botsim-luajit-build.log 2>&1 "
                "|| { tail -n 20 /var/log/botsim-luajit-build.log; exit 1; }; "
                "make -C /opt/botsim/luajit-src install PREFIX=/usr/local >>/var/log/botsim-luajit-build.log 2>&1; fi; "
                "ln -sf /usr/local/bin/luajit-$want /usr/local/bin/luajit; /usr/local/bin/luajit -v") % LUAJIT_VERSION
GOLDEN_CHECK = ("cd /opt/botsim/repo && test -f %s || { echo 'golden test %s missing in the deployed tree'; exit 3; }; "
                "make -B -C tools/botsim/c >/var/log/botsim-clib.log 2>&1 || { tail -n 20 /var/log/botsim-clib.log; exit 4; }; "
                "timeout 300 /usr/local/bin/luajit tools/botsim/fuzz_scan.lua n=200 2>&1 | tail -n 5; test ${PIPESTATUS[0]} -eq 0 || exit 5; "
                "timeout 600 /usr/local/bin/luajit tools/botsim/test/run.lua 2>&1 | tail -n 15; exit ${PIPESTATUS[0]}") % (shlex.quote(GOLDEN), GOLDEN)


def tarball_ok(path):
    import hashlib
    import tarfile
    with open(path, "rb") as f:
        if hashlib.sha256(f.read()).hexdigest() == LUAJIT_SHA256:
            return True
    try:
        with tarfile.open(path) as t:
            m = next((x for x in t.getmembers() if x.name.endswith("/.relver")), None)
            return bool(m) and t.extractfile(m).read().decode().strip() == LUAJIT_VERSION.rsplit(".", 1)[1]
    except (tarfile.TarError, OSError):
        return False


def luajit_tarball(fetch=True):
    if os.environ.get("BOTSIM_LUAJIT_TARBALL"):
        return os.environ["BOTSIM_LUAJIT_TARBALL"]
    path = os.path.join(CONF, "cache", "luajit-%s.tar.gz" % LUAJIT_COMMIT[:12])
    if os.path.exists(path) and tarball_ok(path):
        return path
    if not fetch:
        return None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with urllib.request.urlopen(LUAJIT_URL, timeout=60) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    if not tarball_ok(tmp):
        os.remove(tmp)
        raise SystemExit("downloaded LuaJIT %s does not match the pinned commit" % LUAJIT_COMMIT[:12])
    os.replace(tmp, path)
    return path


def box_luajit_and_golden(b, dry):
    rsync(b, luajit_tarball() if not dry else "luajit.tar.gz", "%s@%s:/opt/botsim/luajit.tar.gz" % (ssh_user(), b["ip"]), dry, delete=False)
    out = ssh(b, LUAJIT_SETUP, dry, check=False, timeout=1200) if not dry else ssh(b, LUAJIT_SETUP, True)
    if not dry and LUAJIT_VERSION not in out:
        raise StepFailed("LuaJIT %s build failed on %s: %s" % (LUAJIT_VERSION, b["name"], out.strip()[-600:] or "no output"))
    GUARD.check("deploy:luajit")
    try:
        out = ssh(b, GOLDEN_CHECK, dry, timeout=700)
    except StepFailed as e:
        raise StepFailed("golden sim test failed on %s, no job will start there: %s" % (b["name"], e))
    if not dry:
        say("  LuaJIT %s, sim tests: %s" % (LUAJIT_VERSION, (out.strip().splitlines() or ["?"])[-1]))


def job_mode_problems():
    probs = []
    r = subprocess.run(["git", "ls-files", "-s", "--", os.path.join(CLOUD, "jobs")], cwd=REPO, capture_output=True, text=True)
    if r.returncode != 0:
        return ["git ls-files failed: %s" % r.stderr.strip()[:200]]
    for line in r.stdout.splitlines():
        meta, _, path = line.partition("\t")
        if path.endswith("/run") and meta.split()[0] != "100755":
            probs.append("%s is %s in git, it must be 100755 (git update-index --chmod=+x %s)" % (path, meta.split()[0], path))
    jobs = os.path.join(CLOUD, "jobs")
    for name in sorted(os.listdir(jobs)) if os.path.isdir(jobs) else []:
        f = os.path.join(jobs, name, "run")
        if os.path.isfile(f) and not os.access(f, os.X_OK):
            probs.append("%s is not executable on disk (chmod +x)" % os.path.relpath(f, REPO))
    return probs


def doctor(a, args, live=None, c=None, verbose=True, flow=None):
    probs = []

    def ok(m):
        if verbose:
            say("ok    " + m)

    def bad(m):
        probs.append(m)
        if verbose:
            say("FAIL  " + m)

    def info(m):
        if verbose:
            say("info  " + m)

    for t in ("ssh", "rsync", "ssh-keygen"):
        (ok if shutil.which(t) else bad)("local tool %s %s" % (t, "found" if shutil.which(t) else "missing"))
    if results_backup():
        ok("results backup to %s set up (head box pushes every 10 min and at stop)" % RESULTS_REPO)
    else:
        info("results backup not set up, runs are only pulled to this PC (hz.py results-setup)")
    tok = os.environ.get("BOTSIM_TOKEN_FILE") or os.path.expanduser("~/.config/botsim/hetzner_token")
    if os.path.exists(tok) and os.stat(tok).st_mode & 0o077:
        bad("token file %s is readable by other users (chmod 600 it)" % tok)
    account = None
    try:
        account = a.get("/ssh_keys")["ssh_keys"]
        ok("API token accepted")
    except ApiError as e:
        bad("API token rejected or API down: %s" % e)
    except Exception as e:
        bad("API not reachable: %s" % e)
    if account is None:
        return probs
    derived = None
    if not os.path.exists(SSH_KEY):
        bad("private ssh key %s missing" % SSH_KEY)
    else:
        r = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", SSH_KEY], capture_output=True, text=True)
        if r.returncode != 0:
            bad("cannot read %s without a passphrase (BatchMode ssh needs that): %s" % (SSH_KEY, r.stderr.strip()[:120]))
        else:
            derived = r.stdout.split()[:2]
            pubf = SSH_KEY + ".pub"
            if os.path.exists(pubf) and open(pubf).read().split()[:2] != derived:
                bad("%s does not belong to %s" % (pubf, SSH_KEY))
    mine = next((k for k in account if k.get("name") == SSH_KEY_NAME), None)
    if not mine:
        bad("no ssh key named %s on the Hetzner account" % SSH_KEY_NAME)
    elif derived and mine.get("public_key", "").split()[:2] != derived:
        bad("ssh key %s on the account is not the local key %s, boxes would refuse the login" % (SSH_KEY_NAME, SSH_KEY))
    elif derived:
        ok("ssh key %s on the account matches %s" % (SSH_KEY_NAME, SSH_KEY))
    if live is None:
        live = a.servers()
    if c is None:
        c = load_json(CURRENT)
    led = ledger()
    ids = {e["id"] for e in led.get("servers", [])}
    cur_run = c.get("run") if c else None
    planned = {b["name"] for b in (c or {}).get("planned", []) + (c or {}).get("boxes", [])}
    mine_live = []
    explicit = getattr(args, "adopt", False) or getattr(args, "replace", False)
    for s in live:
        run = (s.get("labels") or {}).get("botsim-run")
        if explicit and (s["id"] not in ids or run != cur_run):
            info("server %s of run %s is handled by --%s" % (s["name"], run, "replace" if getattr(args, "replace", False) else "adopt"))
            mine_live.append(s)
        elif s["id"] not in ids and s["name"] not in planned:
            bad("server %s (id %s) is not in the ledger: someone or something created it outside hz.py. hz.py list adds it, then adopt or down" % (s["name"], s["id"]))
        elif run != cur_run:
            bad("stray server %s from run %s, not the current run; hz.py down deletes it, or it deletes itself at %s" % (
                s["name"], run, hm(float((s.get("labels") or {}).get("botsim-deadline") or 0))))
        else:
            mine_live.append(s)
    if mine_live:
        info("%d server(s) of the current run %s are up; up, bench and smoke adopt them" % (len(mine_live), cur_run))
    elif not live:
        ok("no botsim servers running")
    gone = [e["name"] for e in led.get("servers", []) if not e.get("deleted") and e["id"] not in {s["id"] for s in live}]
    if gone:
        info("ledger still has %d box(es) open that the API no longer lists (%s); the next status or list marks them deleted" % (len(gone), ", ".join(gone)))
    else:
        ok("ledger agrees with the API (%.4f EUR spent of %.2f)" % (ledger_spent(led), float(led.get("cap_eur", CAP_EUR))))
    try:
        types, ipv4, pricing = catalog(a)
        locs = [x.strip() for x in getattr(args, "locations", DEFAULT_LOCATIONS).split(",") if x.strip()]
        missing = [l for l in locs if l not in ipv4]
        if missing:
            bad("no IPv4 price for %s" % ",".join(missing))
        else:
            ok("prices fetched (%d server types, VAT %s%%)" % (len(types), str(pricing.get("vat_rate")).rstrip("0").rstrip(".")))
    except Exception as e:
        bad("prices could not be fetched: %s" % e)
    if getattr(args, "types", None) and not mine_live:
        try:
            p = make_plan(a, args)
            pp = plan_problems(p)
            for pr in pp:
                bad(pr)
            if not pp:
                ok("plan fits: %s, %.4f EUR, limits %s" % (args.types, p["cost"], ", ".join("%s %d/%d" % (k, p["used"].get(k, 0), v) for k, v in p["limits"].items())))
        except SystemExit as e:
            bad(str(e))
    legacy = os.path.join(CONF, "known_hosts")
    if os.path.exists(legacy):
        info("old shared known_hosts %s is no longer used (each run pins its own host keys)" % legacy)
    if c and c.get("boxes"):
        kh = known_hosts_path(CONF, c["run"])
        n = len(open(kh).read().splitlines()) if os.path.exists(kh) else 0
        pinned = sum(1 for b in c["boxes"] if b.get("host_pub") and not b.get("trust_new"))
        (ok if n == pinned else bad)("known_hosts of run %s pins %d of %d boxes (%s)" % (c["run"], n, len(c["boxes"]), kh))
    jp = job_mode_problems()
    for pr in jp:
        bad(pr)
    if not jp:
        ok("job scripts are executable in git and on disk")
    golden = os.path.join(REPO, GOLDEN)
    (ok if os.path.isfile(golden) else bad)("golden sim test %s %s (every box runs the sim tests before a job)" % (GOLDEN, "present" if os.path.isfile(golden) else "missing"))
    try:
        ok("LuaJIT %s source (commit %s) cached at %s" % (LUAJIT_VERSION, LUAJIT_COMMIT[:12], luajit_tarball()))
    except (OSError, SystemExit) as e:
        bad("LuaJIT %s source not available: %s" % (LUAJIT_VERSION, e))
    if flow == "bench":
        for f in BENCH_FILES:
            (ok if os.path.isfile(os.path.join(REPO, f)) else bad)("%s %s" % (f, "present" if os.path.isfile(os.path.join(REPO, f)) else "missing"))
    return probs


def cmd_doctor(args):
    say("doctor: free checks, creates nothing")
    try:
        a = api()
    except (OSError, SystemExit) as e:
        say("FAIL  token: %s" % e)
        return 1
    probs = doctor(a, args, flow=args.flow)
    say("")
    say("%d problem(s)" % len(probs) if probs else "all good")
    return 1 if probs else 0


BENCH_FILES = ["tools/botsim/train/bench_mcts.lua", "tools/botsim/bench.lua"]
BENCH_CMD = ("cd /opt/botsim/repo && echo '== cpu' && (lscpu | sed -n 's/^Model name: *//p') && nproc && "
             "echo '== bench_mcts' && timeout 1500 luajit tools/botsim/train/bench_mcts.lua; echo \"exit $?\"; "
             "echo '== bench 40' && timeout 1500 luajit tools/botsim/bench.lua 40; echo \"exit $?\"")


def flow_up(args, flow):
    RETRY["cmd"] = this_cmd()
    say("== %s: doctor and up" % flow)
    up_args = argparse.Namespace(**dict(vars(args), dry_run=False, skip_doctor=False))
    if args.dry_run:
        return cmd_up(argparse.Namespace(**dict(vars(up_args), dry_run=True))) or None
    rc = cmd_up(up_args)
    if rc:
        return rc
    c = current()
    c["flow"] = {"name": flow, "types": args.types}
    save_state(c)
    say("== %s: deploy" % flow)
    return cmd_deploy(argparse.Namespace(job=None, dry_run=False, force=False, trust_new_host_keys=args.trust_new_host_keys)) or None


def bench_summary(c, results, path):
    lines = ["# Bench %s" % c["run"], "",
             "Measured %s by `hz.py bench --types %s`. Each box ran `luajit tools/botsim/train/bench_mcts.lua` then `luajit tools/botsim/bench.lua 40`." % (
                 iso(time.time()), (c.get("flow") or {}).get("types", "")), "",
             "| box | type | location | CPU | vCPUs | EUR/h gross |", "| --- | --- | --- | --- | ---: | ---: |"]
    for b in c["boxes"]:
        out = results.get(b["name"], "")
        sec = out.split("== cpu", 1)[-1].strip().splitlines()
        cpu = sec[0] if sec else "?"
        n = sec[1] if len(sec) > 1 else "?"
        lines.append("| %s | %s | %s | %s | %s | %.5f |" % (b["name"], b["type"], b.get("location"), cpu, n, b["price_hourly_gross"]))
    for b in c["boxes"]:
        lines += ["", "## %s (%s)" % (b["name"], b["type"]), "", "```", results.get(b["name"], "").strip(), "```"]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def cmd_bench(args):
    if not args.dry_run:
        require_shared()
    rc = flow_up(args, "bench")
    if args.dry_run:
        say("DRY RUN: then on every box: " + BENCH_CMD)
        return rc or 0
    if rc:
        return rc
    c = current()
    raw = os.path.join(RESULTS, "bench-" + c["run"])
    os.makedirs(raw, exist_ok=True)
    say("== bench: running the benchmarks on %d boxes in parallel" % len(c["boxes"]))
    results, errors = {}, {}

    def one(b):
        f = os.path.join(raw, b["name"] + ".txt")
        if b.get("bench_done") and os.path.exists(f):
            results[b["name"]] = open(f).read()
            return
        r_rc, out, err = run_cmd(ssh_argv(b, BENCH_CMD), timeout=3300)
        if r_rc != 0 or out.count("exit 0") < 2:
            errors[b["name"]] = "exit %d: %s" % (r_rc, (err or out).strip()[-300:])
            return
        with open(f, "w") as fh:
            fh.write(out)
        results[b["name"]] = out

    threads = [threading.Thread(target=one, args=(b,), daemon=True) for b in c["boxes"]]
    for t in threads:
        t.start()
    while any(t.is_alive() for t in threads):
        for t in threads:
            t.join(0.5)
        GUARD.check("bench:run")
    for b in c["boxes"]:
        if b["name"] in results:
            b["bench_done"] = True
    save_state(c)
    GUARD.check("bench:collected")
    if errors:
        report_failures(c, "bench", [(b, errors[b["name"]]) for b in c["boxes"] if b["name"] in errors], this_cmd())
        return 2
    md = os.path.join(RESULTS, "bench-%s.md" % c["run"])
    bench_summary(c, results, md)
    say("results: %s" % md)
    say("== bench: down")
    return cmd_down(argparse.Namespace(dry_run=False))


def cmd_smoke(args):
    if not args.dry_run:
        require_shared()
    args.types = args.type
    rc = flow_up(args, "smoke")
    if args.dry_run:
        say("DRY RUN: then run fake for %s min, wait for games on the dashboard, pull, down" % args.minutes)
        return rc or 0
    if rc:
        return rc
    say("== smoke: run the fake job")
    rc = cmd_run(argparse.Namespace(job="fake", env=["BOTSIM_FAKE_MINUTES=%s" % args.minutes], workers=None, remote_job=False,
                                    dry_run=False, force=False))
    if rc:
        return rc
    c = current()
    say("== smoke: waiting for games on the dashboard (up to %d s)" % args.wait)
    t_end = time.time() + args.wait
    st = {}
    while time.time() < t_end:
        st = head_state(c)
        if (st.get("games") or 0) > 0:
            break
        nap(5, "smoke:wait")
    if not (st.get("games") or 0) > 0:
        report_failures(c, "smoke", [(c["boxes"][0], "no games on the dashboard after %d s: %s" % (args.wait, st.get("error") or "games = 0"))], this_cmd())
        return 2
    say("dashboard ok: %s games, %.1f games/s" % (st.get("games"), st.get("gps") or 0))
    GUARD.check("smoke:seen")
    say("== smoke: pull and down")
    rc = cmd_pull(argparse.Namespace(dry_run=False, down=True))
    if rc:
        return rc
    left = api().servers()
    if left:
        say("WARNING: still listed: %s" % ", ".join(s["name"] for s in left))
        return 1
    say("smoke passed: create, ssh with a pinned host key, cloud-init, deploy, job, dashboard, pull, delete")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="hz.py", description="botsim Hetzner runner. Every paid run needs Gabriel's OK.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def plan_args(p):
        p.add_argument("--types", default=DEFAULT_TYPES, help="comma list, type[:count] (default %s)" % DEFAULT_TYPES)
        p.add_argument("--hours", type=float, default=1.0, help="max hours; boxes delete themselves after this (default 1)")
        p.add_argument("--spend-cap", type=float, help="spend cap for this run in EUR (default: the planned cost)")
        p.add_argument("--locations", default=DEFAULT_LOCATIONS)
        p.add_argument("--limit-shared", type=int, default=LIMITS["shared"])
        p.add_argument("--limit-dedicated", type=int, default=LIMITS["dedicated"])

    p = sub.add_parser("plan", help="show what a run costs")
    p.add_argument("--json", action="store_true")
    plan_args(p)
    def up_args(p):
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--yes", action="store_true", help="skip the confirm prompt")
        p.add_argument("--adopt", action="store_true", help="reuse existing botsim boxes as they are, even if they differ from --types")
        p.add_argument("--replace", action="store_true", help="delete existing botsim boxes first (their paid hour is lost)")
        p.add_argument("--min-left", type=int, default=10, help="minutes before their deadline under which existing boxes are not adopted (default 10)")
        p.add_argument("--skip-doctor", action="store_true", help=argparse.SUPPRESS)

    p = sub.add_parser("up", help="create the servers (adopts the boxes of an interrupted run)")
    plan_args(p)
    up_args(p)
    p = sub.add_parser("deploy", help="copy assets/bot and tools/botsim to every box")
    p.add_argument("--job", help="extra job dir to copy to /opt/botsim/jobs/")
    p.add_argument("--for-job", help="also install what this job needs (the train job: CPU torch and numpy), only on boxes that lack it")
    p.add_argument("--force", action="store_true", help="redeploy boxes already deployed")
    p.add_argument("--trust-new-host-keys", action="store_true", help="trust the host key the boxes show now (when pinning keeps failing)")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("run", help="start a job on every box")
    p.add_argument("job")
    p.add_argument("--env", action="append", help="KEY=VALUE passed to the job, repeatable")
    p.add_argument("--workers", type=int, help="worker count (default: cores)")
    p.add_argument("--remote-job", action="store_true", help="job lives in /opt/botsim/jobs (deploy --job)")
    p.add_argument("--force", action="store_true", help="restart the job on boxes that already run it")
    p.add_argument("--delete-when-done", action="store_true", help="delete every box as soon as the head's job exits (BOTSIM_DELETE_WHEN_DONE=1)")
    p.add_argument("--json", action="store_true", help="print one JSON object last")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("status", help="boxes, spend, live job numbers")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("pull", help="fetch results to tools/botsim/results/<run>/")
    p.add_argument("--down", action="store_true", help="delete every box after pulling")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("down", help="delete every botsim server and verify")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("list", help="list botsim servers")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("spend", help="regenerate and print SPEND.md")
    p.add_argument("--json", action="store_true")
    sub.add_parser("results-setup", help="make the private results repo, its write deploy key and pin GitHub's host keys (free, once)")
    p = sub.add_parser("alerts-test", help="make the secret ntfy topic if needed and send a test alert to the phone")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("watch", help="local watchdog: delete late boxes, stop at the cap, pull and down when the run stops")
    p.add_argument("--every", type=int, default=30, help="seconds between checks")
    p.add_argument("--pull-every", type=int, default=10, help="minutes between pulls, 0 = only at the end")
    p.add_argument("--dry-run", action="store_true")
    p = sub.add_parser("doctor", help="free checks before a paid run, creates nothing")
    p.add_argument("--types", help="also check this plan (type[:count] list)")
    p.add_argument("--hours", type=float, default=1.0)
    p.add_argument("--spend-cap", type=float)
    p.add_argument("--locations", default=DEFAULT_LOCATIONS)
    p.add_argument("--limit-shared", type=int, default=LIMITS["shared"])
    p.add_argument("--limit-dedicated", type=int, default=LIMITS["dedicated"])
    p.add_argument("--flow", choices=["bench", "smoke"], help=argparse.SUPPRESS)
    p = sub.add_parser("bench", help="one shot: up, deploy, run both benchmarks on every box, write results/bench-<run>.md, down")
    plan_args(p)
    up_args(p)
    p.add_argument("--trust-new-host-keys", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(hours=0.9)
    p = sub.add_parser("smoke", help="one shot end-to-end check on the cheapest box: up, deploy, fake job, dashboard, pull, down")
    plan_args(p)
    up_args(p)
    p.add_argument("--type", default="cx23", help="box type (default cx23)")
    p.add_argument("--minutes", default="3", help="fake job length in minutes (default 3)")
    p.add_argument("--wait", type=int, default=420, help="seconds to wait for games on the dashboard (default 420)")
    p.add_argument("--trust-new-host-keys", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(hours=0.9)
    args = ap.parse_args()
    if not hasattr(args, "skip_doctor"):
        args.skip_doctor = False
    fn = {"plan": cmd_plan, "up": cmd_up, "deploy": cmd_deploy, "run": cmd_run, "status": cmd_status, "pull": cmd_pull,
          "down": cmd_down, "list": cmd_list, "spend": cmd_spend, "watch": cmd_watch, "doctor": cmd_doctor, "alerts-test": cmd_alerts_test, "results-setup": cmd_results_setup,
          "bench": cmd_bench, "smoke": cmd_smoke}[args.cmd]
    GUARD.install()
    sys.exit(run_guarded(fn, args))


def run_guarded(fn, args):
    try:
        return fn(args) or 0
    except Interrupted as e:
        say("")
        say("stopped cleanly after %s (%s). The run state is saved in %s." % (e.sig, e.where, CURRENT))
        kept_notice(load_json(CURRENT))
        say("resume: " + retry_cmd(this_cmd()))
        return 130
    except KeyboardInterrupt:
        say("")
        say("forced stop. The run state is saved after every finished step, so a box created by a request in flight is adopted by name.")
        kept_notice(load_json(CURRENT))
        say("resume: " + retry_cmd(this_cmd()))
        return 130
    except StepFailed as e:
        say("FAILED: %s" % e)
        kept_notice(load_json(CURRENT))
        say("retry: " + retry_cmd(this_cmd()))
        return 2
    except ApiError as e:
        raise SystemExit("Hetzner API error: %s" % e)


if __name__ == "__main__":
    main()
