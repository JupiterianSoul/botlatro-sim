import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import Api, load_json, save_json, next_hour_boundary, box_cost, read_token, CAP_EUR

ETC = os.environ.get("BOTSIM_ETC", "/etc/botsim")
HOME = os.environ.get("BOTSIM_HOME", "/opt/botsim")
RUN_DIR = os.path.join(HOME, "run")
CONTROL = os.path.join(HOME, "control.json")
METADATA = os.environ.get("BOTSIM_METADATA", "http://169.254.169.254/hetzner/v1/metadata")
LOG = os.environ.get("BOTSIM_LOG", "/var/log/botsim-watchdog.log")
STOP_TIMEOUT = int(os.environ.get("BOTSIM_STOP_TIMEOUT", "180"))
BACKUP_DIR = os.environ.get("BOTSIM_BACKUP_DIR", "/var/lib/botsim/results-repo")
BACKUP_MAX_BYTES = int(os.environ.get("BOTSIM_BACKUP_MAX_BYTES", str(50 * 1024 * 1024)))
GIT_AUTHOR = ["-c", "user.name=Gabriel Quart", "-c", "user.email=gabriel.quart.15@gmail.com"]


def log(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def box():
    b = load_json(os.path.join(ETC, "box.json"))
    if not b:
        raise SystemExit("no box.json in " + ETC)
    return b


def api(b):
    return Api(read_token(os.path.join(ETC, "token")), base=b.get("api"))


def control():
    return load_json(CONTROL, {}) or {}


def set_control(**kw):
    c = control()
    c.update(kw)
    c["t"] = time.time()
    save_json(CONTROL, c)
    return c


def job_alive(run_dir=RUN_DIR):
    try:
        pid = int(open(os.path.join(run_dir, "job.pid")).read().strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def own_id(b, a):
    try:
        with urllib.request.urlopen(METADATA + "/instance-id", timeout=5) as r:
            return int(r.read().decode().strip())
    except Exception:
        pass
    if b.get("id"):
        return int(b["id"])
    found = a.get("/servers?name=" + urllib.request.quote(b["name"])).get("servers", [])
    return found[0]["id"] if found else None


def self_delete(b):
    a = api(b)
    sid = own_id(b, a)
    if sid is None:
        log("self delete: server %s not found, nothing to delete" % b["name"])
        return True
    log("self delete: deleting server %s id %s" % (b["name"], sid))
    a.delete_server(sid)
    log("self delete: request accepted")
    return True


def request_stop(reason):
    os.makedirs(RUN_DIR, exist_ok=True)
    p = os.path.join(RUN_DIR, "STOP_REQUEST")
    if not os.path.exists(p):
        with open(p, "w") as f:
            f.write(reason)


def job_env(etc=ETC):
    env = {}
    try:
        for ln in open(os.path.join(etc, "job.env")):
            k, _, v = ln.strip().partition("=")
            if k:
                env[k] = v
    except OSError:
        pass
    return env


def unit_active():
    try:
        r = subprocess.run(["systemctl", "is-active", "botsim-job"], capture_output=True, text=True, timeout=20)
        return r.stdout.strip() in ("active", "activating", "deactivating", "reloading")
    except (OSError, subprocess.SubprocessError):
        return False


def done_check(b, c, now, active=unit_active):
    if b.get("role") != "head" or job_env().get("BOTSIM_DELETE_WHEN_DONE") != "1":
        return False
    if c.get("state") in ("stopping", "stopped") or os.path.exists(os.path.join(RUN_DIR, "STOP_REQUEST")):
        return False
    rs = os.path.join(RUN_DIR, "RESTARTING")
    if os.path.exists(rs) and now - os.path.getmtime(rs) < 600:
        return False
    start = load_json(os.path.join(RUN_DIR, "JOB_START"), None)
    ex = load_json(os.path.join(RUN_DIR, "JOB_EXIT"), None)
    if not start or not ex or float(ex.get("start", 0)) != float(start.get("t", -1)) or float(ex.get("t", 0)) < float(start["t"]):
        return False
    if job_alive() or active():
        return False
    log("job exited (%s) and BOTSIM_DELETE_WHEN_DONE=1: stopping the run and deleting the boxes" % ex.get("how"))
    request_stop("job %s, delete when done" % ex.get("how"))
    return True


def tick():
    b = box()
    now = time.time()
    c = control()
    try:
        done_check(b, c, now)
    except Exception as e:
        log("delete when done check failed: %s" % e)
    deadline = float(b["deadline"])
    effective = min(deadline, float(c.get("keep_until") or deadline))
    if now >= effective:
        try:
            self_delete(b)
        except Exception as e:
            log("self delete failed, retrying next tick: %s" % e)
        return
    lead = float(b.get("save_lead", 480))
    if now >= deadline - lead and c.get("state") not in ("stopping", "stopped"):
        log("deadline in %ds, asking the job to save" % int(deadline - now))
        request_stop("deadline")


def http(url, data=None, timeout=10):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def node_url(n, secret, path):
    return "http://%s:%s/%s/api/%s" % (n["ip"], n.get("port"), secret, path)


def stop_job_local():
    os.makedirs(RUN_DIR, exist_ok=True)
    open(os.path.join(RUN_DIR, "STOP"), "w").close()


def fetch_results(n, secret, dest):
    raw = http(node_url(n, secret, "results.tgz"), timeout=120)
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as t:
        t.extractall(dest, filter="data")


def stop(reason=None):
    p = os.path.join(RUN_DIR, "STOP_REQUEST")
    if reason is None:
        try:
            reason = open(p).read().strip() or "emergency"
        except OSError:
            reason = "emergency"
    try:
        os.replace(p, p + ".done")
    except OSError:
        pass
    b = box()
    stop_job_local()
    if b.get("role") != "head":
        log("node stop (%s): job asked to save" % reason)
        return
    c = control()
    if c.get("state") in ("stopping", "stopped"):
        log("stop (%s): already %s" % (reason, c.get("state")))
        return
    run = load_json(os.path.join(ETC, "run.json"), {}) or {}
    secret = b["secret"]
    nodes = [dict(n, port=b["port"]) for n in run.get("boxes", []) if n["name"] != b["name"]]
    set_control(state="stopping", reason=reason, started=time.time())
    log("stop (%s): %d other boxes" % (reason, len(nodes)))
    for n in nodes:
        try:
            http(node_url(n, secret, "node-stop"), data=b"1")
        except Exception as e:
            log("node-stop %s failed: %s" % (n["name"], e))
    t_end = time.time() + STOP_TIMEOUT
    pending = {n["name"] for n in nodes}
    while time.time() < t_end:
        for n in nodes:
            if n["name"] in pending:
                try:
                    st = json.loads(http(node_url(n, secret, "node?since=-1")))
                    if not st.get("job_active"):
                        pending.discard(n["name"])
                except Exception:
                    pass
        if not pending and not job_alive():
            break
        time.sleep(2)
    results, deleted = {}, dict(c.get("deleted") or {})
    for n in nodes:
        try:
            fetch_results(n, secret, os.path.join(RUN_DIR, "boxes", n["name"]))
            results[n["name"]] = "ok"
        except Exception as e:
            results[n["name"]] = "failed: %s" % e
            log("results from %s failed: %s" % (n["name"], e))
    results[b["name"]] = "ok" if not job_alive() else "job still running"
    a = api(b)
    for n in nodes:
        try:
            a.delete_server(n["id"])
            deleted[n["name"]] = time.time()
            log("deleted %s" % n["name"])
        except Exception as e:
            log("delete %s failed: %s" % (n["name"], e))
    now = time.time()
    me = next((x for x in run.get("boxes", []) if x["name"] == b["name"]), {})
    created = float(me.get("created") or b.get("created_hint") or now)
    hour_end = next_hour_boundary(created, now)
    keep = max(hour_end - 120, now + 600)
    if keep > hour_end:
        spent = float(run.get("spent_before", 0))
        for x in run.get("boxes", []):
            end = deleted.get(x["name"]) or now
            spent += box_cost(float(x["created"]), end, float(x["price_hourly_gross"]))
        if spent + float(me.get("price_hourly_gross", 0)) > float(run.get("cap", CAP_EUR)):
            keep = max(now + 60, hour_end - 60)
    keep = min(keep, float(b["deadline"]))
    set_control(state="stopped", reason=reason, keep_until=keep, deleted=deleted, results=results, stopped=now)
    log("stopped (%s), head kept until %s for pull" % (reason, time.strftime("%H:%M:%S", time.localtime(keep))))
    try:
        backup()
    except Exception as e:
        log("backup after stop failed: %s" % e)


def git(args, cwd=None):
    key, known = os.path.join(ETC, "results_key"), os.path.join(ETC, "github_known_hosts")
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0",
               GIT_SSH_COMMAND="ssh -i %s -o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes -o BatchMode=yes" % (key, known))
    r = subprocess.run(["git"] + GIT_AUTHOR + args, cwd=cwd, env=env, capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (args[0], (r.stderr or r.stdout).strip()[-300:]))
    return r.stdout


def backup_ignore(src, names):
    skip = []
    for n in names:
        p = os.path.join(src, n)
        if n == "job.pid" or n.startswith("STOP"):
            skip.append(n)
        elif os.path.isfile(p) and os.path.getsize(p) > BACKUP_MAX_BYTES:
            log("backup: skipped %s (%d MB, over the limit)" % (p, os.path.getsize(p) // (1024 * 1024)))
            skip.append(n)
    return skip


def backup():
    b = box()
    remote = b.get("results_remote")
    if b.get("role") != "head" or not remote:
        return False
    os.makedirs(os.path.dirname(BACKUP_DIR), exist_ok=True)
    with open(BACKUP_DIR + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        if not os.path.isdir(os.path.join(BACKUP_DIR, ".git")):
            git(["clone", "--depth", "1", remote, BACKUP_DIR])
        else:
            git(["fetch", "--depth", "1", "origin"], BACKUP_DIR)
            git(["reset", "--hard", "origin/HEAD"], BACKUP_DIR)
        dest = os.path.join(BACKUP_DIR, "runs", b["run"])
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(RUN_DIR, dest, ignore=backup_ignore)
        run = os.path.join(ETC, "run.json")
        if os.path.exists(run):
            shutil.copy(run, os.path.join(dest, "run.json"))
        git(["add", "-A", "runs"], BACKUP_DIR)
        if not git(["status", "--porcelain"], BACKUP_DIR).strip():
            return True
        git(["commit", "-q", "-m", "%s %s" % (b["run"], time.strftime("%Y-%m-%d %H:%M:%S"))], BACKUP_DIR)
        try:
            git(["push", "-q", "origin", "HEAD"], BACKUP_DIR)
        except RuntimeError:
            git(["pull", "-q", "--rebase", "--depth", "1", "origin", "HEAD"], BACKUP_DIR)
            git(["push", "-q", "origin", "HEAD"], BACKUP_DIR)
        log("backup: pushed %s" % b["run"])
    return True


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "tick"
    if cmd == "tick":
        tick()
    elif cmd == "stop":
        stop(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "backup":
        backup()
    elif cmd == "self-delete":
        self_delete(box())
    else:
        raise SystemExit("usage: boxctl.py tick|stop [reason]|backup|self-delete")


if __name__ == "__main__":
    main()
