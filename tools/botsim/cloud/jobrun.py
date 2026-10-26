import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import load_json

ETC = os.environ.get("BOTSIM_ETC", "/etc/botsim")
HOME = os.environ.get("BOTSIM_HOME", "/opt/botsim")
REPO = os.environ.get("BOTSIM_REPO", os.path.join(HOME, "repo"))
CLOUD = os.path.dirname(os.path.abspath(__file__))


def metric(path, **kw):
    kw.setdefault("t", time.time())
    with open(path, "a") as f:
        f.write(json.dumps(kw, separators=(",", ":")) + "\n")


def write_marker(path, **kw):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(kw, f)
    os.replace(tmp, path)


def delete_when_done(etc=ETC):
    try:
        for ln in open(os.path.join(etc, "job.env")):
            if ln.strip() == "BOTSIM_DELETE_WHEN_DONE=1":
                return True
    except OSError:
        pass
    return os.environ.get("BOTSIM_DELETE_WHEN_DONE") == "1"


def resolve(job):
    for base in (os.path.join(CLOUD, "jobs"), os.path.join(HOME, "jobs")):
        d = os.path.join(base, job)
        if os.path.isfile(os.path.join(d, "run")):
            return d
    if os.path.isfile(os.path.join(job, "run")):
        return os.path.abspath(job)
    raise SystemExit("job not found: " + job)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: jobrun.py <job>")
    job_dir = resolve(sys.argv[1])
    node = load_json(os.path.join(ETC, "node.json"), {}) or {}
    run_dir = os.path.join(HOME, "run")
    os.makedirs(os.path.join(run_dir, "checkpoints"), exist_ok=True)
    metrics = os.path.join(run_dir, "metrics.jsonl")
    stop_file = os.path.join(run_dir, "STOP")
    if os.path.exists(stop_file):
        os.remove(stop_file)
    workers = int(os.environ.get("BOTSIM_WORKERS") or node.get("workers") or os.cpu_count() or 1)
    env = dict(os.environ)
    env.update({
        "BOTSIM_RUN": str(node.get("run", "local")),
        "BOTSIM_BOX": str(node.get("name", "local")),
        "BOTSIM_ROLE": str(node.get("role", "head")),
        "BOTSIM_DEADLINE": str(node.get("deadline", 0)),
        "BOTSIM_WORKERS": str(workers),
        "BOTSIM_RUN_DIR": run_dir,
        "BOTSIM_METRICS": metrics,
        "BOTSIM_CHECKPOINTS": os.path.join(run_dir, "checkpoints"),
        "BOTSIM_STOP_FILE": stop_file,
        "BOTSIM_PEERS": os.path.join(ETC, "run.json"),
        "BOTSIM_REPO": REPO,
        "BOTSIM_JOB_DIR": job_dir,
    })
    metric(metrics, type="state", state="starting", box=env["BOTSIM_BOX"], job=os.path.basename(job_dir), workers=workers)
    started = time.time()
    write_marker(os.path.join(run_dir, "JOB_START"), t=started, pid=os.getpid(), job=os.path.basename(job_dir))
    p = subprocess.Popen([os.path.join(job_dir, "run")], cwd=REPO, env=env, start_new_session=True)
    with open(os.path.join(run_dir, "job.pid"), "w") as f:
        f.write(str(os.getpid()))
    stopping = {"at": None}

    def on_term(sig, frame):
        open(stop_file, "w").close()
        stopping["at"] = time.time()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    timeout = float(os.environ.get("BOTSIM_JOB_STOP_TIMEOUT", "150"))
    while True:
        try:
            rc = p.wait(timeout=1)
            break
        except subprocess.TimeoutExpired:
            pass
        if stopping["at"] is None and os.path.exists(stop_file):
            stopping["at"] = time.time()
        if stopping["at"] is not None and time.time() - stopping["at"] > timeout:
            os.killpg(p.pid, signal.SIGKILL)
            rc = p.wait()
            metric(metrics, type="state", state="killed", box=env["BOTSIM_BOX"], msg="job ignored STOP for %ds" % timeout)
            rc = None
            break
    how = "killed" if rc is None else ("done" if rc == 0 else "failed")
    write_marker(os.path.join(run_dir, "JOB_EXIT"), t=time.time(), start=started, rc=rc, how=how, signalled=stopping["at"] is not None,
                 job=os.path.basename(job_dir))
    if stopping["at"] is None and env["BOTSIM_ROLE"] == "head" and delete_when_done():
        req = os.path.join(run_dir, "STOP_REQUEST")
        if not os.path.exists(req):
            with open(req, "w") as f:
                f.write("job %s, delete when done" % how)
    if rc is None:
        pass
    elif rc == 0:
        metric(metrics, type="exit", box=env["BOTSIM_BOX"], code=rc)
    else:
        metric(metrics, type="state", state="failed", box=env["BOTSIM_BOX"], code=rc)
    try:
        os.remove(os.path.join(run_dir, "job.pid"))
    except OSError:
        pass
    sys.exit(0 if rc == 0 else 1)


if __name__ == "__main__":
    main()
