import json
import os
import re
import shutil
import sys

import ci
import gates
import steps
from steps import REPO

HZ = os.path.join(REPO, "tools", "botsim", "cloud", "hz.py")
CAP_EUR = 100.0
DRY_OK = ("up", "deploy", "run", "down")
ENDED = ("done", "saved", "stopped", "failed", "killed")
START_W = "tools/botsim/autopilot/start.bnnw"


def conf():
    return os.environ.get("BOTSIM_CONFIG", os.path.expanduser("~/.config/botsim"))


def current_path():
    return os.path.join(conf(), "current_run.json")


def dry(ctx):
    return bool(ctx.prof.get("dry_paid")) or ctx.dry


def hz(ctx, *args, env=None):
    argv = [sys.executable, HZ] + list(args)
    if dry(ctx) and args[0] in DRY_OK:
        argv.append("--dry-run")
    ctx.say("hz.py " + " ".join(args))
    return ctx.run(argv, env=env)


def hz_json(ctx, *args):
    rc, out = hz(ctx, *(list(args) + ["--json"]))
    return rc, ci.last_json(out)


def keep(ctx, run):
    if run and os.path.exists(current_path()):
        ctx.store.copy_in(current_path(), "%s/hz/%s.json" % (ctx.dir, run))


def restore(ctx, run):
    rel = "%s/hz/%s.json" % (ctx.dir, run)
    if run and ctx.store.exists(rel):
        os.makedirs(conf(), exist_ok=True)
        ctx.store.copy_out(rel, current_path())
        os.chmod(current_path(), 0o600)


def pconf(ctx, step=None):
    step = step or ctx.st.get("step")
    if step in ("teacher", "imitation") and (ctx.prof.get(step) or {}).get("paid"):
        return ctx.prof[step]["paid"]
    return ctx.prof["paid"]


def round_args(ctx, step=None):
    p = pconf(ctx, step)
    return ["--types", p["types"], "--hours", str(p["hours"]), "--spend-cap", str(p["spend_cap"])]


def round_cost(ctx, step=None):
    rc, j = hz_json(ctx, "plan", *round_args(ctx, step))
    if rc == 0 and isinstance(j, dict) and j.get("cost_eur") is not None:
        return float(j["cost_eur"])
    if dry(ctx):
        return 0.0
    return None


def spent(ctx):
    rc, j = hz_json(ctx, "spend")
    if rc == 0 and isinstance(j, dict) and j.get("spent_eur") is not None:
        return float(j["spent_eur"])
    return None


def boxes(ctx):
    if dry(ctx):
        return []
    rc, j = hz_json(ctx, "list")
    if isinstance(j, dict):
        j = j.get("servers")
    if rc != 0 or not isinstance(j, list):
        return None
    return j


def used(pd, ledger):
    base = pd.get("ledger_base")
    own = pd.get("spent_eur", 0)
    if base is None or ledger is None:
        return own
    return max(own, ledger - base)


def budget_problem(ctx, cost):
    pd = ctx.st["paid"]
    if cost is None:
        return "cannot price the round (hz.py plan --json failed)"
    if dry(ctx):
        return None
    if pd.get("approved_eur", 0) <= 0:
        return "no approved budget for paid rounds"
    if cost > pd.get("round_cap_eur", 0):
        return "round costs %.2f EUR, over the per-round cap %.2f" % (cost, pd.get("round_cap_eur", 0))
    s = spent(ctx)
    if s is None:
        return "cannot read the shared ledger (hz.py spend --json failed)"
    left = pd["approved_eur"] - used(pd, s)
    if left < cost:
        return "approved budget used up: %.2f EUR left, round costs %.2f" % (left, cost)
    if s + cost > CAP_EUR:
        return "shared ledger %.2f + round %.2f EUR is over the %.0f EUR cap" % (s, cost, CAP_EUR)
    return None


def down_verify(ctx, run=None):
    if run:
        restore(ctx, run)
    for i in range(3):
        hz(ctx, "down")
        left = boxes(ctx)
        if left == []:
            return True
        ctx.say("boxes still listed after down (try %d)" % (i + 1))
        ctx.sleep(10)
    return False


def teacher_env(ctx):
    t, tp = ctx.st["teacher"], ctx.prof["teacher"]
    per = len(tp["decks"].split(",")) * len(str(tp["stakes"]).split(","))
    left = max(0, steps.teacher_goal(ctx.st, tp) - t["games"])
    seeds = max(1, min(int(tp["paid"]["seeds_per_round"]), -(-left // per)))
    return {"TEACH_START": str(t.get("next", 1)), "TEACH_SEEDS": str(seeds), "TEACH_DECKS": tp["decks"],
            "TEACH_STAKES": str(tp["stakes"]), "TEACH_PREFIX": tp["prefix"], "TEACH_BUDGET": tp["budget"],
            "TEACH_STOP_ANTE": str(tp.get("stop_ante") or 0), "TEACH_LEAK_ARGS": ctx.prof.get("leak_args", "")}


def imitation_env(ctx):
    ip, b = ctx.prof["imitation"], ctx.prof["bench"]
    sh = ctx.prof["shuffle"]
    runs = [a["hz_run"] for a in ctx.st["teacher"].get("artifacts", []) if a.get("hz_run")]
    env = {"IMIT_RUNS": ",".join(runs), "IMIT_STEPS": str(ip["steps"]), "IMIT_EVAL_SEEDS": str(ip["eval_seeds"]),
           "IMIT_DECKS": ip["decks"], "IMIT_STAKES": str(ip["stakes"]), "IMIT_PREFIX": b["prefix"], "IMIT_WINDOW": str(ip.get("window", 0)),
           "IMIT_LEAK_ARGS": ctx.prof.get("leak_args", ""), "IMIT_SHUFFLE_SEEDS": str(sh["seeds"]), "IMIT_SHUFFLE_DECKS": sh["decks"],
           "IMIT_SHUFFLE_STAKES": str(sh["stakes"]), "IMIT_SHUFFLE_STEPS": str(sh["max_steps"])}
    if ip.get("cfg"):
        env["IMIT_CFG"] = ip["cfg"]
    if ip.get("chosen"):
        env["IMIT_CHOSEN"] = str(ip["chosen"])
    if ip.get("all_discards"):
        env["IMIT_ALL_DISC"] = str(ip["all_discards"])
    if ip.get("eval_args"):
        env["IMIT_EVAL_ARGS"] = ip["eval_args"]
    if ip.get("value_weight") is not None:
        env["IMIT_VALUE_W"] = str(ip["value_weight"])
    return env


def env_for(ctx, step):
    p = pconf(ctx, step)
    env = {"BOTSIM_DELETE_WHEN_DONE": "1", "TRAIN_PATIENCE": "4"}
    env.update(p.get("env") or {})
    if step == "teacher":
        env.update(teacher_env(ctx))
        return env
    if step == "imitation":
        env.update(imitation_env(ctx))
        return env
    if ctx.st["best"].get("path") and not dry(ctx):
        env["TRAIN_WEIGHTS"] = START_W
    if step == "ladder":
        env["TRAIN_STAKES"] = env["TRAIN_EVAL_STAKES"] = str(ctx.st["stake"])
    return env


def start(ctx, step):
    cost = round_cost(ctx, step)
    why = budget_problem(ctx, cost)
    if why:
        return "waiting", why
    p = pconf(ctx, step)
    now = ctx.now()
    before = spent(ctx) if not dry(ctx) else 0.0
    ctx.st["job"] = {"kind": "hetzner", "step": step, "phase": "round", "run": None, "started": now,
                     "deadline": now + float(p["hours"]) * 3600, "round_cost_eur": cost, "spent_before": before, "readback": {}}
    ctx.push("round starting for %s" % step)
    if not dry(ctx):
        rc, out = hz(ctx, "doctor")
        if rc != 0:
            ctx.st["job"] = None
            return "failed", "hz.py doctor failed: " + tail(out)
    rc, out = hz(ctx, "up", *(round_args(ctx, step) + ["--yes"]))
    run = run_name(ctx)
    ctx.st["job"]["run"] = run
    keep(ctx, run)
    ctx.push("round %s up" % run)
    if not checked(ctx, "up", rc, out):
        return abort(ctx, "hz.py up failed: " + tail(out))
    if ctx.st["best"].get("path") and not dry(ctx) and step not in ("teacher", "imitation"):
        ctx.store.copy_out(ctx.st["best"]["path"], os.path.join(REPO, START_W))
    rc, out = hz(ctx, "deploy", "--for-job", p["job"])
    keep(ctx, run)
    if not checked(ctx, "deploy", rc, out):
        return abort(ctx, "hz.py deploy failed: " + tail(out))
    args = ["run", p["job"]]
    for k, v in sorted(env_for(ctx, step).items()):
        args += ["--env", "%s=%s" % (k, v)]
    rc, out = hz(ctx, *(args + ["--json"]))
    keep(ctx, run)
    rb = ci.last_json(out) or {}
    ctx.st["job"]["readback"] = rb.get("readback") or {}
    if not checked(ctx, "run", rc, out) or (not dry(ctx) and (not rb.get("started") or rb.get("failed") or rb.get("refused"))):
        return abort(ctx, "hz.py run did not start cleanly (exit %d): %s" % (rc, tail(out)))
    ctx.alert("paid round started", "%s round %s, about %.2f EUR" % (step, run, cost or 0), 3)
    ctx.event("round %s started (%.2f EUR planned)" % (run, cost or 0))
    return "started", None


def checked(ctx, what, rc, out):
    if rc == 0:
        return True
    if dry(ctx):
        ctx.event("dry run: hz.py %s exit %d: %s" % (what, rc, tail(out, 160)))
        return True
    return False


def run_name(ctx):
    if dry(ctx):
        return "dry-%d" % int(ctx.now())
    try:
        with open(current_path()) as f:
            return json.load(f).get("run") or "unknown"
    except (OSError, ValueError):
        return "unknown"


def tail(out, n=300):
    out = (out or "").strip()
    key = [l.strip() for l in out.splitlines() if "up stopped" in l or "failed (" in l or "ApiError" in l]
    if key:
        return (" | ".join(key[-3:]) + " | " + out[-n:])[-(n + 400):]
    return out[-n:]


def abort(ctx, why):
    run = (ctx.st.get("job") or {}).get("run")
    gone = down_verify(ctx, run)
    ctx.st["job"] = None
    if not gone:
        ctx.stop("boxes still listed after a failed round start: " + why, urgent=True)
        return "stopped", why
    ctx.alert("paid round failed to start", why + " (boxes deleted)", 4)
    return "failed", why


def metrics(ctx, run):
    text = ctx.store.read_text("runs/%s/metrics.jsonl" % run, "") or ""
    out = []
    for line in text.splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def last_state(lines):
    s = None
    for m in lines:
        if m.get("type") == "state":
            s = m.get("state")
    return s


def best_gen(lines, stake=None):
    per, promoted = {}, None
    for m in lines:
        if m.get("type") != "eval" or m.get("who") != "gen" or m.get("gen") is None:
            continue
        if stake is not None and int(m.get("stake") or 0) != stake:
            continue
        g = per.setdefault(m["gen"], {"n": 0, "wins": 0, "ante_sum": 0.0})
        n = int(m.get("n") or 0)
        g["n"] += n
        g["wins"] += int(m.get("wins") or 0)
        g["ante_sum"] += float(m.get("ante") or 0) * n
        if m.get("promoted"):
            promoted = m["gen"]
    if not per:
        return None
    for g, v in per.items():
        v["gen"] = g
        v["ante"] = v["ante_sum"] / v["n"] if v["n"] else 0.0
        v["rate"] = gates.rate(v["wins"], v["n"])
    if promoted is not None:
        return per[promoted]
    return max(per.values(), key=gates.score_key)


def checkpoint(ctx, run, gen):
    d = "runs/%s/checkpoints" % run
    want = "gen_%04d.bnnw" % int(gen)
    if ctx.store.exists("%s/%s" % (d, want)):
        return "%s/%s" % (d, want)
    root = ctx.store.path(d)
    if os.path.isdir(root):
        for f in sorted(os.listdir(root)):
            m = re.match(r"gen_0*(\d+)\.bnnw$", f)
            if m and int(m.group(1)) == int(gen):
                return "%s/%s" % (d, f)
    return None


def ended(ctx, job, lines):
    if dry(ctx):
        return True, "dry run"
    s = last_state(lines)
    if s in ENDED:
        return True, "job %s" % s
    if ctx.now() > job["deadline"]:
        return True, "past the deadline"
    live = boxes(ctx)
    if live == []:
        return True, "boxes gone"
    return False, s or "running"


def poll(ctx):
    job = ctx.st["job"]
    run = job.get("run")
    if not run:
        return abort_unknown(ctx)
    restore(ctx, run)
    ctx.push("poll round %s" % run)
    ctx.store.sync()
    lines = metrics(ctx, run)
    done, why = ended(ctx, job, lines)
    if not done:
        job["progress"] = {"state": why, "lines": len(lines), "t": ctx.now()}
        return None
    if ctx.now() > job["deadline"] + 600 and boxes(ctx):
        ctx.alert("round past its deadline", "round %s still had boxes 10 min after its deadline, deleting them" % run, 5)
    return finish(ctx, why, lines)


def abort_unknown(ctx):
    gone = down_verify(ctx)
    ctx.st["job"] = None
    if not gone:
        ctx.stop("a round start was interrupted and boxes are still listed", urgent=True)
        return {"ok": False, "why": "interrupted round start, boxes left", "stopped": True}
    return gates.result(False, "round start was interrupted before the run was recorded; boxes deleted")


def finish(ctx, why, lines):
    job = ctx.st["job"]
    run = job["run"]
    gone = down_verify(ctx, run)
    keep(ctx, run)
    after = spent(ctx) if not dry(ctx) else 0.0
    if after is not None and job.get("spent_before") is not None:
        cost = max(0.0, after - job["spent_before"])
    else:
        cost = job.get("round_cost_eur") or 0.0
    ctx.st["paid"]["spent_eur"] = round(max(ctx.st["paid"].get("spent_eur", 0) + cost, used(ctx.st["paid"], after)), 4)
    rec = {"run": run, "step": job["step"], "started": job["started"], "ended": ctx.now(), "cost_eur": round(cost, 4), "why": why}
    ctx.st["rounds"].append(rec)
    if not gone:
        ctx.stop("round %s ended but boxes are still listed after 3 downs" % run, urgent=True)
        return {"ok": False, "why": "boxes still listed", "stopped": True}
    ctx.alert("paid round ended", "%s: %s, %.2f EUR, boxes verified gone" % (run, why, cost), 3)
    ctx.event("round %s ended: %s, %.2f EUR, boxes gone" % (run, why, cost))
    if dry(ctx):
        return gates.result(True, "", dry=True, improved=False)
    if job["step"] == "teacher":
        return finish_teacher(ctx, run, lines)
    if job["step"] == "imitation":
        return finish_imitation(ctx, run, lines)
    if last_state(lines) in ("failed", "killed"):
        return gates.result(False, "round job %s" % last_state(lines))
    stake = ctx.st["stake"] if job["step"] == "ladder" else None
    b = best_gen(lines, stake)
    if not b:
        return gates.result(False, "round wrote no eval lines")
    rec["best"] = {k: b[k] for k in ("gen", "n", "wins", "ante", "rate")}
    path = checkpoint(ctx, run, b["gen"])
    improved = gates.improves(b, ctx.st["best"].get("score")) if job["step"] == "expert" else True
    if path and improved:
        name = "%s-%s-g%d" % (job["step"], run, int(b["gen"]))
        dst = "%s/checkpoints/%s.bnnw" % (ctx.dir, name)
        ctx.store.copy_in(ctx.store.path(path), dst)
        ctx.st["candidate"] = {"name": name, "path": dst, "score": {"ante": b["ante"], "rate": b["rate"], "wins": b["wins"], "n": b["n"]}}
    elif improved:
        return gates.result(False, "best checkpoint gen %s not found in runs/%s" % (b["gen"], run))
    return gates.result(True, "", improved=improved, best=rec["best"])


def finish_teacher(ctx, run, lines):
    t, tp = ctx.st["teacher"], ctx.prof["teacher"]
    sums = [m for m in lines if m.get("type") == "teacher"]
    if not sums:
        return gates.result(False, "teacher round %s wrote no summary (job %s)" % (run, last_state(lines)))
    m = sums[-1]
    t["leak_ok"] = bool(m.get("leak_ok"))
    games, recs = int(m.get("games") or 0), int(m.get("records") or 0)
    t["games"] += games
    t["records"] += recs
    if m.get("complete"):
        t["next"] = int(m.get("start") or t.get("next", 1)) + int(m.get("seeds") or 0)
    if recs and m.get("files"):
        t.setdefault("artifacts", []).append({"hz_run": run, "games": games, "bytes": m.get("bytes")})
    if not t["leak_ok"]:
        return gates.result(False, "leak test failed on the teacher box")
    if games == 0:
        return gates.result(False, "teacher round returned no games")
    if not m.get("complete"):
        return gates.result(False, "teacher round %s ended early (%s), %d games kept" % (run, last_state(lines), games))
    goal = steps.teacher_goal(ctx.st, tp)
    if t["games"] < goal:
        return gates.result(True, "", more=True, games=t["games"], records=t["records"])
    return gates.teacher(t["games"], t["records"], goal, t["leak_ok"])


def finish_imitation(ctx, run, lines):
    sums = [m for m in lines if m.get("type") == "imitation"]
    if not sums:
        return gates.result(False, "imitation round %s wrote no summary (job %s)" % (run, last_state(lines)))
    m = sums[-1]
    root = ctx.store.path("runs/%s/imitation" % run)
    if m.get("stopped"):
        return gates.result(False, "imitation round %s was stopped before it finished" % run)
    w = os.path.join(root, "imitation.bnnw")
    if not os.path.exists(w):
        return gates.result(False, "imitation round %s kept no checkpoint" % run)
    ctx.event("imitation on the box: %.0f samples/s on %s threads, %s s train, %.1f s/game" % (
        m.get("samples_per_s") or 0, m.get("threads"), m.get("train_secs"), m.get("sec_per_game") or 0))
    return steps.finish_imitation(ctx, root, run, wfile=w, done=m)


def watchdog(ctx):
    job = ctx.st.get("job") or {}
    if job.get("kind") != "hetzner" or not job.get("run") or dry(ctx):
        return False
    if ctx.now() <= job["deadline"] + 600:
        return False
    restore(ctx, job["run"])
    if boxes(ctx):
        ctx.alert("watchdog", "round %s alive 10 min past its deadline, deleting" % job["run"], 5)
        down_verify(ctx, job["run"])
        return True
    return False


def cleanup_start_weights():
    p = os.path.join(REPO, START_W)
    if os.path.exists(p):
        os.remove(p)
