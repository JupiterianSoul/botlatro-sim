import json
import os
import shutil
import subprocess
import sys
import time

LAST = []
HERE = os.path.dirname(os.path.abspath(__file__))
CLOUD = os.path.dirname(HERE)
PY = sys.executable


def run(tmp, env, check0, hz0, stub, stub_servers, stub_log):
    last = {"out": ""}

    def hz(*a, **k):
        rc, out = hz0(*a, **k)
        last["out"] = out
        return rc, out

    def check(cond, what):
        check0(cond, what)
        if not cond:
            print("      " + last["out"][-2500:].replace("\n", "\n      "))
        last["out"] = ""

    LAST.append(last)
    union_tests(check)
    run_tests(tmp, env, check, hz)
    shared_tests(tmp, env, check, hz, stub, stub_servers, stub_log)
    done_tests(tmp, check)
    fake_minutes_test(tmp, check)


def union_tests(check):
    import hz
    s = lambda i, d=None, est=False: dict({"id": i, "name": "b%d" % i, "type": "cx23", "price_hourly_gross": 0.01, "created": 100.0, "deleted": d},
                                          **({"deleted_estimated": True} if est else {}))
    u = hz.union_ledgers({"servers": [s(1)]}, {"servers": [s(1, 500.0, True)]})
    check(u["servers"][0]["deleted"] == 500.0, "union: a deletion beats still running")
    u = hz.union_ledgers({"servers": [s(1, 900.0, True)]}, {"servers": [s(1, 400.0)]})
    check(u["servers"][0]["deleted"] == 400.0 and not u["servers"][0].get("deleted_estimated"), "union: a real deletion beats an estimated one")
    u = hz.union_ledgers({"servers": [s(1, 300.0, True)]}, {"servers": [s(1, 700.0, True)]})
    check(u["servers"][0]["deleted"] == 700.0, "union: between two estimated deletions the later wins")
    u = hz.union_ledgers({"servers": [s(1), s(2)]}, {"servers": [s(3)]})
    check(sorted(e["id"] for e in u["servers"]) == [1, 2, 3], "union: servers from both sides by id")
    adj = {"date": "2026-10-20", "note": "fix", "eur": 1.5}
    u = hz.union_ledgers({"servers": [], "adjustments": [dict(adj)]}, {"servers": [], "adjustments": [dict(adj), {"id": "x", "eur": 2}]})
    check(len(u["adjustments"]) == 2 and all(a.get("id") for a in u["adjustments"]), "union: adjustments by id, old ones get a stable id")


def write_state(conf, boxes):
    os.makedirs(conf, exist_ok=True)
    json.dump({"run": "rt", "port": 8, "secret": "s", "dashboard_url": "http://127.0.0.1:9/s/",
               "boxes": [{"name": n, "ip": "10.9.0.%d" % i, "run": "rt", "role": "head" if i == 0 else "node", "deployed": True, "index": i,
                          "created": time.time() - 60, "deadline": time.time() + 3000}
                         for i, n in enumerate(boxes)]}, open(os.path.join(conf, "current_run.json"), "w"))


def last_json(out):
    for ln in reversed(out.strip().split("\n")):
        if ln.startswith("{"):
            return json.loads(ln)
    return None


def run_tests(tmp, env, check, hz):
    d = os.path.join(tmp, "runtest")
    os.makedirs(d)
    e = dict(env, BOTSIM_CONFIG=os.path.join(d, "conf"), FAKE_SSH_LOG=os.path.join(d, "ssh.log"), FAKE_SSH_PLAN=os.path.join(d, "plan.json"))
    names = ["botsim-rt-0", "botsim-rt-1"]
    write_state(e["BOTSIM_CONFIG"], names)

    def plan(p):
        for f in os.listdir(d):
            if f.startswith("count-") or f.startswith("job-"):
                os.remove(os.path.join(d, f))
        json.dump(p, open(e["FAKE_SSH_PLAN"], "w"))

    plan({})
    rc, out = hz(e, "run", "fake", "--env", "FAKE_MINUTES=5", "--delete-when-done", "--json")
    j = last_json(out)
    sent = {"BOTSIM_JOB": "fake", "FAKE_MINUTES": "5", "BOTSIM_DELETE_WHEN_DONE": "1"}
    check(rc == 0 and j and j["started"] == names and not j["refused"] and not j["failed"]
          and all(j["readback"][n]["env"] == sent and j["readback"][n]["start"] for n in names) and "readback botsim-rt-0" in out,
          "run starts every box and reads back start time and job.env (--delete-when-done sets the flag)")
    rc, out = hz(e, "run", "fake", "--env", "FAKE_MINUTES=7", "--json")
    j = last_json(out)
    check(rc == 3 and j and j["refused"] == names and not j["started"] and "NOT STARTED" in out and "FAKE_MINUTES=5" in out
          and not any(ln.startswith("started") for ln in out.split("\n")) and "skipped" not in out,
          "run on boxes already running refuses with NOT STARTED, their settings, exit 3")
    rc, out = hz(e, "run", "fake", "--env", "FAKE_MINUTES=7", "--force", "--json")
    j = last_json(out)
    check(rc == 0 and j["started"] == names and j["readback"][names[0]]["env"]["FAKE_MINUTES"] == "7", "run --force restarts and reads back the new settings")
    plan({names[0]: {"job_state": "active", "job_start": time.time() - 99, "job_env": "BOTSIM_JOB=train\n"}})
    rc, out = hz(e, "run", "fake", "--json")
    j = last_json(out)
    check(rc == 3 and j["refused"] == [names[0]] and j["started"] == [names[1]] and "BOTSIM_JOB=train" in out,
          "run starts the idle box, refuses the busy one, exit 3")
    plan({names[1]: {"restart": "bad_env"}})
    rc, out = hz(e, "run", "fake", "--json")
    j = last_json(out)
    check(rc == 2 and j["failed"] == [names[1]] and j["started"] == [names[0]] and "does not match" in out, "job.env readback mismatch fails, exit 2")
    plan({names[0]: {"restart": "old_start"}})
    rc, out = hz(e, "run", "fake", "--json")
    j = last_json(out)
    check(rc == 2 and j["failed"] == [names[0]] and "not after the restart" in out, "a start time older than the restart fails, exit 2")
    plan({names[0]: {"restart": "inactive"}})
    rc, out = hz(e, "run", "fake")
    check(rc == 2 and "FAILED" in out and "summary:" in out.strip().split("\n")[-1], "a job not active after the start fails, summary is the last line")
    plan({names[1]: {"always": "refused"}})
    rc, out = hz(e, "run", "fake", "--json")
    j = last_json(out)
    check(rc == 2 and names[1] in j["failed"], "an unreachable box is reported FAILED, never skipped")


def git(*a, cwd=None):
    return subprocess.run(["git"] + list(a), cwd=cwd, capture_output=True, text=True)


def shared_tests(tmp, env, check, hz, stub, stub_servers, stub_log):
    import hz as H
    from common import ledger_spent
    bare = os.path.join(tmp, "shared.git")
    git("init", "-q", "--bare", "-b", "main", bare)
    real = json.load(open(os.path.join(CLOUD, "spend.json")))
    base = dict(env)
    base.pop("BOTSIM_SHARED_LEDGER", None)

    def machine(n, remote=bare):
        d = os.path.join(tmp, "shared-m%d" % n)
        os.makedirs(os.path.join(d, "ledger"), exist_ok=True)
        return dict(base, BOTSIM_CONFIG=os.path.join(d, "conf"), BOTSIM_LEDGER=os.path.join(d, "ledger", "spend.json"),
                    BOTSIM_SHARED_REMOTE=remote, BOTSIM_SHARED_CACHE=os.path.join(d, "cache"))

    def remote_ledger():
        r = git("--git-dir", bare, "show", "main:ledger/spend.json")
        return json.loads(r.stdout) if r.returncode == 0 else None

    m1 = machine(1)
    json.dump(real, open(m1["BOTSIM_LEDGER"], "w"))
    rc, out = hz(m1, "spend", "--json")
    j = last_json(out)
    want = ledger_spent(real)
    rl = remote_ledger()
    check(rc == 0 and j and abs(j["spent_eur"] - want) < 0.01 and rl and len(rl["servers"]) == len(real["servers"]),
          "first sync seeds the shared ledger from the local one (%.2f EUR)" % want)
    log = git("--git-dir", bare, "log", "-1", "--format=%an <%ae>").stdout.strip()
    check(log == "Gabriel Quart <gabriel.quart.15@gmail.com>", "shared ledger commits are made as Gabriel")
    m2 = machine(2)
    now = time.time()
    extra = {"id": 999001, "name": "botsim-other-0", "run": "other", "type": "cx23", "location": "fsn1", "price_hourly_gross": 0.5,
             "created": now - 600, "deadline": now + 3000, "deleted": now - 60}
    json.dump({"cap_eur": 100.0, "credit_eur": 25.0, "servers": [extra], "adjustments": []}, open(m2["BOTSIM_LEDGER"], "w"))
    rc, out = hz(m2, "spend", "--json")
    j = last_json(out)
    check(rc == 0 and abs(j["spent_eur"] - (want + 0.5)) < 0.01 and len(remote_ledger()["servers"]) == len(real["servers"]) + 1,
          "a second machine sees the first one's spend and adds its own")
    rc, out = hz(m1, "spend", "--json")
    j = last_json(out)
    check(abs(j["spent_eur"] - (want + 0.5)) < 0.01 and any(e["id"] == 999001 for e in json.load(open(m1["BOTSIM_LEDGER"]))["servers"]),
          "the first machine picks up the second one's box")
    bad = machine(3, os.path.join(tmp, "missing.git"))
    json.dump({"cap_eur": 100.0, "credit_eur": 25.0, "servers": [], "adjustments": []}, open(bad["BOTSIM_LEDGER"], "w"))
    api = stub(tmp, "shared")
    bad["BOTSIM_API"] = api
    rc, out = hz(bad, "up", "--yes", "--types", "cx23", "--hours", "1")
    check(rc != 0 and "shared ledger" in out and "cannot be read" in out and not stub_servers(api) and not any(x[0] == "POST" for x in stub_log(api)),
          "up refuses when the shared ledger cannot be read, creates nothing")
    rc, out = hz(bad, "smoke", "--yes")
    check(rc != 0 and "cannot be read" in out and not stub_servers(api), "smoke refuses too")
    rc, out = hz(bad, "spend", "--json")
    pending = os.path.join(bad["BOTSIM_CONFIG"], "shared_ledger_pending")
    check(rc == 0 and os.path.exists(pending) and "could not push" in out, "a failed push is kept pending, not fatal")
    fixed = dict(bad, BOTSIM_SHARED_REMOTE=bare)
    rc, out = hz(fixed, "spend", "--json")
    check(rc == 0 and not os.path.exists(pending), "the pending push goes through at the next call")


def box_env(root, role, flag):
    etc, home = os.path.join(root, "etc"), os.path.join(root, "home")
    os.makedirs(etc, exist_ok=True)
    os.makedirs(os.path.join(home, "run"), exist_ok=True)
    json.dump({"name": "b", "run": "r", "role": role, "deadline": time.time() + 3000}, open(os.path.join(etc, "box.json"), "w"))
    json.dump({"name": "b", "run": "r", "role": role, "workers": 1}, open(os.path.join(etc, "node.json"), "w"))
    open(os.path.join(etc, "job.env"), "w").write("BOTSIM_JOB=x\n" + ("BOTSIM_DELETE_WHEN_DONE=1\n" if flag else ""))
    e = dict(os.environ, BOTSIM_ETC=etc, BOTSIM_HOME=home, BOTSIM_LOG=os.path.join(root, "w.log"), BOTSIM_REPO=root)
    e.pop("BOTSIM_DELETE_WHEN_DONE", None)
    return e, os.path.join(home, "run")


def done_tests(tmp, check):
    job = os.path.join(tmp, "tinyjob")
    os.makedirs(job)
    for name, code in (("ok", 0), ("bad", 3)):
        os.makedirs(os.path.join(job, name))
        p = os.path.join(job, name, "run")
        open(p, "w").write("#!/bin/sh\nexit %d\n" % code)
        os.chmod(p, 0o755)
    cases = [("head", True, "ok", True, "done"), ("head", True, "bad", True, "failed"), ("node", True, "ok", False, "done"), ("head", False, "ok", False, "done")]
    for i, (role, flag, jobname, want, how) in enumerate(cases):
        e, rd = box_env(os.path.join(tmp, "done%d" % i), role, flag)
        subprocess.run([PY, os.path.join(CLOUD, "jobrun.py"), os.path.join(job, jobname)], env=e, cwd=tmp, capture_output=True, timeout=60)
        ex = json.load(open(os.path.join(rd, "JOB_EXIT")))
        st = json.load(open(os.path.join(rd, "JOB_START")))
        check(ex["how"] == how and ex["start"] == st["t"] and os.path.exists(os.path.join(rd, "STOP_REQUEST")) == want,
              "jobrun: %s job on a %s %s the flag %s the stop path" % (how, role, "with" if flag else "without", "starts" if want else "does not start"))
    probe = ("import sys, time; sys.path.insert(0, %r); import boxctl; "
             "print(boxctl.done_check(boxctl.box(), {}, time.time(), active=lambda: False))" % CLOUD)

    def tick_case(i, role, flag, setup):
        e, rd = box_env(os.path.join(tmp, "tick%d" % i), role, flag)
        t = time.time()
        json.dump({"t": t, "pid": 1}, open(os.path.join(rd, "JOB_START"), "w"))
        json.dump({"t": t + 5, "start": t, "how": "killed", "rc": None}, open(os.path.join(rd, "JOB_EXIT"), "w"))
        setup(rd, t)
        r = subprocess.run([PY, "-c", probe], env=e, capture_output=True, text=True, timeout=60)
        LAST[0]["out"] = r.stdout + r.stderr
        return r.stdout.strip().split("\n")[-1] == "True" and os.path.exists(os.path.join(rd, "STOP_REQUEST"))

    nothing = lambda rd, t: None
    check(tick_case(0, "head", True, nothing), "watchdog: head job killed with the flag starts the stop path")
    check(not tick_case(1, "head", True, lambda rd, t: open(os.path.join(rd, "RESTARTING"), "w").close()), "watchdog: a restart in progress never triggers it")
    check(not tick_case(2, "head", True, lambda rd, t: json.dump({"t": t + 10, "pid": 2}, open(os.path.join(rd, "JOB_START"), "w"))),
          "watchdog: an exit older than the current start never triggers it")
    check(not tick_case(3, "node", True, nothing), "watchdog: a node's own exit does not trigger it")
    check(not tick_case(4, "head", False, nothing), "watchdog: without the flag nothing happens")


def fake_minutes_test(tmp, check):
    rd = os.path.join(tmp, "fakemin")
    os.makedirs(os.path.join(rd, "checkpoints"))
    e = dict(os.environ, BOTSIM_CHECKPOINTS=os.path.join(rd, "checkpoints"), FAKE_MINUTES="0.1", BOTSIM_FAKE_BENCH="0", BOTSIM_FAKE_REPORT="1", BOTSIM_RUN_DIR=rd, BOTSIM_WORKERS="1")
    e.pop("BOTSIM_FAKE_MINUTES", None)
    t0 = time.time()
    try:
        r = subprocess.run([PY, os.path.join(CLOUD, "jobs", "fake", "run")], env=e, cwd=rd, capture_output=True, timeout=90)
        rc = r.returncode
    except subprocess.TimeoutExpired:
        rc = None
    check(rc == 0 and time.time() - t0 < 60, "fake job with FAKE_MINUTES=0.1 finishes cleanly by itself (%.0f s)" % (time.time() - t0))
    shutil.rmtree(rd, ignore_errors=True)
