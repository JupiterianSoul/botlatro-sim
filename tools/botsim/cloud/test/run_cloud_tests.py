import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import threading
import http.server
import base64
import gzip

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
CLOUD = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(CLOUD, "..", "..", ".."))
PY = sys.executable
NICE = ["nice", "-n", "19", "taskset", "-c", ",".join(str(c) for c in sorted(os.sched_getaffinity(0)))]
procs = []
fails = []
ntfy_log = []


class NtfyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        ntfy_log.append({"topic": self.path.strip("/"), "title": self.headers.get("Title"), "msg": body, "prio": self.headers.get("Priority")})
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


def start_ntfy():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NtfyHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return "http://127.0.0.1:%d" % srv.server_address[1]


def titles():
    return [m["title"] for m in ntfy_log]


def wait_for(fn, timeout=15):
    t_end = time.time() + timeout
    while time.time() < t_end:
        if fn():
            return True
        time.sleep(0.5)
    return False


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(argv, env, log):
    p = subprocess.Popen(argv, env=env, stdout=open(log, "w"), stderr=subprocess.STDOUT, start_new_session=True)
    procs.append(p)
    return p


def check(cond, what):
    print(("ok    " if cond else "FAIL  ") + what, flush=True)
    if not cond:
        fails.append(what)


def hz(env, *args, inp=None, timeout=300):
    r = subprocess.run([PY, os.path.join(CLOUD, "hz.py")] + list(args), env=env, capture_output=True, text=True, input=inp or "", timeout=timeout)
    if os.environ.get("HZ_VERBOSE"):
        print("   $ hz.py %s -> %d\n%s" % (" ".join(args), r.returncode, "\n".join("     " + l for l in (r.stdout + r.stderr).splitlines())))
    return r.returncode, r.stdout + r.stderr


def get(url, data=None, timeout=10):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def stub_servers(api):
    return json.loads(get(api.replace("/v1", "/_log")))["servers"]


def stub_log(api):
    return json.loads(get(api.replace("/v1", "/_log")))["log"]


def stub(tmp, name, *extra):
    port = free_port()
    api = "http://127.0.0.1:%d/v1" % port
    start([PY, os.path.join(HERE, "fake_hetzner.py"), "--port", str(port), "--token", "test-token", "--ssh-pub", os.path.join(tmp, "client_key.pub")] + list(extra),
          dict(os.environ), os.path.join(tmp, name + ".log"))
    return api if wait_http(api.replace("/v1", "/_log")) else None


def wait_http(url, timeout=10):
    t_end = time.time() + timeout
    while time.time() < t_end:
        try:
            get(url, timeout=2)
            return True
        except Exception:
            time.sleep(0.3)
    return False


def main():
    tmp = tempfile.mkdtemp(prefix="botsim-cloud-test-")
    try:
        run_tests(tmp)
    finally:
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        time.sleep(1)
        for p in procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if os.environ.get("KEEP_TEST_LOGS"):
            shutil.copytree(tmp, os.environ["KEEP_TEST_LOGS"], dirs_exist_ok=True, ignore=shutil.ignore_patterns("*.bspr", "*.bnnw", "*.pt", ".venv*"))
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n%d failures" % len(fails) if fails else "\nall passed")
    sys.exit(1 if fails else 0)


def run_tests(tmp):
    key = os.path.join(tmp, "client_key")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key], check=True)
    api = stub(tmp, "stub", "--make-available", "cx23")
    tokf = os.path.join(tmp, "token")
    fd = os.open(tokf, os.O_WRONLY | os.O_CREAT, 0o600)
    os.write(fd, b"test-token\n")
    os.close(fd)
    ntfy = start_ntfy()
    env = dict(os.environ, BOTSIM_API=api, BOTSIM_TOKEN_FILE=tokf, BOTSIM_CONFIG=os.path.join(tmp, "conf"), BOTSIM_LEDGER=os.path.join(tmp, "ledger", "spend.json"),
               BOTSIM_SSH_KEY=key, BOTSIM_RESULTS=os.path.join(tmp, "results"), BOTSIM_DOWN_POLL="0.2", BOTSIM_SSH_RETRY="0.2",
               PATH=os.path.join(HERE, "fakebin") + os.pathsep + os.environ["PATH"], FAKE_SSH_LOG=os.path.join(tmp, "ssh.log"),
               FAKE_RSYNC_LOG=os.path.join(tmp, "rsync.log"), FAKE_SSH_PLAN=os.path.join(tmp, "sshplan.json"),
               BOTSIM_NTFY_URL=ntfy, BOTSIM_DASH_STATE=os.path.join(tmp, "dash-local"), BOTSIM_SHARED_LEDGER="off")
    env.pop("BOTSIM_NTFY_TOPIC_FILE", None)
    env.pop("BOTSIM_TEST_INTERRUPT", None)
    lj = os.path.join(tmp, "luajit.tar.gz")
    open(lj, "wb").write(b"fake")
    env.update(BOTSIM_LUAJIT_TARBALL=lj, BOTSIM_GOLDEN_TEST="tools/botsim/test/run.lua")
    os.makedirs(os.path.join(tmp, "ledger"))
    check(bool(api), "stub API is up")
    rc, out = hz(env, "alerts-test")
    tf = os.path.join(tmp, "conf", "ntfy_topic")
    topic = open(tf).read().strip() if os.path.exists(tf) else ""
    check(rc == 0 and topic.startswith("botlatro-") and len(topic) >= 30 and oct(os.stat(tf).st_mode)[-3:] == "600", "alerts-test makes a long secret topic, saved 0600")
    check(len(ntfy_log) == 1 and ntfy_log[0]["topic"] == topic and "alerts work" in ntfy_log[0]["title"], "alerts-test posts a test message to the topic")
    rc, out = hz(env, "alerts-test")
    check(rc == 0 and open(tf).read().strip() == topic and len(ntfy_log) == 2, "alerts-test keeps the same topic the second time")

    rc, out = hz(env, "plan")
    check(rc == 0 and "0.5182" in out, "plan: cpx62 + ccx33 for 1 h costs 0.5182 EUR incl. IPv4")
    rc, out = hz(env, "plan", "--types", "ccx63:4", "--hours", "1")
    check(rc == 1 and "core limits" in out, "plan refuses types over the account core limits")
    rc, out = hz(env, "plan", "--types", "cx23", "--hours", "0.17")
    check(rc == 0 and "0.0115" in out, "plan: 10 min on cx23 bills one hour, 0.0115 EUR")

    rc, out = hz(env, "up", "--dry-run", "--hours", "2")
    ci = open(os.path.join(tmp, "conf", "dryrun-cloud-init.yaml")).read()
    check(rc == 0 and "DRY RUN: POST /servers" in out and not stub_servers(api), "up --dry-run sends nothing")
    check("test-token" not in out and "test-token" not in ci and "<token redacted>" in ci, "dry run never prints the token")
    check(len(ci) < 32000, "cloud-init fits the 32 KiB user_data limit (%d bytes)" % len(ci))
    node_json = None
    lines = ci.split("\n")
    for i, ln in enumerate(lines):
        if ln.strip() == "- path: /etc/botsim/node.json":
            node_json = json.loads(base64.b64decode(lines[i + 4].split("content: ")[1]))
    check(node_json and node_json.get("ntfy_topic") == topic and node_json.get("ntfy_url") == ntfy, "up passes the ntfy topic to the head box")

    led = {"cap_eur": 100.0, "credit_eur": 25.0, "servers": [], "adjustments": [{"date": "test", "note": "test", "eur": 99.8}]}
    json.dump(led, open(env["BOTSIM_LEDGER"], "w"))
    rc, out = hz(env, "up", "--yes", "--hours", "1")
    check(rc == 1 and "over the 100.00 EUR cap" in out and not stub_servers(api), "up refuses when spent + plan passes the cap")
    os.remove(env["BOTSIM_LEDGER"])
    rc, out = hz(env, "up", "--yes", "--hours", "1", "--spend-cap", "0.3")
    check(rc == 1 and "over its spend cap" in out and not stub_servers(api), "up refuses a run over its own spend cap")

    rc, out = hz(env, "up", "--hours", "1.5", inp="no\n")
    check(rc == 1 and not stub_servers(api), "up without --yes asks and cancels")
    rc, out = hz(env, "up", "--yes", "--hours", "1.5")
    srv = stub_servers(api)
    check(rc == 0 and len(srv) == 2 and all(s["labels"].get("botsim") == "1" for s in srv), "up creates 2 labeled servers")
    cur = json.load(open(os.path.join(tmp, "conf", "current_run.json")))
    url = open(os.path.join(tmp, "conf", "dashboard_url")).read().strip()
    check(url == cur["dashboard_url"] and len(cur["secret"]) >= 30 and oct(os.stat(os.path.join(tmp, "conf", "dashboard_url")).st_mode)[-3:] == "600",
          "dashboard url saved 0600 with a long secret")
    dl = cur["deadline"] - cur["started"]
    check(abs(dl - 5400) < 2, "deadline for 1.5 h is 90 min after up")
    posts = len([x for x in stub_log(api) if x[0] == "POST"])
    rc, out = hz(env, "up", "--yes", "--hours", "1.5")
    check(rc == 0 and "adopting" in out and len([x for x in stub_log(api) if x[0] == "POST"]) == posts and len(stub_servers(api)) == 2,
          "a second up with the same types adopts the boxes and creates nothing")
    rc, out = hz(env, "up", "--yes", "--types", "cpx62")
    check(rc == 1 and "--adopt" in out and "--replace" in out and len(stub_servers(api)) == 2, "up with other types explains --adopt and --replace and changes nothing")
    led = json.load(open(env["BOTSIM_LEDGER"]))
    check(len(led["servers"]) == 2 and all(e["deleted"] is None for e in led["servers"]), "ledger records both boxes")
    md = open(os.path.join(tmp, "ledger", "SPEND.md")).read()
    check("still running" in md and "0.2509" in md, "SPEND.md lists the running boxes")
    rc, out = hz(env, "list")
    check(rc == 0 and "botsim-" + cur["run"] in out, "list shows the boxes")
    rc, out = hz(env, "deploy", "--dry-run")
    check(rc == 0 and out.count("rsync") >= 4 and "cloud-init status --wait" in out, "deploy --dry-run prints ssh and rsync steps")
    rc, out = hz(env, "deploy", "--for-job", "train", "--dry-run")
    check(rc == 0 and "download.pytorch.org/whl/cpu" in out and "torch==" in out and "python3-venv" in out and out.count("/opt/botsim/venv") >= 2,
          "deploy --for-job train --dry-run installs CPU torch from the PyTorch index")
    rc, out = hz(env, "deploy", "--dry-run")
    check(rc == 0 and "download.pytorch.org" not in out and ".venv/" in out, "plain deploy installs no torch and never copies a local venv")
    rc, out = hz(env, "run", "train", "--dry-run", "--env", "TRAIN_GENS=1")
    check(rc == 0 and "systemctl restart botsim-job" in out, "run train --dry-run prints the job start")
    rc, out = hz(env, "run", "train", "--env", "TRAIN_GENS=1")
    check(rc != 0 and "deploy --for-job train" in out, "run train refuses on boxes that lack what it needs")
    rc, out = hz(env, "run", "fake", "--dry-run", "--env", "BOTSIM_FAKE_MINUTES=5")
    check(rc == 0 and "systemctl restart botsim-job" in out, "run --dry-run prints the job start")
    rc, out = hz(env, "down", "--dry-run")
    check(rc == 0 and len(stub_servers(api)) == 2, "down --dry-run deletes nothing")
    rc, out = hz(env, "down")
    check(rc == 0 and "verified" in out and not stub_servers(api), "down deletes every box and verifies")
    rc, out = hz(env, "down")
    check(rc == 0 and "no botsim servers" in out, "down is idempotent")
    led = json.load(open(env["BOTSIM_LEDGER"]))
    spent = sum(e["price_hourly_gross"] for e in led["servers"])
    check(all(e["deleted"] for e in led["servers"]), "ledger marks both boxes deleted (billed %.4f EUR, one started hour each)" % spent)

    api2 = stub(tmp, "stub2", "--fail-type", "ccx33")
    env2 = dict(env, BOTSIM_API=api2, BOTSIM_CONFIG=os.path.join(tmp, "conf2"))
    rc, out = hz(env2, "up", "--yes")
    check(rc == 1 and "kept botsim-" in out and "retry" in out and len(stub_servers(api2)) == 1 and not any(x[0] == "DELETE" for x in stub_log(api2)),
          "a failed create keeps the paid box and prints the retry command")
    hz(env2, "down")

    box_test(tmp, env, api)
    backup_test(tmp)
    train_test(tmp)
    train_fair_test(tmp)
    import safe_tests
    safe_tests.run(tmp, env, key, check, hz, stub, stub_servers, stub_log, start)
    import hardening_tests
    hardening_tests.run(tmp, env, check, hz, stub, stub_servers, stub_log)


def write_box(root, box, node, run, token):
    etc, home = os.path.join(root, "etc"), os.path.join(root, "home")
    os.makedirs(etc)
    os.makedirs(os.path.join(home, "run"))
    json.dump(box, open(os.path.join(etc, "box.json"), "w"))
    json.dump(node, open(os.path.join(etc, "node.json"), "w"))
    json.dump(run, open(os.path.join(etc, "run.json"), "w"))
    open(os.path.join(etc, "token"), "w").write(token)
    return dict(os.environ, BOTSIM_ETC=etc, BOTSIM_HOME=home, BOTSIM_LOG=os.path.join(root, "watchdog.log"), BOTSIM_REPO=REPO,
                BOTSIM_METADATA="http://127.0.0.1:9", BOTSIM_STOP_TIMEOUT="60")


def train_python():
    venv = os.path.join(REPO, "tools", "botsim", "train", ".venv")
    py = os.path.join(venv, "bin", "python")
    if not os.path.exists(py):
        print("creating %s with CPU torch (once, a few minutes)" % venv, flush=True)
        subprocess.run([PY, "-m", "venv", venv], check=True)
        subprocess.run([py, "-m", "pip", "install", "-q", "torch", "numpy", "--index-url", "https://download.pytorch.org/whl/cpu"], check=True)
    return py


def train_fair_test(tmp):
    py = train_python()
    ip, n = "127.0.0.4", "fbox0"
    port = free_port()
    secret = "fairsecret0123456789abcdefghijklm"
    now = time.time()
    run = {"run": "r-fair", "port": port, "cap": 100.0, "spent_before": 0, "boxes": [
        {"name": n, "ip": ip, "type": "cpx22", "cores": 1, "role": "head", "price_hourly_gross": 0.01, "created": now, "deadline": now + 3000}]}
    node = {"name": n, "run": "r-fair", "role": "head", "secret": secret, "port": port, "deadline": now + 3000, "workers": 2}
    e = write_box(os.path.join(tmp, n), {"name": n}, node, run, "f")
    e.update(BOTSIM_BIND=ip, BOTSIM_DASH_STATE=os.path.join(tmp, n, "dash"), BOTSIM_WORKERS="2", TRAIN_PY=py, TRAIN_GENS="3", TRAIN_GAMES="2",
             TRAIN_PLAYER="fair", TRAIN_FAIR_ARGS="stop_ante=1", TRAIN_FAIR_NET_SIMS="4", TRAIN_FAIR_DECKS="b_red,b_blue",
             TRAIN_WEIGHTS=os.path.join(REPO, "tools", "botsim", "train", "start", "r2_gen_0001.bnnw"),
             TRAIN_STEPS="20", TRAIN_EVAL_PER="1", TRAIN_EVAL_DECKS="b_red", TRAIN_EVAL_STAKES="1", TRAIN_EVAL_SIMS="4", TRAIN_SIMS="4",
             TRAIN_RECORD_GAP="0", BOTSIM_JOB_STOP_TIMEOUT="60")
    home = e["BOTSIM_HOME"]
    start([PY, os.path.join(CLOUD, "dashboard.py"), "--box"], e, os.path.join(tmp, n + "-dash.log"))
    check(wait_http("http://%s:%d/%s/api/state" % (ip, port, secret)), "train fair: dashboard answers")
    job = start(NICE + [PY, os.path.join(CLOUD, "jobrun.py"), "train"], e, os.path.join(tmp, n + "-job.log"))
    hm = os.path.join(home, "run", "metrics.jsonl")

    def lines(**kw):
        out = []
        try:
            for ln in open(hm):
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if all(r.get(k) == v for k, v in kw.items()):
                    out.append(r)
        except OSError:
            pass
        return out

    ok = wait_for(lambda: len({r["gen"] for r in lines(type="gen")}) >= 2, 900)
    gens = sorted({r["gen"] for r in lines(type="gen")})
    check(ok, "train fair: head trained at least two generations on net-guided Fair Seer games %s" % gens)
    games = [g for g in lines(type="game") if g.get("gen") is not None]
    check(games and all("dur" in g and "net_picks" in g and g.get("deck") in ("b_red", "b_blue") for g in games),
          "train fair: game lines come from the fair teacher (%d games)" % len(games))
    os.kill(job.pid, signal.SIGTERM)
    check(wait_for(lambda: job.poll() is not None, 60) and job.returncode == 0, "train fair: clean exit after a stop")


def train_test(tmp):
    py = train_python()
    ips = ["127.0.0.2", "127.0.0.3"]
    names = ["tbox0", "tbox1"]
    port = free_port()
    secret = "trainsecret0123456789abcdefghijkl"
    now = time.time()
    run = {"run": "r-train", "port": port, "cap": 100.0, "spent_before": 0, "boxes": [
        {"name": n, "ip": ip, "type": "cpx22", "cores": 1, "role": "head" if i == 0 else "node", "price_hourly_gross": 0.01, "created": now, "deadline": now + 3000}
        for i, (n, ip) in enumerate(zip(names, ips))]}
    envs, homes = [], []
    for i, (n, ip) in enumerate(zip(names, ips)):
        node = {"name": n, "run": "r-train", "role": run["boxes"][i]["role"], "secret": secret, "port": port, "deadline": now + 3000, "workers": 1}
        e = write_box(os.path.join(tmp, n), {"name": n}, node, run, "t")
        e.update(BOTSIM_BIND=ip, BOTSIM_DASH_STATE=os.path.join(tmp, n, "dash"), BOTSIM_WORKERS="1", TRAIN_PY=py, TRAIN_GENS="6", TRAIN_GAMES="10",
                 TRAIN_TEACHER_GAMES="10", TRAIN_TEACHER_STEPS="40", TRAIN_STEPS="40", TRAIN_EVAL_PER="1", TRAIN_EVAL_DECKS="b_red,b_blue,b_yellow,b_black", TRAIN_EVAL_STAKES="1,3", TRAIN_EVAL_SIMS="8", TRAIN_SIMS="8",
                 TRAIN_RUNS_PER_FILE="2", TRAIN_RECORD_GAP="0", BOTSIM_JOB_STOP_TIMEOUT="60")
        envs.append(e)
        homes.append(e["BOTSIM_HOME"])
        start([PY, os.path.join(CLOUD, "dashboard.py"), "--box"], e, os.path.join(tmp, n + "-dash.log"))
    url = "http://%s:%d/%s/" % (ips[0], port, secret)
    check(wait_http(url + "api/state") and wait_http("http://%s:%d/%s/api/state" % (ips[1], port, secret)), "train: both dashboards answer")
    jobs = [start(NICE + [PY, os.path.join(CLOUD, "jobrun.py"), "train"], e, os.path.join(tmp, n + "-job.log")) for n, e in zip(names, envs)]
    hm, nm = (os.path.join(h, "run", "metrics.jsonl") for h in (homes[0], homes[1]))

    def lines(path, **kw):
        out = []
        try:
            for ln in open(path):
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if all(r.get(k) == v for k, v in kw.items()):
                    out.append(r)
        except OSError:
            pass
        return out

    ok = wait_for(lambda: len({r["gen"] for r in lines(hm, type="gen")}) >= 3, 420)
    gens = sorted({r["gen"] for r in lines(hm, type="gen")})
    check(ok and gens[:3] == [0, 1, 2], "train: head trained generation 0 on teacher records and at least two more generations %s" % gens)
    g0 = lines(hm, type="gen", gen=0)[0]
    check(all(k in g0 for k in ("loss", "loss_policy", "loss_value", "loss_ante", "lr", "samples", "buffer", "train_s", "steps", "val_policy", "val_win_pred", "epochs")), "train: gen lines carry losses, held-out losses, calibration, lr, samples and buffer")
    batches = os.path.join(homes[0], "work", "batches")
    files = [f for d in os.listdir(batches) for f in os.listdir(os.path.join(batches, d))] if os.path.isdir(batches) else []
    check(any(f.startswith(names[0] + "_") for f in files) and any(f.startswith(names[1] + "_") for f in files),
          "train: records from both boxes reached the head (%d files)" % len(files))
    node_in = os.path.join(homes[1], "xfer", "in")
    check(os.path.isdir(node_in) and any(f.startswith("gen_000") and f.endswith(".bnnw") for f in os.listdir(node_in)), "train: weights reached the node over the node API")
    check(wait_for(lambda: any(r.get("gen") == 1 for r in lines(nm, type="game")), 120), "train: the node plays self-play games with the pushed generation")
    check(len(lines(nm, type="game")) > 0 and len(lines(hm, type="game")) > 0 and len(lines(hm, type="progress")) > 0 and len(lines(nm, type="progress")) > 0,
          "train: game and progress lines from both boxes")
    check(len(lines(hm, type="checkpoint")) >= 3 and os.path.exists(os.path.join(homes[0], "run", "checkpoints", "gen_0002.bnnw")), "train: checkpoint lines and files per generation")
    check(len(lines(hm, type="bench")) >= 1 and len(lines(hm, type="record")) + len(lines(nm, type="record")) >= 1, "train: bench and record lines")
    big = [f for dp, dn, fn in os.walk(os.path.join(homes[0], "run")) for f in fn if os.path.getsize(os.path.join(dp, f)) > 50 << 20]
    check(not big, "train: nothing in the run dir is over 50 MB")
    wait_for(lambda: {r["gen"] for r in lines(hm, type="eval", who="gen")} >= {0, 1, 2}, 90)
    ev = lines(hm, type="eval")
    check({r["who"] for r in ev} >= {"gen", "rules"} and {r["gen"] for r in ev if r["who"] == "gen"} >= {0, 1, 2} and all(r["set"] == "fixed-8" for r in ev),
          "train: eval lines for the generations and the greedy reference on the fixed set")

    def view():
        return json.loads(get(url + "api/view"))["view"]["panels"]

    check(wait_for(lambda: len((view().get("eval") or {}).get("gens", [])) >= 2, 60), "train: dashboard shows strength vs references")
    pn = view()
    check({r["who"] for r in pn["eval"]["refs"]} == {"rules"} and len(pn["train"]) >= 2 and pn["tiles"]["games"] > 0, "train: dashboard has references, training curves and games")
    st = json.loads(get(url + "api/state"))
    check(len([b for b in st["boxes"] if b["games"] > 0]) == 2, "train: dashboard counts games from both boxes")
    os.kill(jobs[0].pid, signal.SIGTERM)
    os.kill(jobs[1].pid, signal.SIGTERM)
    check(wait_for(lambda: jobs[0].poll() is not None and jobs[1].poll() is not None, 60), "train: both jobs exit after a stop")
    check(jobs[0].returncode == 0 and jobs[1].returncode == 0, "train: clean exit codes")
    saved = lines(hm, type="state", state="saved")
    ck = os.listdir(os.path.join(homes[0], "run", "checkpoints"))
    check(len(saved) == 1 and "latest.bnnw" in ck and sum(f.startswith("gen_") for f in ck) >= 3, "train: stop saves the latest checkpoint and a saved state (%s)" % sorted(ck))
    rounds = os.path.join(homes[1], "work", "rounds")
    check(bool(lines(nm, type="state", state="saved")) and not (os.path.isdir(rounds) and os.listdir(rounds)), "train: the node saved and leaves no half finished round behind")
    left = subprocess.run(["pgrep", "-f", "(luajit|selfplay_pool).*" + tmp], capture_output=True, text=True).stdout.split()
    check(not left, "train: no worker processes left %s" % left)


def backup_test(tmp):
    bare = os.path.join(tmp, "results.git")
    seed = os.path.join(tmp, "results-seed")
    g = ["git", "-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare], check=True)
    subprocess.run(["git", "clone", "-q", bare, seed], check=True, capture_output=True)
    open(os.path.join(seed, "README.md"), "w").write("results\n")
    subprocess.run(g + ["-C", seed, "add", "."], check=True)
    subprocess.run(g + ["-C", seed, "commit", "-qm", "init"], check=True)
    subprocess.run(["git", "-C", seed, "push", "-q", "origin", "HEAD:main"], check=True, capture_output=True)
    box = {"name": "bk-0", "run": "r-backup", "role": "head", "deadline": time.time() + 3000, "results_remote": bare}
    e = write_box(os.path.join(tmp, "bk"), box, {}, {"run": "r-backup"}, "test-token")
    e.update(BOTSIM_BACKUP_DIR=os.path.join(tmp, "bk", "repo"), BOTSIM_BACKUP_MAX_BYTES="1000")
    run = os.path.join(e["BOTSIM_HOME"], "run")
    os.makedirs(os.path.join(run, "gens"))
    open(os.path.join(run, "gens", "g1.json"), "w").write("{}")
    open(os.path.join(run, "job.pid"), "w").write("1")
    open(os.path.join(run, "STOP"), "w").close()
    open(os.path.join(run, "big.bin"), "wb").write(b"x" * 2000)

    def files():
        r = subprocess.run(["git", "--git-dir", bare, "ls-tree", "-r", "--name-only", "main"], capture_output=True, text=True)
        return set(r.stdout.split())

    def commits():
        return int(subprocess.run(["git", "--git-dir", bare, "rev-list", "--count", "main"], capture_output=True, text=True).stdout)

    r = subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "backup"], env=e, capture_output=True, text=True, timeout=60)
    f = files()
    check(r.returncode == 0 and {"runs/r-backup/gens/g1.json", "runs/r-backup/run.json", "README.md"} <= f, "backup pushes the run folder to the results repo %s %s" % (sorted(f), r.stderr[-300:]))
    check(not any(x.endswith(("job.pid", "STOP", "big.bin")) for x in f), "backup skips job.pid, STOP files and files over the size limit")
    n = commits()
    subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "backup"], env=e, capture_output=True, text=True, timeout=60)
    check(commits() == n, "backup with no changes makes no commit")
    subprocess.run(["git", "-C", seed, "pull", "-q", "origin", "main"], check=True, capture_output=True)
    open(os.path.join(seed, "other.txt"), "w").write("x")
    subprocess.run(g + ["-C", seed, "add", "."], check=True)
    subprocess.run(g + ["-C", seed, "commit", "-qm", "other run"], check=True)
    subprocess.run(["git", "-C", seed, "push", "-q", "origin", "HEAD:main"], check=True, capture_output=True)
    open(os.path.join(run, "gens", "g2.json"), "w").write("{}")
    r = subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "backup"], env=e, capture_output=True, text=True, timeout=60)
    f = files()
    check(r.returncode == 0 and {"runs/r-backup/gens/g2.json", "other.txt"} <= f, "backup keeps other runs' pushes and adds new files %s" % r.stderr[-300:])
    box["role"] = "node"
    json.dump(box, open(os.path.join(e["BOTSIM_ETC"], "box.json"), "w"))
    open(os.path.join(run, "gens", "g3.json"), "w").write("{}")
    subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "backup"], env=e, capture_output=True, text=True, timeout=60)
    check("runs/r-backup/gens/g3.json" not in files(), "only the head box backs up")


def box_test(tmp, env, api):
    rc, out = hz(env, "up", "--yes", "--hours", "1")
    cur = json.load(open(os.path.join(tmp, "conf", "current_run.json")))
    port, secret = cur["port"], cur["secret"]
    now = time.time()
    boxes = [{k: b.get(k) for k in ("name", "id", "ip", "type", "cores", "role", "price_hourly_gross", "created", "deadline")} for b in cur["boxes"]]
    run = {"run": cur["run"], "port": port, "cap": 100.0, "run_cap": cur["run_cap"], "spent_before": 1.25, "boxes": boxes}
    envs = []
    for b in boxes:
        box = {"name": b["name"], "run": cur["run"], "role": b["role"], "deadline": now + 3000, "save_lead": 300,
               "price_hourly_gross": b["price_hourly_gross"], "created_hint": now, "secret": secret, "port": port, "api": api}
        node = {"name": b["name"], "run": cur["run"], "role": b["role"], "secret": secret, "port": port, "deadline": now + 3000, "workers": 1}
        if b["role"] == "head":
            node.update(ntfy_topic="test-topic-123", ntfy_url=env["BOTSIM_NTFY_URL"])
        e = write_box(os.path.join(tmp, b["name"]), box, node, run, "test-token")
        e["BOTSIM_BIND"] = b["ip"]
        e["BOTSIM_DASH_STATE"] = os.path.join(tmp, b["name"], "dash")
        e["BOTSIM_ALERT_EVERY"] = "1"
        envs.append(e)
        start([PY, os.path.join(CLOUD, "dashboard.py"), "--box"], e, os.path.join(tmp, b["name"] + "-dash.log"))
    for b, e in zip(boxes, envs):
        je = dict(e, BOTSIM_FAKE_MINUTES="0.6", BOTSIM_FAKE_REPORT="2", BOTSIM_WORKERS="1", BOTSIM_FAKE_BENCH_N="20",
                  BOTSIM_FAKE_GEN_SECONDS="4", BOTSIM_FAKE_RECORD_EVERY="15")
        if b["role"] != "head":
            je.update(BOTSIM_FAKE_BENCH="0", BOTSIM_FAKE_RATE="4")
        start(NICE + [PY, os.path.join(CLOUD, "jobrun.py"), "fake"], je, os.path.join(tmp, b["name"] + "-job.log"))
    head_url = "http://%s:%d/%s/" % (boxes[0]["ip"], port, secret)
    check(wait_http(head_url + "api/state"), "head dashboard answers on its secret path")
    try:
        get("http://%s:%d/wrong/api/state" % (boxes[0]["ip"], port))
        check(False, "wrong secret gets 404")
    except urllib.error.HTTPError as e:
        check(e.code == 404, "wrong secret gets 404")
    page = get(head_url).decode()
    check("Emergency stop" in page and "api/view" in page and "Watch a game" in page, "page serves")
    time.sleep(16)
    st = json.loads(get(head_url + "api/state"))
    check(st["games"] > 0 and len([b for b in st["boxes"] if b["games"] > 0]) == 2, "head sees games from both boxes (%s games, %.1f/s)" % (st["games"], st["gps"]))
    check(st["bench"] is not None and st["demo"] is True, "bench result present, demo flag set by the fake job")
    vw = json.loads(get(head_url + "api/view"))
    pn = vw["view"]["panels"]
    check(pn["tiles"]["games"] > 0 and pn["win_gen"] and pn["heat"]["all"] and pn["ante"], "view: tiles, win rate, heatmap and ante distribution have data (%d games)" % pn["tiles"]["games"])
    ev = pn["eval"] or {}
    check({r["who"] for r in ev.get("refs", [])} == {"rules", "seer"} and len(ev.get("gens", [])) >= 2 and all(g["lo"] <= g["rate"] <= g["hi"] for g in ev["gens"]),
          "view: strength vs rules bot and Seer with intervals, %d generations" % len(ev.get("gens", [])))
    check(len(pn["train"]) >= 2 and all("loss_policy" in g and "lr" in g for g in pn["train"][1:]), "view: training curves with losses and learning rate")
    check(pn["death"]["total"] > 0 and pn["jokers"]["top"] and pn["econ"].get("lost"), "view: death causes, final jokers, economy")
    check(len(pn["throughput"]["boxes"]) == 2 and any(q[2] for q in pn["throughput"]["total"] if q[2] is not None), "view: throughput for both boxes with decisions/s")
    names = {b["name"] for b in st["boxes"]}
    check(os.path.getsize(os.path.join(tmp, boxes[0]["name"], "dash", cur["run"], "mirror", boxes[1]["name"] + ".jsonl")) > 0, "head mirrors the node's metrics file")
    recs = json.loads(get(head_url + "api/records"))
    rid = recs["records"][0]["id"] if recs["records"] else ""
    rec = json.loads(get(head_url + "api/record?id=" + urllib.parse.quote(rid))) if rid else {}
    mv = (rec.get("moves") or [{}])[0]
    check(recs["total"] > 0 and len(rec.get("moves", [])) > 3 and "top" in mv and "act" in mv, "watch: recorded game list and full move list (%d records)" % recs["total"])
    try:
        get(head_url + "api/record?id=nope")
        check(False, "unknown record gets 404")
    except urllib.error.HTTPError as e:
        check(e.code == 404, "unknown record gets 404")
    lost = json.loads(get(head_url + "api/records?r=lost&s=1"))["records"]
    check(all(not m["won"] and m["stake"] == 1 for m in lost), "watch list follows the filters (%d lost White stake)" % len(lost))
    check(wait_for(lambda: any("started" in (t or "") for t in titles()) and any("New best" in (t or "") for t in titles())),
          "alerts: run started and new best generation sent to ntfy")
    check(all(m["topic"] == "test-topic-123" for m in ntfy_log[2:]) and all("[demo]" in (m["title"] or "") for m in ntfy_log[2:]), "alerts go to the box topic and say demo %s" % [(m["topic"], m["title"]) for m in ntfy_log[2:] if m["topic"] != "test-topic-123" or "[demo]" not in (m["title"] or "")])
    check(st["money"]["spent"] > 1.25 and st["money"]["run_spent"] > 0.5, "money: spent before + started hours x price (%.4f)" % st["money"]["spent"])
    check(st["can_stop"] is True, "head offers Stop")
    json.dump(st, open(os.path.join(tmp, "state-live.json"), "w"))
    get(head_url + "api/stop", data=b"stop")
    head_home = envs[0]["BOTSIM_HOME"]
    check(os.path.exists(os.path.join(head_home, "run", "STOP_REQUEST")), "Stop writes the stop request for the root unit")
    check(wait_for(lambda: any("Stop pressed" in (t or "") for t in titles())), "alerts: Stop pressed sent")
    r = subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "stop"], env=envs[0], capture_output=True, text=True, timeout=200)
    ctl = json.load(open(os.path.join(head_home, "control.json")))
    check(ctl.get("state") == "stopped" and ctl["results"].get(boxes[1]["name"]) == "ok", "stop routine: stopped, node results ok")
    check(os.path.exists(os.path.join(head_home, "run", "boxes", boxes[1]["name"], "metrics.jsonl")), "node metrics collected on the head")
    ck = os.listdir(os.path.join(head_home, "run", "checkpoints"))
    check(any(f.startswith("gen_") for f in ck), "head job saved a checkpoint (%d files)" % len(ck))
    names = [s["name"] for s in stub_servers(api)]
    check(boxes[1]["name"] not in names and boxes[0]["name"] in names, "node deleted, head kept for pull")
    check(now + 500 < ctl["keep_until"] <= now + 3000, "head keep_until is inside the paid window")
    st = json.loads(get(head_url + "api/state"))
    check(st["control"]["state"] == "stopped" and boxes[1]["name"] in st["control"]["deleted"], "dashboard shows stopped")
    check(wait_for(lambda: any("finished" in (t or "") for t in titles())), "alerts: run finished sent")
    n_before = len(ntfy_log)
    time.sleep(3)
    check(len(ntfy_log) == n_before and len(titles()[2:]) == len(set(titles()[2:])), "alerts are sent once each %s" % titles()[2:])
    res = os.path.join(tmp, "results", cur["run"])
    shutil.copytree(os.path.join(head_home, "run", "boxes"), res)
    shutil.copytree(os.path.join(head_home, "run"), os.path.join(res, boxes[0]["name"]), ignore=shutil.ignore_patterns("boxes"))
    json.dump(run, open(os.path.join(res, "run.json"), "w"))
    r = subprocess.run([PY, os.path.join(CLOUD, "dashboard.py"), "--local", res, "--dump"], env=env, capture_output=True, text=True)
    lst = json.loads(r.stdout)
    check(lst["mode"] == "local" and lst["games"] > 0 and len(lst["boxes"]) == 2 and lst["can_stop"] is False, "local dashboard reads pulled results")
    aggregation_checks(res, env)
    shutil.copytree(res, os.path.join(tmp, "keep-results"))
    c = json.load(open(os.path.join(head_home, "control.json")))
    c["keep_until"] = time.time() - 1
    json.dump(c, open(os.path.join(head_home, "control.json"), "w"))
    subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "tick"], env=envs[0], capture_output=True, text=True, timeout=60)
    check(not stub_servers(api), "head watchdog deletes itself after keep_until")
    rc, out = hz(env, "up", "--yes", "--types", "cx23", "--hours", "1")
    cur = json.load(open(os.path.join(tmp, "conf", "current_run.json")))
    b = cur["boxes"][0]
    box = {"name": b["name"], "run": cur["run"], "role": "head", "deadline": time.time() + 200, "save_lead": 300, "price_hourly_gross": 0.01152,
           "secret": "x", "port": 1, "api": api}
    e = write_box(os.path.join(tmp, "dl"), box, {}, {}, "test-token")
    subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "tick"], env=e, capture_output=True, text=True, timeout=60)
    check(open(os.path.join(e["BOTSIM_HOME"], "run", "STOP_REQUEST")).read() == "deadline" and stub_servers(api), "watchdog asks for a save before the deadline")
    box["deadline"] = time.time() - 1
    json.dump(box, open(os.path.join(e["BOTSIM_ETC"], "box.json"), "w"))
    subprocess.run([PY, os.path.join(CLOUD, "boxctl.py"), "tick"], env=e, capture_output=True, text=True, timeout=60)
    check(not stub_servers(api), "watchdog deletes its own server at the deadline")
    rc, out = hz(env, "down")
    check(rc == 0, "down after self-deletes syncs the ledger")
    led = json.load(open(env["BOTSIM_LEDGER"]))
    check(all(e["deleted"] for e in led["servers"]) and any(e.get("deleted_estimated") for e in led["servers"]), "ledger estimates the end of self-deleted boxes")
    if os.environ.get("KEEP_RESULTS"):
        shutil.copytree(os.path.join(tmp, "keep-results"), os.environ["KEEP_RESULTS"], dirs_exist_ok=True)
        shutil.copy(os.path.join(tmp, "state-live.json"), os.environ["KEEP_RESULTS"])


def dump_view(res, env, query):
    r = subprocess.run([PY, os.path.join(CLOUD, "dashboard.py"), "--local", res, "--dump-view", query], env=env, capture_output=True, text=True)
    return json.loads(r.stdout)["panels"]


def aggregation_checks(res, env):
    games = []
    evals = []
    for f in sorted(os.listdir(res)):
        p = os.path.join(res, f, "metrics.jsonl")
        if os.path.exists(p):
            for line in open(p):
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("type") == "game":
                    games.append(r)
                elif r.get("type") == "eval":
                    evals.append(r)
    cases = [("", lambda g: True), ("d=b_red,b_blue&s=1,2", lambda g: g["deck"] in ("b_red", "b_blue") and g["stake"] in (1, 2)),
             ("r=won", lambda g: g["won"]), ("r=lost&a=2-4", lambda g: not g["won"] and 2 <= g["ante"] <= 4),
             ("g=1-2", lambda g: 1 <= g["gen"] <= 2), ("c=none", lambda g: not g.get("chal"))]
    for q, fn in cases:
        sel = [g for g in games if fn(g)]
        pn = dump_view(res, env, q)
        t = pn["tiles"]
        wins = sum(1 for g in sel if g["won"])
        ok = t["games"] == len(sel) and t["wins"] == wins
        if sel:
            ok = ok and abs(t["ante"] - sum(g["ante"] for g in sel) / len(sel)) < 1e-3
            ok = ok and sum(v[1] + v[2] for v in [[a, l, w] for a, l, w in pn["ante"]]) == len(sel)
            ok = ok and sum(d["n"] for d in pn["death"]["top"]) <= pn["death"]["total"] == (0 if q == "r=won" else len(sel) - wins)
        check(ok, "aggregation matches the raw game lines for filter %r (%d games, %d wins)" % (q or "none", len(sel), wins))
    pn = dump_view(res, env, "s=1")
    rules = [e for e in evals if e["who"] == "rules" and e["stake"] == 1]
    ref = next((r for r in pn["eval"]["refs"] if r["who"] == "rules"), None)
    check(ref is not None and ref["n"] == sum(e["n"] for e in rules) and ref["wins"] == sum(e["wins"] for e in rules), "eval totals match for the rules bot at White stake")
    j = {}
    lost = [g for g in games if not g["won"]]
    for g in lost:
        for k in set(g["jokers"]):
            j[k] = j.get(k, 0) + 1
    top = dump_view(res, env, "r=lost")["jokers"]["top"]
    check(top and all(abs(r[2] - j.get(r[0], 0) / len(lost)) < 1e-3 for r in top), "final joker shares match the raw lines")
    sys.path.insert(0, CLOUD)
    import alerts
    sent = []
    st_path = os.path.join(os.path.dirname(res), "alerts-unit.json")
    al = alerts.Alerter("http://x", "t", st_path, sender=lambda *a, **k: sent.append(a[2]) or True)
    now = time.time()
    snap = {"run": "r1", "now": now, "deadline": now + 300, "games": 0, "job_states": {"a": "running"}, "money": {"spent": 81, "cap": 100}, "boxes": [1]}
    got = al.check(snap)
    check(got == ["start", "deadline", "cap80"], "alert rules: start, deletion soon, 80%% of the cap (%s)" % got)
    snap["money"]["spent"] = 96
    got = al.check(snap)
    al2 = alerts.Alerter("http://x", "t", st_path, sender=lambda *a, **k: sent.append(a[2]) or True)
    check(got == ["cap95"] and al2.check(snap) == [], "95% alert once, nothing resent after a dashboard restart")
    failing = alerts.Alerter("http://x", "t", st_path + "2", sender=lambda *a, **k: False)
    check(failing.check(snap) == [] and not failing.sent, "a failed send is retried later, not marked sent")
    slow = alerts.Alerter("http://x", "t", st_path + "3", sender=lambda *a, **k: True)
    base = {"run": "r2", "phase": "teacher games", "job_states": {"a": "running"}, "money": {"spent": 1, "cap": 100}, "boxes": [1]}
    stalls = []
    for i in range(6):
        stalls += [k for k in slow.check(dict(base, now=now + 900 * i, games=40 * i)) if k == "stall"]
    for i in range(6, 9):
        stalls += [k for k in slow.check(dict(base, now=now + 900 * i, games=200)) if k == "stall"]
    check(stalls == ["stall"], "stuck alert waits while games still go up under one phase, fires once they stop (%s)" % stalls)


if __name__ == "__main__":
    main()
