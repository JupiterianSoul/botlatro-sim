#!/usr/bin/env python3
import argparse
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(1, os.path.join(HERE, "..", "cloud"))

import ci
import paid
import steps
import store as storemod

LOCK_STALE = 45 * 60
POLL_S = 30
LOST_S = 30 * 60
FLAGS = ("fair_speed_ok", "expert_ok", "imitation_hold")


def say(*a):
    print(*a, flush=True)


def load_profiles():
    with open(os.path.join(HERE, "profiles.json")) as f:
        return json.load(f)


def default_runner(argv, env=None, timeout=3600):
    e = dict(os.environ)
    e.update(env or {})
    try:
        p = subprocess.run(argv, env=e, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as ex:
        return 127, str(ex)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def default_alert(title, message, priority):
    try:
        import alerts
        topic = alerts.read_topic()
    except Exception as e:
        topic = None
        say("alerts unavailable: %s" % e)
    if not topic:
        say("ALERT (no ntfy topic) %s: %s" % (title, message))
        return False
    try:
        return alerts.send(None, topic, "botsim autopilot: " + title, message, priority=priority, tags="robot")
    except Exception as e:
        say("ALERT not sent (%s) %s: %s" % (e, title, message))
        return False


def new_state(profile, dir_, prof):
    return {
        "version": 1, "id": secrets.token_hex(3), "profile": profile, "dir": dir_,
        "status": "running", "reason": "", "step": prof["steps"][0], "attempt": 1, "job": None,
        "flags": dict({k: False for k in FLAGS}, **prof.get("flags", {})),
        "paid": {"approved_eur": 0, "round_cap_eur": 0, "spent_eur": 0, "approved_at": None},
        "gates": {}, "baseline": {}, "best": {"name": None, "path": None, "score": {}},
        "stake": (prof.get("ladder") or {}).get("stakes", [1])[0], "stale_gens": 0, "rounds": [], "step_rounds": 0,
        "teacher": {"games": 0, "records": 0, "artifacts": [], "next": 1},
        "prechecked": None, "candidate": None, "final": False, "leak_ok": False, "seq": 0,
        "alerts_sent": {}, "lock": None, "updated": 0,
    }


class Ctx:
    def __init__(self, store, dir_, runner=None, alert_fn=None, now=None, sleep=None, results=None, profiles=None, dry=False, me=None):
        self.store = store
        self.dir = dir_
        self.run = runner or default_runner
        self.alert_fn = alert_fn or default_alert
        self.now = now or time.time
        self.sleep = sleep or time.sleep
        if results is None:
            import results as results
        self.res = results
        self.profiles = profiles or load_profiles()
        self.dry = dry
        self.me = me or "%s-%d-%s" % (socket.gethostname(), os.getpid(), os.environ.get("GITHUB_RUN_ID", "local"))
        self.st = None
        self.prof = None
        self.say = say

    def rel(self, name):
        return "%s/%s" % (self.dir, name)

    def load(self):
        self.st = self.store.read_json(self.rel("state.json"))
        if self.st:
            self.prof = self.profiles[self.st["profile"]]
        return self.st

    def write(self):
        self.st["updated"] = self.now()
        if not self.dry:
            self.store.write_json(self.rel("state.json"), self.st)

    def push(self, msg):
        self.write()
        if self.dry:
            return True
        ok = self.store.save("autopilot: " + msg)
        if not ok:
            say("could not push the state (%s)" % msg)
        return ok

    def event(self, msg):
        line = "- %s %s: %s" % (time.strftime("%Y-%m-%d %H:%M", time.gmtime(self.now())), self.st.get("step"), msg)
        say(line)
        if not self.dry:
            self.store.append(self.rel("log.md"), line)

    def alert(self, title, msg, priority=3, once=None):
        if once:
            if once in self.st["alerts_sent"]:
                return False
            self.st["alerts_sent"][once] = self.now()
        if self.dry:
            say("would alert: %s: %s" % (title, msg))
            return False
        return self.alert_fn(title, msg, priority)

    def add_rows(self, rows):
        if self.dry:
            return
        for r in rows or []:
            self.store.append(self.rel("results.jsonl"), json.dumps(r, sort_keys=True))

    def rows(self):
        out = []
        for line in (self.store.read_text(self.rel("results.jsonl"), "") or "").splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def render(self):
        if self.dry:
            return
        try:
            self.store.write_text(self.rel("RESULTS.md"), self.res.render(self.st, self.rows()))
        except Exception as e:
            say("RESULTS.md not rendered: %s" % e)

    def stop(self, reason, urgent=True):
        job = self.st.get("job") or {}
        if job.get("kind") == "hetzner":
            gone = paid.down_verify(self, job.get("run"))
            if not gone:
                reason += "; boxes still listed after down, check Hetzner now"
        self.st["job"] = None
        self.st["status"] = "stopped"
        self.st["reason"] = reason
        self.event("stopped: " + reason)
        self.alert("stopped", reason, 5 if urgent else 4)

    def wait(self, reason):
        if self.st["status"] != "waiting" or self.st["reason"] != reason:
            self.event("waiting: " + reason)
        self.st["status"] = "waiting"
        self.st["reason"] = reason
        self.alert("waiting", reason, 3, once="wait:" + reason)


def take_lock(ctx):
    lock = ctx.st.get("lock")
    if lock and lock.get("id") != ctx.me and ctx.now() - lock.get("t", 0) < LOCK_STALE:
        say("another tick holds the lock (%s, %d s ago)" % (lock.get("id"), ctx.now() - lock.get("t", 0)))
        return False
    ctx.st["lock"] = {"id": ctx.me, "t": ctx.now()}
    return ctx.push("lock")


def tick(ctx):
    ctx.store.sync()
    if not ctx.load():
        say("no state in %s, run init first" % ctx.dir)
        return 0
    if ctx.st["status"] in ("stopped", "done"):
        say("autopilot is %s: %s" % (ctx.st["status"], ctx.st.get("reason") or ""))
        return 0
    if not take_lock(ctx):
        return 0
    try:
        step_tick(ctx)
    except Exception as e:
        ctx.event("tick crashed: %s" % e)
        ctx.alert("tick crashed", str(e)[:300], 4, once="crash:%s" % str(e)[:80])
        raise
    finally:
        paid.cleanup_start_weights()
        ctx.render()
        ctx.st["lock"] = None
        ctx.push("tick %s %s" % (ctx.st["step"], ctx.st["status"]))
    return 0


def step_tick(ctx):
    for _ in range(8):
        paid.watchdog(ctx)
        if ctx.st.get("job"):
            res = poll(ctx)
            if res is None:
                say("job still running")
                return
            handle(ctx, res)
        if ctx.st["status"] not in ("running", "waiting") or ctx.st.get("job"):
            return
        before = (ctx.st["step"], ctx.st.get("seq"), ctx.st["status"])
        start(ctx)
        if ctx.st.get("job") or ctx.st["status"] != "running" or (ctx.st["step"], ctx.st.get("seq"), ctx.st["status"]) == before:
            return


def poll(ctx):
    job = ctx.st["job"]
    if job["kind"] == "hetzner":
        return paid.poll(ctx)
    return poll_ci(ctx)


def poll_ci(ctx):
    job = ctx.st["job"]
    if not job.get("run_id"):
        r = ci.find_run(ctx.run, job["tag"])
        if not r:
            if ctx.now() - job["dispatched"] > LOST_S:
                return {"ok": False, "why": "CI run %s never showed up" % job["tag"]}
            return None
        job["run_id"] = r["id"]
    else:
        r = ci.view_run(ctx.run, job["run_id"])
    if not r or r.get("status") != "completed":
        return None
    tmp = tempfile.mkdtemp(prefix="botsim-ap-")
    try:
        ok, out = ci.download(ctx.run, job["run_id"], tmp)
        arts = sorted(os.listdir(tmp)) if os.path.isdir(tmp) else []
        res = steps.finish(ctx, job["step"], job.get("phase", "main"), tmp, job["run_id"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    res["conclusion"] = r.get("conclusion")
    summary = {"tag": job["tag"], "run_id": job["run_id"], "conclusion": r.get("conclusion"), "artifacts": arts,
               "download_ok": ok, "step": job["step"], "phase": job.get("phase"), "result": res}
    if not ctx.dry:
        ctx.store.write_json(ctx.rel("work/%s.json" % (job["tag"] or job["run_id"])), summary)
    return res


def start(ctx):
    st = ctx.st
    step = st["step"]
    flag = steps.FLAG_OF.get(step)
    if flag and not st["flags"].get(flag):
        return ctx.wait("flag %s is off (autopilot.py flag %s on)" % (flag, flag))
    if steps.on_hetzner(ctx.prof, step, st):
        if step == "imitation" and st["flags"].get("imitation_hold"):
            return ctx.wait("imitation_hold is on, the paid imitation round waits (autopilot.py flag imitation_hold off)")
        return start_round(ctx, step)
    if step in steps.CI_STEPS:
        return dispatch(ctx, step, "main")
    if st.get("candidate"):
        return dispatch(ctx, step, "verify")
    if st.get("final"):
        return dispatch(ctx, step, "final")
    if st.get("prechecked") != (st["best"].get("name") or "none"):
        return dispatch(ctx, step, "precheck")
    return start_round(ctx, step)


def start_round(ctx, step):
    if ctx.dry and not ctx.prof.get("dry_paid"):
        say("dry run: would start a %s round: %s" % (step, " ".join(paid.round_args(ctx, step))))
        return
    what, why = paid.start(ctx, step)
    if what == "waiting":
        return ctx.wait(why)
    if what in ("failed",):
        return handle(ctx, {"ok": False, "why": why}, phase="round")
    if what == "stopped":
        return
    ctx.st["status"] = "running"
    ctx.st["reason"] = ""
    wait_min = float(paid.pconf(ctx, step).get("wait_minutes") or 0)
    end = ctx.now() + wait_min * 60
    while True:
        res = paid.poll(ctx)
        if res is not None:
            return handle(ctx, res)
        if ctx.now() >= end:
            return
        ctx.push("round polling")
        ctx.sleep(POLL_S)


def dispatch(ctx, step, phase):
    st = ctx.st
    jobs = steps.jobs_for(ctx, step, phase)
    if not jobs:
        return handle(ctx, {"ok": True, "why": ""}, phase=phase)
    tag = "%s-%d-%s-%s" % (st["id"], st["seq"] + 1, step.replace("_", ""), phase)
    if ctx.dry:
        say("dry run: would dispatch %s with %d jobs:" % (tag, len(jobs)))
        for j in jobs:
            say("  %s: %s" % (j["label"], j["cmd"]))
        return
    st["seq"] += 1
    st["status"] = "running"
    st["reason"] = ""
    st["job"] = {"kind": "ci", "step": step, "phase": phase, "tag": tag, "run_id": None, "dispatched": ctx.now(), "jobs": jobs}
    if not ctx.push("dispatch %s" % tag):
        st["job"] = None
        raise RuntimeError("could not record the dispatch of %s, not dispatching" % tag)
    ok, out = ci.dispatch(ctx.run, tag, jobs, ctx.dir)
    if not ok:
        st["job"] = None
        return handle(ctx, {"ok": False, "why": "gh workflow run failed: %s" % paid.tail(out)}, phase=phase)
    ctx.event("dispatched %s (%d jobs)" % (tag, len(jobs)))


def handle(ctx, res, phase=None):
    st = ctx.st
    job = st.get("job") or {}
    phase = phase or job.get("phase") or "main"
    step = st["step"]
    st["job"] = None
    if res.get("stopped") or st["status"] == "stopped":
        return
    g = st["gates"].setdefault(step, {"fails": 0, "last": {}})
    g["last"] = {k: v for k, v in res.items() if k in ("ok", "why", "conclusion", "improved", "best", "mean_s", "mean_ante", "games", "records", "white")}
    g["last"]["phase"] = phase
    g["last"]["t"] = ctx.now()
    if not res.get("ok"):
        return fail(ctx, step, phase, res.get("why") or "gate failed")
    if phase != "precheck":
        g["fails"] = 0
    if res.get("more"):
        ctx.event("batch done, %d of %d teacher games" % (st["teacher"]["games"], ctx.prof["teacher"]["games"]))
        return
    ctx.event("gate passed (%s)" % phase)
    if step in steps.CI_STEPS:
        ctx.alert("gate passed", "%s passed" % step, 3)
        return next_step(ctx)
    if phase == "precheck":
        st["prechecked"] = st["best"].get("name") or "none"
        return
    if phase == "round":
        return after_round(ctx, step, res)
    if phase == "verify":
        return after_verify(ctx, step)
    if phase == "final":
        return finish_all(ctx)


def fail(ctx, step, phase, why):
    st = ctx.st
    g = st["gates"][step]
    g["fails"] += 1
    if step in steps.PAID_STEPS:
        st["prechecked"] = None
        st["candidate"] = None
    ctx.event("gate failed (%s, %d in a row): %s" % (phase, g["fails"], why))
    if g["fails"] >= 2:
        return ctx.stop("%s failed twice in a row: %s" % (step, why), urgent=True)
    st["attempt"] += 1
    ctx.alert("gate failed", "%s (%s): %s; retrying" % (step, phase, why), 4)


def after_round(ctx, step, res):
    st, lp = ctx.st, ctx.prof.get("ladder") or {}
    st["step_rounds"] = st.get("step_rounds", 0) + 1
    dry = res.get("dry")
    if step == "expert":
        if not res.get("improved") and not dry:
            st["stale_gens"] += 1
        if st["stale_gens"] >= 4:
            ctx.event("expert stops after %d rounds without a better net" % st["stale_gens"])
            return next_step(ctx)
        if not st.get("candidate") and st["step_rounds"] >= ctx.prof["paid"]["max_rounds"]:
            return next_step(ctx)
        return
    if dry:
        return promote(ctx)
    if st["step_rounds"] >= ctx.prof["paid"]["max_rounds"] and not st.get("candidate"):
        return ctx.stop("ladder used its %d rounds at stake %d" % (st["step_rounds"], st["stake"]), urgent=False)


def after_verify(ctx, step):
    st, lp = ctx.st, ctx.prof.get("ladder") or {}
    cand = st["candidate"]
    st["best"] = {"name": cand["name"], "path": cand["path"], "score": cand["score"]}
    st["prechecked"] = cand["name"]
    st["candidate"] = None
    ctx.alert("new best", "%s: %s" % (cand["name"], json.dumps(cand["score"])), 3)
    if step == "expert":
        st["stale_gens"] = 0
        if st["step_rounds"] >= ctx.prof["paid"]["max_rounds"]:
            return next_step(ctx)
        return
    sc = cand["score"]
    if sc.get("n") and sc.get("wins", 0) / float(sc["n"]) >= lp.get("win_rate", 0.6):
        return promote(ctx)
    st["stale_gens"] += 1
    if st["stale_gens"] >= 4:
        return ctx.stop("ladder stuck at stake %d after %d rounds" % (st["stake"], st["stale_gens"]), urgent=False)


def promote(ctx):
    st, lp = ctx.st, ctx.prof.get("ladder") or {}
    stakes = lp.get("stakes", [1])
    ctx.event("stake %d passed" % st["stake"])
    ctx.alert("ladder", "stake %d passed" % st["stake"], 3)
    st["stale_gens"] = 0
    st["step_rounds"] = 0
    rest = [s for s in stakes if s > st["stake"]]
    if rest:
        st["stake"] = rest[0]
        return
    if lp.get("final_bench"):
        st["final"] = True
        return
    finish_all(ctx)


def next_step(ctx):
    st = ctx.st
    order = ctx.prof["steps"]
    i = order.index(st["step"]) if st["step"] in order else len(order)
    if i + 1 >= len(order):
        return finish_all(ctx)
    st["step"] = order[i + 1]
    st["attempt"] = 1
    st["step_rounds"] = 0
    if st["step"] == "ladder":
        st["stale_gens"] = 0
    st["status"] = "running"
    st["reason"] = ""
    ctx.event("next step")


def finish_all(ctx):
    ctx.st["status"] = "done"
    ctx.st["reason"] = "all steps done"
    ctx.st["final"] = False
    ctx.event("done")
    ctx.alert("done", "every step of the %s profile is done" % ctx.st["profile"], 4)


def mutate(ctx, msg, fn):
    ctx.store.sync()
    if not ctx.load():
        raise SystemExit("no state in %s, run init first" % ctx.dir)
    fn(ctx.st)
    ctx.render()
    ctx.push(msg)
    say("%s: %s, step %s" % (msg, ctx.st["status"], ctx.st["step"]))


def cmd_init(ctx, a):
    ctx.store.sync()
    if ctx.store.exists(ctx.rel("state.json")) and not a.reset:
        raise SystemExit("state exists in %s (use --reset to start over)" % ctx.dir)
    if a.profile not in ctx.profiles:
        raise SystemExit("unknown profile %s" % a.profile)
    ctx.prof = ctx.profiles[a.profile]
    ctx.st = new_state(a.profile, ctx.dir, ctx.prof)
    if a.from_ci:
        ctx.st["job"] = {"kind": "ci", "step": ctx.st["step"], "phase": "main", "tag": None, "run_id": int(a.from_ci),
                         "dispatched": ctx.now(), "jobs": []}
    ctx.event("init profile %s" % a.profile)
    ctx.render()
    ctx.push("init %s" % a.profile)
    say("autopilot initialised in %s with profile %s, first step %s" % (ctx.dir, a.profile, ctx.st["step"]))
    return 0


def cmd_status(ctx, a):
    ctx.store.sync()
    if not ctx.load():
        say("no state in %s" % ctx.dir)
        return 0
    st = ctx.st
    if a.json:
        print(json.dumps(st, indent=1, sort_keys=True))
        return 0
    say("profile %s, status %s, step %s (attempt %d)" % (st["profile"], st["status"], st["step"], st["attempt"]))
    if st.get("reason"):
        say("reason: %s" % st["reason"])
    job = st.get("job")
    if job:
        say("job: %s %s" % (job["kind"], job.get("tag") or job.get("run")))
    p = st["paid"]
    say("paid: %.2f of %.2f EUR approved, round cap %.2f" % (paid.used(p, paid.spent(ctx) if not ctx.dry else None), p["approved_eur"], p["round_cap_eur"]))
    say("best: %s" % (st["best"].get("name") or "none"))
    return 0


def cmd_flag(ctx, a):
    if a.name not in FLAGS:
        raise SystemExit("flags: %s" % ", ".join(FLAGS))

    def f(st):
        st["flags"][a.name] = a.value == "on"
        if st["status"] == "waiting":
            st["status"], st["reason"] = "running", ""
    mutate(ctx, "flag %s %s" % (a.name, a.value), f)
    return 0


def cmd_approve(ctx, a):
    def f(st):
        st["paid"]["approved_eur"] = a.eur
        st["paid"]["round_cap_eur"] = a.round_cap
        st["paid"]["approved_at"] = ctx.now()
        led = paid.spent(ctx) if not ctx.dry else None
        if a.already_spent is not None:
            st["paid"]["spent_eur"] = a.already_spent
        if led is not None:
            st["paid"]["ledger_base"] = round(led - st["paid"].get("spent_eur", 0), 4)
        if st["status"] == "waiting":
            st["status"], st["reason"] = "running", ""
    mutate(ctx, "approve %.2f EUR, round cap %.2f" % (a.eur, a.round_cap), f)
    return 0


def cmd_stop(ctx, a):
    ctx.store.sync()
    if not ctx.load():
        raise SystemExit("no state in %s" % ctx.dir)
    ctx.stop(" ".join(a.reason) or "stopped by hand", urgent=False)
    ctx.render()
    ctx.push("stop")
    return 0


def cmd_resume(ctx, a):
    def f(st):
        st["status"], st["reason"] = "running", ""
        st["gates"].setdefault(st["step"], {"fails": 0, "last": {}})["fails"] = 0
        st["lock"] = None
    mutate(ctx, "resume", f)
    return 0


def cmd_redo(ctx, a):
    def f(st):
        steps = ctx.prof["steps"]
        if a.step not in steps or steps.index(a.step) > steps.index(st["step"]):
            raise SystemExit("redo goes back to an earlier step of %s, got %s" % (", ".join(steps), a.step))
        if st.get("job"):
            raise SystemExit("a job is live (%s); stop first" % (st["job"].get("tag") or st["job"].get("run")))
        st["step"], st["attempt"], st["step_rounds"] = a.step, 1, 0
        st["status"], st["reason"], st["lock"] = "running", "", None
        for later in steps[steps.index(a.step):]:
            st["gates"][later] = {"fails": 0, "last": {}}
        if a.step == "teacher":
            st["teacher"] = {"games": 0, "records": 0, "artifacts": [], "next": 1}
        if "imitation" in steps and steps.index(a.step) <= steps.index("imitation"):
            st["best"] = {"name": None, "path": None, "score": {}}
            st["candidate"], st["prechecked"] = None, None
    mutate(ctx, "redo %s" % a.step, f)
    return 0


def cmd_extend(ctx, a):
    def f(st):
        steps = ctx.prof["steps"]
        if a.step != "teacher" or "teacher" not in steps:
            raise SystemExit("extend works on the teacher step only")
        if steps.index("teacher") > steps.index(st["step"]):
            raise SystemExit("the teacher step is not done yet")
        if st.get("job"):
            raise SystemExit("a job is live (%s); stop first" % (st["job"].get("tag") or st["job"].get("run")))
        if a.games <= 0:
            raise SystemExit("--games must be positive")
        t = st["teacher"]
        t["target"] = int(t.get("games", 0)) + a.games
        t["ci"] = bool(a.ci)
        if a.hold:
            st["flags"]["imitation_hold"] = True
        st["step"], st["attempt"], st["step_rounds"] = "teacher", 1, 0
        st["status"], st["reason"], st["lock"] = "running", "", None
        for later in steps[steps.index("teacher"):]:
            st["gates"][later] = {"fails": 0, "last": {}}
        st["best"] = {"name": None, "path": None, "score": {}}
        st["candidate"], st["prechecked"] = None, None
    mutate(ctx, "extend teacher +%d%s" % (a.games, " on CI" if a.ci else ""), f)
    return 0


def cmd_results(ctx, a):
    ctx.store.sync()
    if not ctx.load():
        raise SystemExit("no state in %s" % ctx.dir)
    ctx.render()
    ctx.push("results")
    return 0


def parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dir", default=argparse.SUPPRESS)
    common.add_argument("--store-local", default=argparse.SUPPRESS)
    common.add_argument("--dry-run", action="store_true", default=argparse.SUPPRESS)
    p = argparse.ArgumentParser(prog="autopilot.py", parents=[common])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("init", parents=[common])
    s.add_argument("--profile", required=True)
    s.add_argument("--from-ci")
    s.add_argument("--reset", action="store_true")
    sub.add_parser("tick", parents=[common])
    s = sub.add_parser("status", parents=[common])
    s.add_argument("--json", action="store_true")
    s = sub.add_parser("flag", parents=[common])
    s.add_argument("name")
    s.add_argument("value", choices=["on", "off"])
    s = sub.add_parser("approve", parents=[common])
    s.add_argument("--eur", type=float, required=True)
    s.add_argument("--round-cap", type=float, required=True)
    s.add_argument("--already-spent", type=float, default=None)
    s = sub.add_parser("stop", parents=[common])
    s.add_argument("reason", nargs="*")
    sub.add_parser("resume", parents=[common])
    s = sub.add_parser("redo", parents=[common])
    s.add_argument("step")
    s = sub.add_parser("extend", parents=[common])
    s.add_argument("step")
    s.add_argument("--games", type=int, required=True)
    s.add_argument("--ci", action="store_true")
    s.add_argument("--hold", action="store_true")
    sub.add_parser("results", parents=[common])
    return p


COMMANDS = {"init": cmd_init, "tick": tick, "status": cmd_status, "flag": cmd_flag, "approve": cmd_approve,
            "stop": cmd_stop, "resume": cmd_resume, "redo": cmd_redo, "extend": cmd_extend, "results": cmd_results}


def main(argv=None, **kw):
    a = parser().parse_args(argv)
    dir_ = getattr(a, "dir", None) or "autopilot"
    st = kw.pop("store", None) or storemod.open_store(getattr(a, "store_local", None))
    ctx = Ctx(st, dir_, dry=getattr(a, "dry_run", False), **kw)
    fn = COMMANDS[a.cmd]
    return fn(ctx) if a.cmd == "tick" else fn(ctx, a)


if __name__ == "__main__":
    sys.exit(main() or 0)
