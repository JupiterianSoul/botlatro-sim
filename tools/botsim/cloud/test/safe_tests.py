import getpass
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CLOUD = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(CLOUD, "..", "..", ".."))
PY = sys.executable
NICE = ["nice", "-n", "19", "taskset", "-c", "0-3"]
sys.path.insert(0, CLOUD)

USED = {
    "server": ["id", "name", "status", "created", "labels", "server_type.name", "server_type.cores", "server_type.prices.location",
               "server_type.prices.price_hourly.gross", "location.name", "public_net.ipv4.ip"],
    "server_types": ["server_types.name", "server_types.cores", "server_types.cpu_type", "server_types.memory", "server_types.deprecated",
                     "server_types.deprecation", "server_types.prices.location", "server_types.prices.price_hourly.gross",
                     "server_types.locations.name", "server_types.locations.available", "server_types.locations.deprecation"],
    "pricing": ["pricing.vat_rate", "pricing.currency", "pricing.primary_ips.type", "pricing.primary_ips.prices.location",
                "pricing.primary_ips.prices.price_hourly.gross"],
    "ssh_keys": ["ssh_keys.name", "ssh_keys.public_key", "ssh_keys.fingerprint"],
    "servers_list": ["servers", "meta.pagination.next_page"],
}


def walk(obj, path):
    head, _, rest = path.partition(".")
    if isinstance(obj, list):
        return all(walk(x, path) for x in obj) if obj else True
    if not isinstance(obj, dict) or head not in obj:
        return False
    return walk(obj[head], rest) if rest else True


def shape(v):
    if isinstance(v, dict):
        return {k: shape(x) for k, x in v.items()}
    if isinstance(v, list):
        return [shape(v[0])] if v else []
    return "null" if v is None else type(v).__name__


def get(url, timeout=10):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": "Bearer test-token"}), timeout=timeout) as r:
        return json.loads(r.read())


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def state(env):
    try:
        return json.load(open(os.path.join(env["BOTSIM_CONFIG"], "current_run.json")))
    except FileNotFoundError:
        return None


def ssh_calls(env):
    try:
        return [json.loads(l) for l in open(env["FAKE_SSH_LOG"])]
    except FileNotFoundError:
        return []


def reset_ssh(env, plan=None):
    d = os.path.dirname(env["FAKE_SSH_LOG"])
    for f in os.listdir(d):
        if f.startswith("count-") or f.startswith("job-"):
            os.remove(os.path.join(d, f))
    for f in (env["FAKE_SSH_LOG"], env["FAKE_RSYNC_LOG"]):
        if os.path.exists(f):
            os.remove(f)
    json.dump(plan or {}, open(env["FAKE_SSH_PLAN"], "w"))


def run(tmp, env, key, check, hz, stub, stub_servers, stub_log, start):
    contract(tmp, env, check, stub)
    jobs_exec(check)
    tarball_check(tmp, check)
    yaml_check(check)
    doctor_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    interrupt_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    signal_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    adopt_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    deploy_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    pull_tests(tmp, env, check, hz, stub, stub_servers)
    flow_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    sshd_tests(tmp, key, check, start)


def contract(tmp, env, check, stub):
    import hz
    fx = json.load(open(os.path.join(HERE, "fixtures", "hetzner_real.json")))
    for part, paths in USED.items():
        missing = [p for p in paths if not walk(fx[part], p)]
        check(not missing, "contract: recorded real %s has every field the code reads%s" % (part, (" (missing %s)" % missing) if missing else ""))
    srv = fx["server"]
    check("datacenter" not in srv and hz.server_loc(srv) == "fsn1" and abs(hz.price_of_server(srv) - 0.01152) < 1e-9,
          "contract: server location and price read from the real shape")
    api = env["BOTSIM_API"]
    fake = {"server_types": get(api + "/server_types"), "pricing": get(api + "/pricing"), "ssh_keys": get(api + "/ssh_keys"),
            "servers_list": get(api + "/servers?label_selector=botsim%3D1")}
    for part in ("server_types", "pricing", "ssh_keys", "servers_list"):
        missing = [p for p in USED[part] if not walk(fake[part], p)]
        check(not missing, "contract: fake %s has the same fields%s" % (part, (" (missing %s)" % missing) if missing else ""))
    api3 = stub(tmp, "contract")
    body = json.dumps({"name": "botsim-rx-0", "server_type": "cpx22", "location": "fsn1", "labels": {}}).encode()
    req = urllib.request.Request(api3 + "/servers", data=body, method="POST", headers={"Authorization": "Bearer test-token", "Content-Type": "application/json"})
    created = json.loads(urllib.request.urlopen(req).read())["server"]
    listed = get(api3 + "/servers")["servers"][0]
    real_shape = shape(srv)
    for s, what in ((created, "create"), (listed, "list")):
        s = {k: v for k, v in s.items() if k != "user_data_len"}
        check(set(s) == set(srv) and shape(s)["public_net"] == real_shape["public_net"] and shape(s)["location"] == real_shape["location"],
              "contract: fake server from %s has exactly the real top-level fields, no datacenter" % what)
    try:
        get(api3.replace("/v1", "/v1/datacenters"))
        check(False, "contract: /datacenters is gone (410) like the real API")
    except urllib.error.HTTPError as e:
        check(e.code == 410, "contract: /datacenters is gone (410) like the real API")


def tarball_check(tmp, check):
    import io
    import tarfile
    import hz
    for relver, want in (("1791988261", True), ("1700000000", False)):
        path = os.path.join(tmp, "lj-%s.tar.gz" % relver)
        with tarfile.open(path, "w:gz") as t:
            data = (relver + "\n").encode()
            info = tarfile.TarInfo("LuaJIT-x/.relver")
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
        check(hz.tarball_ok(path) is want, "LuaJIT source with release %s is %s" % (relver, "accepted" if want else "rejected"))


def yaml_check(check):
    py = "/usr/bin/python3"
    code = ("import sys, yaml; sys.path.insert(0, %r); import hz, safety; priv, pub = safety.gen_host_key(); "
            "d = yaml.safe_load(hz.cloud_init({'name': 'x'}, {'name': 'x'}, 'tok', (priv, pub))); "
            "print(d['ssh_keys']['ed25519_private'] == priv and d['ssh_keys']['ed25519_public'].split()[:2] == pub.split() and d['ssh_deletekeys'] is True)") % CLOUD
    if not os.path.exists(py) or subprocess.run([py, "-c", "import yaml"], capture_output=True).returncode != 0:
        print("skip  no PyYAML, cloud-init YAML parse check skipped")
        return
    r = subprocess.run([py, "-c", code], capture_output=True, text=True)
    check(r.stdout.strip() == "True", "cloud-init parses as YAML and carries the exact host key")


def jobs_exec(check):
    r = subprocess.run(["git", "ls-files", "-s", "--", "tools/botsim/cloud/jobs"], cwd=REPO, capture_output=True, text=True)
    runs = [l for l in r.stdout.splitlines() if l.endswith("/run")]
    check(runs and all(l.startswith("100755") for l in runs), "every jobs/*/run is 100755 in git (%d jobs)" % len(runs))


def doctor_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    rc, out = hz(env, "doctor", "--types", "cpx22,ccx13")
    check(rc == 0 and "all good" in out and "matches" in out and "job scripts are executable" in out and "plan fits" in out, "doctor passes on a clean account")
    api = stub(tmp, "doctor-unavail")
    e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-doc"), BOTSIM_LEDGER=os.path.join(tmp, "ledger-doc", "spend.json"))
    os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
    rc, out = hz(e, "doctor", "--types", "cx23")
    check(rc == 1 and "cx23 is not available" in out and "cheapest available shared type: cpx22" in out, "doctor refuses a sold out type and names the cheapest one")
    rc, out = hz(e, "smoke", "--yes")
    check(rc == 1 and "nothing was created" in out and not stub_servers(api), "smoke refuses before creating anything when cx23 is sold out")
    other = os.path.join(tmp, "other_key")
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other], check=True)
    rc, out = hz(dict(e, BOTSIM_SSH_KEY=other), "doctor")
    check(rc == 1 and "is not the local key" in out, "doctor catches an account ssh key that differs from the local one")
    rc, out = hz(dict(e, BOTSIM_TOKEN_FILE=os.path.join(tmp, "nope")), "doctor")
    check(rc == 1 and "token" in out, "doctor reports a missing token")
    body = json.dumps({"name": "botsim-r1-0", "server_type": "cpx22", "location": "fsn1", "labels": {"botsim": "1", "botsim-run": "r1", "botsim-deadline": str(int(time.time() + 1800))}}).encode()
    urllib.request.urlopen(urllib.request.Request(api + "/servers", data=body, method="POST", headers={"Authorization": "Bearer test-token", "Content-Type": "application/json"}))
    rc, out = hz(e, "doctor")
    check(rc == 1 and "not in the ledger" in out, "doctor reports a server the ledger does not know")
    rc, out = hz(e, "up", "--yes", "--types", "cpx22")
    check(rc == 1 and "REFUSED" in out and len(stub_servers(api)) == 1, "up refuses on a doctor problem")
    hz(e, "list")
    rc, out = hz(e, "doctor")
    check(rc == 1 and "stray server" in out, "doctor reports a stray server of another run")
    hz(e, "down")


def interrupt_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    api = stub(tmp, "intr")
    e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-intr"), BOTSIM_LEDGER=os.path.join(tmp, "ledger-intr", "spend.json"))
    os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
    for hook in ("up:before_create:0", "up:after_create:0", "up:before_create:1", "up:after_create:1"):
        n0 = len(stub_log(api))
        rc, out = hz(dict(e, BOTSIM_TEST_INTERRUPT=hook), "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9")
        st = state(e)
        live = sorted(s["name"] for s in stub_servers(api))
        led = json.load(open(e["BOTSIM_LEDGER"])) if os.path.exists(e["BOTSIM_LEDGER"]) else {"servers": []}
        in_led = sorted(x["name"] for x in led["servers"] if not x.get("deleted"))
        consistent = st is not None and sorted(b["name"] for b in st["boxes"]) == live == in_led
        check(rc == 130 and "resume:" in out and consistent and not any(x[0] == "DELETE" for x in stub_log(api)[n0:]),
              "SIGINT at %s: exits 130, keeps %d box(es), state and ledger match the API" % (hook, len(live)))
        rc, out = hz(e, "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9")
        live = stub_servers(api)
        st = state(e)
        posts = [x for x in stub_log(api)[n0:] if x[0] == "POST"]
        check(rc == 0 and len(live) == 2 and len(posts) == 2 and not any(x[0] == "DELETE" for x in stub_log(api)[n0:]) and st["phase"] == "created" and len(st["boxes"]) == 2 and st.get("dashboard_url"),
              "after SIGINT at %s the same up resumes: 2 boxes, 2 creates in total, nothing deleted" % hook)
        if hook == "up:after_create:1":
            break
        hz(e, "down")
        reset_stub_log(api)
    reset_ssh(e)
    for hook, skipped in (("deploy:0:synced", 0), ("deploy:0:done", 1), ("deploy:1:ready", 1)):
        rc, out = hz(dict(e, BOTSIM_TEST_INTERRUPT=hook), "deploy")
        rc2, out2 = hz(e, "deploy")
        st = state(e)
        check(rc == 130 and "resume: python3 tools/botsim/cloud/hz.py deploy" in out and rc2 == 0 and out2.count("already done, skipped") == skipped
              and all(b.get("deployed") for b in st["boxes"]), "SIGINT at %s: deploy resumes and skips the %d box(es) already done" % (hook, skipped))
        for b in st["boxes"]:
            b["deployed"] = False
        json.dump(st, open(os.path.join(e["BOTSIM_CONFIG"], "current_run.json"), "w"))
    hz(e, "deploy")
    rc, out = hz(dict(e, BOTSIM_TEST_INTERRUPT="run:0"), "run", "fake")
    rc2, out2 = hz(e, "run", "fake")
    check(rc == 130 and rc2 == 3 and out2.count(": NOT STARTED") == 1 and out2.count("readback ") == 1,
          "SIGINT during run: rerun starts the job only where it is missing and refuses the running one (exit 3)")
    hz(e, "down")


def reset_stub_log(api):
    pass


def signal_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    for force in (False, True):
        api = stub(tmp, "slow%d" % force, "--slow-post", "1.5")
        e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-slow%d" % force), BOTSIM_LEDGER=os.path.join(tmp, "ledger-slow%d" % force, "spend.json"))
        os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
        p = subprocess.Popen([PY, os.path.join(CLOUD, "hz.py"), "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9"], env=e,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        t_end = time.time() + 20
        while time.time() < t_end and not any(x[0] == "POST" for x in stub_log(api)):
            time.sleep(0.05)
        p.send_signal(signal.SIGINT)
        if force:
            time.sleep(0.2)
            p.send_signal(signal.SIGINT)
        out = p.communicate(timeout=60)[0]
        live = stub_servers(api)
        st = state(e)
        if not force:
            check(p.returncode == 130 and len(live) == 1 and len(st["boxes"]) == 1 and st["boxes"][0]["id"] == live[0]["id"],
                  "real SIGINT in the middle of a create: the request finishes, the box is recorded, nothing else is created")
        else:
            check(p.returncode == 130 and "forced stop" in out and len(live) == 1 and not st["boxes"] and st["planned"][0]["name"] == live[0]["name"],
                  "double SIGINT mid-create: forced exit, the in-flight box is known by name in the state")
            rc, out = hz(e, "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9")
            st = state(e)
            check(rc == 0 and len(stub_servers(api)) == 2 and len(st["boxes"]) == 2 and st["boxes"][0]["host_pub"] == st["planned"][0]["host_pub"]
                  and len(json.load(open(e["BOTSIM_LEDGER"]))["servers"]) == 2,
                  "the next up adopts the in-flight box with its pinned host key and creates the other one")
        hz(e, "down")


def adopt_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    api = stub(tmp, "adopt")
    e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-adopt"), BOTSIM_LEDGER=os.path.join(tmp, "ledger-adopt", "spend.json"))
    os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
    hz(e, "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9")
    rc, out = hz(e, "up", "--yes", "--types", "cpx22,ccx13", "--min-left", "999")
    check(rc == 1 and "Too little time left" in out and len(stub_servers(api)) == 2, "boxes too close to their deadline are not adopted, the choices are explained")
    rc, out = hz(e, "up", "--yes", "--types", "ccx13", "--adopt")
    posts = [x for x in stub_log(api) if x[0] == "POST"]
    check(rc == 0 and "adopting" in out and len(posts) == 2 and len(state(e)["boxes"]) == 2, "--adopt keeps mismatched boxes as they are")
    os.remove(os.path.join(e["BOTSIM_CONFIG"], "current_run.json"))
    rc, out = hz(e, "up", "--yes", "--types", "cpx22,ccx13")
    check(rc == 1 and "stray server" in out, "without local state the boxes are strays, up refuses")
    rc, out = hz(e, "up", "--yes", "--types", "cpx22,ccx13", "--adopt")
    st = state(e)
    check(rc == 0 and len(st["boxes"]) == 2 and st["secret"] is None and "trust its key on first use" in out, "--adopt rebuilds a lost state from the API")
    rc, out = hz(e, "up", "--yes", "--types", "cpx22", "--replace")
    live = stub_servers(api)
    check(rc == 0 and len(live) == 1 and live[0]["server_type"]["name"] == "cpx22" and "throwing away" in out, "--replace deletes the old boxes and creates the new plan")
    hz(e, "down")


def deploy_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    api = stub(tmp, "deploy")
    e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-dep"), BOTSIM_LEDGER=os.path.join(tmp, "ledger-dep", "spend.json"),
             BOTSIM_SSH_AUTH_GRACE="1", BOTSIM_SSH_HOSTKEY_GRACE="1", BOTSIM_SSH_BOOT_TIMEOUT="3")
    os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
    hz(e, "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9")
    st = state(e)
    b0, b1 = st["boxes"]
    kh = os.path.join(e["BOTSIM_CONFIG"], "runs", st["run"], "known_hosts")
    lines = open(kh).read().split("\n")
    check(lines[0] == "%s %s" % (b0["name"], b0["host_pub"]) and lines[1].startswith(b1["name"] + " ssh-ed25519 "), "known_hosts of the run pins each box by name, not by IP")
    ud = get(api.replace("/v1", "/_userdata?name=") + b0["name"])["user_data"]
    check("ed25519_private: |" in ud and ("ed25519_public: %s botsim-host" % b0["host_pub"]) in ud and "ssh_deletekeys: true" in ud,
          "cloud-init installs the host key that known_hosts pins")
    reset_ssh(e, {b0["name"]: {"fail": ["refused", "timeout"]}, b1["name"]: {"always": "auth"}})
    t0 = time.time()
    rc, out = hz(e, "deploy")
    took = time.time() - t0
    calls = ssh_calls(e)
    o = next(c for c in calls if c["alias"] == b0["name"])["opts"]
    check(o.get("StrictHostKeyChecking") == "yes" and o.get("HostKeyAlias") == b0["name"] and o.get("UserKnownHostsFile") == kh
          and o.get("HostKeyAlgorithms") == "ssh-ed25519" and o.get("CheckHostIP") == "no", "ssh pins the host key: strict, alias per box, per-run known_hosts")
    check("refused: ssh: connect to host" in out and "timeout:" in out and "ssh ok after 3 tries" in out, "each failed ssh try prints the real error")
    check(rc == 2 and "gave up" in out and "auth" in out and "kept %s" % b1["name"] in out and "retry (boxes already done are skipped): python3 tools/botsim/cloud/hz.py deploy" in out
          and len(stub_servers(api)) == 2 and not any(x[0] == "DELETE" for x in stub_log(api)) and took < 30,
          "auth failure gives up in %.0f s with the reason, keeps both boxes, prints the retry" % took)
    reset_ssh(e, {b1["name"]: {"always": "hostkey"}})
    rc, out = hz(e, "deploy")
    check(rc == 2 and "already done, skipped" in out and "hostkey" in out and "--trust-new-host-keys" in out, "a changed host key fails fast and suggests --trust-new-host-keys")
    reset_ssh(e, {})
    rc, out = hz(e, "deploy", "--trust-new-host-keys")
    o = [c for c in ssh_calls(e) if c["alias"] == b1["name"]][0]["opts"]
    check(rc == 0 and o.get("StrictHostKeyChecking") == "accept-new" and o.get("UserKnownHostsFile") == kh, "--trust-new-host-keys trusts on first use, still per run")
    reset_ssh(e, {b0["name"]: {"golden": "fail"}})
    rc, out = hz(e, "deploy", "--force")
    rc2, out2 = hz(e, "run", "fake")
    check(rc == 2 and "golden sim test failed on %s" % b0["name"] in out and "expected S_A" in out and rc2 == 1 and "refusing to start fake" in out2,
          "a box that fails the golden sim test is not deployed and run refuses to start the job")
    lj = [c for c in ssh_calls(e) if "luajit-src" in c["command"]]
    rs = [json.loads(l) for l in open(e["FAKE_RSYNC_LOG"])]
    check(lj and "2.1.1791988261" in lj[0]["command"] and any(r["dst"].endswith(":/opt/botsim/luajit.tar.gz") for r in rs),
          "deploy ships the pinned LuaJIT source and builds 2.1.1791988261 on the box")
    reset_ssh(e, {b0["name"]: {"cloud_init": "error"}})
    rc, out = hz(e, "deploy", "--force")
    check(rc == 2 and "cloud-init on %s did not finish" % b0["name"] in out and "Unable to locate package" in out, "a cloud-init error shows the end of its log")
    hz(e, "down")


def pull_tests(tmp, env, check, hz, stub, stub_servers):
    api = stub(tmp, "pull")
    for types in ("cpx22", "cpx22,ccx13"):
        e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-pull-" + types), FAKE_RSYNC_NO_BOXES="1",
                 BOTSIM_LEDGER=os.path.join(tmp, "ledger-pull-" + types, "spend.json"))
        os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
        hz(e, "up", "--yes", "--types", types, "--hours", "0.9")
        st = state(e)
        rc, out = hz(e, "pull")
        out_dir = os.path.join(env["BOTSIM_RESULTS"], st["run"])
        ok = all(os.path.exists(os.path.join(out_dir, b["name"], "metrics.jsonl")) for b in st["boxes"])
        check(rc == 0 and ok and os.path.exists(os.path.join(out_dir, "run.json")), "pull with %d box(es), head without boxes/ folder" % len(st["boxes"]))
        hz(e, "down")


class FakeDash(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        raw = json.dumps({"games": 7, "gps": 2.5, "control": {"state": "running"}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def flow_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    api = stub(tmp, "bench")
    e = dict(env, BOTSIM_API=api, BOTSIM_CONFIG=os.path.join(tmp, "conf-bench"), BOTSIM_LEDGER=os.path.join(tmp, "ledger-bench", "spend.json"))
    os.makedirs(os.path.dirname(e["BOTSIM_LEDGER"]))
    reset_ssh(e)
    rc, out = hz(dict(e, BOTSIM_TEST_INTERRUPT="bench:collected"), "bench", "--types", "cpx22,ccx13", "--yes")
    check(rc == 130 and "resume: python3 tools/botsim/cloud/hz.py bench --types cpx22,ccx13 --yes" in out and len(stub_servers(api)) == 2,
          "SIGINT in bench keeps the boxes and prints the same command to resume")
    run = state(e)["run"]
    rc, out = hz(e, "bench", "--types", "cpx22,ccx13", "--yes")
    md = os.path.join(env["BOTSIM_RESULTS"], "bench-%s.md" % run)
    text = open(md).read() if os.path.exists(md) else ""
    posts = [x for x in stub_log(api) if x[0] == "POST"]
    check(rc == 0 and len(posts) == 2 and "adopting" in out and "AMD EPYC-Genoa Processor (fake" in text and text.count("| botsim-") == 2
          and "greedy policy runs" in text and not stub_servers(api), "bench resumes on the same boxes, writes bench-<run>.md with CPU per box, then deletes them")
    api2 = stub(tmp, "bench-fail")
    e2 = dict(e, BOTSIM_API=api2, BOTSIM_CONFIG=os.path.join(tmp, "conf-bench2"))
    reset_ssh(e2, {})
    hz(e2, "up", "--yes", "--types", "cpx22,ccx13", "--hours", "0.9")
    st = state(e2)
    reset_ssh(e2, {st["boxes"][1]["name"]: {"bench_exit": 1}})
    rc, out = hz(e2, "bench", "--types", "cpx22,ccx13", "--yes")
    check(rc == 2 and "bench failed on 1 of 2" in out and "kept " in out and len(stub_servers(api2)) == 2, "a failing benchmark keeps the boxes for a retry")
    reset_ssh(e2, {})
    rc, out = hz(e2, "bench", "--types", "cpx22,ccx13", "--yes")
    benches = [c for c in ssh_calls(e2) if "bench_mcts" in c["command"]]
    check(rc == 0 and len(benches) == 1 and not stub_servers(api2), "the retry only reruns the failed box, then deletes both")

    port = free_port()
    dash = http.server.ThreadingHTTPServer(("127.0.0.9", port), FakeDash)
    threading.Thread(target=dash.serve_forever, daemon=True).start()
    api3 = stub(tmp, "smoke", "--make-available", "cx23", "--fixed-ip", "127.0.0.9")
    e3 = dict(e, BOTSIM_API=api3, BOTSIM_CONFIG=os.path.join(tmp, "conf-smoke"), BOTSIM_DASH_PORT=str(port), FAKE_RSYNC_NO_BOXES="1")
    reset_ssh(e3, {})
    rc, out = hz(e3, "smoke", "--yes", "--wait", "20")
    check(rc == 0 and "dashboard ok: 7 games" in out and "smoke passed" in out and not stub_servers(api3), "smoke runs up, deploy, job, dashboard, pull and down in one go")
    dash.shutdown()


def sshd_tests(tmp, key, check, start):
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    if not os.path.exists(sshd):
        print("skip  no sshd, real host key tests skipped")
        return
    import safety
    d = os.path.join(tmp, "sshd")
    os.makedirs(d)
    keys = []
    for n in ("k1", "k2"):
        priv, pub = safety.gen_host_key()
        f = os.path.join(d, n)
        fd = os.open(f, os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, priv.encode())
        os.close(fd)
        keys.append((f, pub))
    shutil.copy(key + ".pub", os.path.join(d, "authorized_keys"))
    port = free_port()

    def serve(hostkey):
        cfg = os.path.join(d, "cfg")
        open(cfg, "w").write("Port %d\nListenAddress 127.0.0.1\nHostKey %s\nPidFile %s\nAuthorizedKeysFile %s\nStrictModes no\nUsePAM no\n"
                             "PasswordAuthentication no\nKbdInteractiveAuthentication no\nLogLevel ERROR\n" % (port, hostkey, os.path.join(d, "pid"), os.path.join(d, "authorized_keys")))
        p = start(NICE + [os.path.abspath(sshd), "-D", "-e", "-f", cfg], dict(os.environ), os.path.join(d, "sshd.log"))
        t_end = time.time() + 10
        while time.time() < t_end:
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                return p
            except OSError:
                time.sleep(0.1)
        return p

    os.environ["BOTSIM_SSH_PORT"] = str(port)
    os.environ["BOTSIM_SSH_USER"] = getpass.getuser()
    conf = os.path.join(tmp, "conf-sshd")
    msgs = []

    def attempt(run, box, client_key, **kw):
        safety.write_known_hosts(conf, run, [box])
        argv = lambda cmd: ["ssh"] + safety.ssh_opts(conf, run, box, client_key) + ["%s@127.0.0.1" % getpass.getuser(), cmd]
        t0 = time.time()
        try:
            safety.wait_ssh(argv, msgs.append, retry=0.3, **kw)
            return "ok", time.time() - t0
        except safety.StepFailed as e:
            return str(e), time.time() - t0

    p = serve(keys[0][0])
    res, _ = attempt("r1", {"name": "botsim-r1-0", "host_pub": keys[0][1]}, key)
    check(res == "ok", "real sshd: login works with the host key pinned at up")
    res, took = attempt("r1", {"name": "botsim-r1-0", "host_pub": keys[0][1]}, os.path.join(tmp, "other_key"), auth_grace=1, boot_timeout=20)
    check("auth" in res and took < 10, "real sshd: a wrong client key is reported as auth in %.1f s" % took)
    os.killpg(p.pid, signal.SIGTERM)
    p.wait()
    p = serve(keys[1][0])
    res, took = attempt("r1", {"name": "botsim-r1-0", "host_pub": keys[0][1]}, key, hostkey_grace=1, boot_timeout=20)
    check("hostkey" in res and took < 10, "real sshd: same IP and port, other host key: refused as hostkey in %.1f s" % took)
    res, _ = attempt("r2", {"name": "botsim-r2-0", "host_pub": keys[1][1]}, key)
    check(res == "ok", "real sshd: the next run pins its own key in its own known_hosts and connects")
    os.killpg(p.pid, signal.SIGTERM)
    p.wait()
    res, took = attempt("r2", {"name": "botsim-r2-0", "host_pub": keys[1][1]}, key, boot_timeout=1.5)
    check("refused" in res and took < 10, "real sshd down: gives up as refused after the boot timeout (%.1f s)" % took)
    os.environ.pop("BOTSIM_SSH_PORT")
    os.environ.pop("BOTSIM_SSH_USER")
