import gzip
import json
import math
import os

import ci
import gates

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
PART_BYTES = 40 * 1024 * 1024
SLICES = 4
CI_STEPS = ("fair_bench", "fair_speed", "teacher", "imitation")
PAID_STEPS = ("expert", "ladder")
FLAG_OF = {"fair_speed": "fair_speed_ok", "expert": "expert_ok", "ladder": "expert_ok"}


def on_hetzner(prof, step, st=None):
    if step == "teacher" and ((st or {}).get("teacher") or {}).get("ci"):
        return False
    return step in ("teacher", "imitation") and bool((prof.get(step) or {}).get("paid"))


def teacher_goal(st, tp):
    return int((st.get("teacher") or {}).get("target") or tp["games"])


def store_teacher(store, src, rel, i):
    with open(src, "rb") as f:
        blob = gzip.compress(f.read(), 6)
    for k in range(max(1, int(math.ceil(len(blob) / float(PART_BYTES))))):
        store.write_bytes("%s/w%03d.bspr.gz.%03d" % (rel, i, k), blob[k * PART_BYTES:(k + 1) * PART_BYTES])
    return len(blob)


def job(label, cmd, timeout, torch=False):
    return {"label": label, "cmd": cmd, "torch": torch, "timeout": int(timeout)}


def quiet(cmd, log):
    return "%s > $OUT/%s 2>&1 || true" % (cmd, log)


def leak_cmd(prof):
    return quiet("luajit tools/botsim/seer/test/fair_test.lua %s" % prof.get("leak_args", ""), "leak.txt").replace("  ", " ")


def shuffle_cmd(prof, who, weights=None, args=""):
    s = prof["shuffle"]
    w = " weights=%s sims=0" % weights if weights else ""
    w += " " + args if args else ""
    return quiet("luajit tools/botsim/seer/fair_shuffle.lua who=%s budget=lite%s prefix=%s first=1 seeds=%d decks=%s stakes=%s max_steps=%d out=$OUT/shuffle.json"
                 % (who, w, prof["bench"]["prefix"], s["seeds"], s["decks"], s["stakes"], s["max_steps"]), "shuffle.txt")


def fetch_cmd(dir_, name):
    return "python3 tools/botsim/autopilot/store.py fetch %s/checkpoints/%s.bnnw ckpt/%s.bnnw" % (dir_, name, name)


def bench_jobs(prof, cells, extra=""):
    b = prof["bench"]
    out = []
    for cell in b["cells"]:
        if cells and cell["name"] not in cells:
            continue
        per = max(1, int(b["per_job"]))
        for i in range(int(math.ceil(cell["seeds"] / float(per)))):
            first = 1 + i * per
            n = min(per, cell["seeds"] - i * per)
            cmd = "luajit tools/botsim/seer/fair.lua budget=%s prefix=%s first=%d seeds=%d decks=%s stakes=%s run_cap=%d jobs=$CORES%s out=$OUT/games.jsonl" % (
                b["budget"], b["prefix"], first, n, cell["decks"], cell["stakes"], b.get("run_cap", 0), extra)
            out.append(job("%s-%d" % (cell["name"], i + 1), quiet(cmd, "bench.txt"), b["timeout"]))
    return out


def check_jobs(prof, who="fair", weights=None, pre=""):
    t = prof.get("paid", {}).get("precheck_timeout") or prof["bench"]["timeout"]
    sh = shuffle_cmd(prof, who, weights)
    return [job("leak", leak_cmd(prof), t), job("shuffle", (pre + " && " if pre else "") + sh, t)]


def all_decks():
    try:
        with open(os.path.join(REPO, "tools", "botsim", "bench", "seeds.json")) as f:
            return json.load(f)["decks"]
    except (OSError, ValueError, KeyError):
        return ["b_red"]


def jobs_for(ctx, step, phase):
    st, prof = ctx.st, ctx.prof
    if step == "fair_bench":
        return bench_jobs(prof, None) + check_jobs(prof)
    if step == "fair_speed":
        fs = prof["fair_speed"]
        return bench_jobs(prof, fs["cells"], (" " + fs["args"]) if fs.get("args") else "") + check_jobs(prof)
    if step == "teacher":
        return teacher_jobs(ctx)
    if step == "imitation":
        return imitation_jobs(ctx)
    if phase in ("precheck", "verify"):
        name = st["best"]["name"] if phase == "precheck" else (st.get("candidate") or {}).get("name")
        if not name:
            return check_jobs(prof)
        return check_jobs(prof, "net", "ckpt/%s.bnnw" % name, fetch_cmd(ctx.dir, name))
    if phase == "final":
        return final_jobs(ctx)
    raise ValueError("no CI work for %s %s" % (step, phase))


def teacher_jobs(ctx):
    t, tp = ctx.st["teacher"], ctx.prof["teacher"]
    left = teacher_goal(ctx.st, tp) - t["games"]
    if left <= 0:
        return []
    per = max(1, int(tp["per_job"]))
    n = min(int(tp["max_jobs"]), int(math.ceil(left / float(per))))
    start = t.get("next", 1)
    out = []
    for i in range(n):
        k = min(per, left - i * per)
        if k <= 0:
            break
        stop = " stop_ante=%d" % tp["stop_ante"] if tp.get("stop_ante") else ""
        base = "luajit tools/botsim/seer/teacher.lua mode=fair budget=%s prefix=%s decks=%s stakes=%s%s" % (tp["budget"], tp["prefix"], tp["decks"], tp["stakes"], stop)
        q = int(math.ceil(k / float(SLICES)))
        parts = []
        for j in range(SLICES):
            n = min(q, k - j * q)
            if n <= 0:
                break
            parts.append("%s start=%d seeds=%d out=$OUT/teach%d.bspr jsonl=$OUT/games%d.jsonl > $OUT/teacher%d.txt 2>&1 &" % (base, start + i * per + j * q, n, j, j, j))
        cmd = " ".join(parts) + " wait; cat $OUT/games[0-9]*.jsonl > $OUT/games.jsonl || true"
        out.append(job("t%d" % (i + 1), cmd, tp["timeout"]))
    if not t.get("leak_ok"):
        out.append(job("leak", leak_cmd(ctx.prof), tp["timeout"]))
    return out


def imitation_jobs(ctx):
    ip, b = ctx.prof["imitation"], ctx.prof["bench"]
    dl = []
    for a in ctx.st["teacher"].get("artifacts", []):
        if a.get("hz_run"):
            dl.append("python3 tools/botsim/autopilot/store.py fetchdir runs/%s/teacher data/%s && for f in data/%s/w*.bspr.gz.000; do cat \"${f%%.000}\".* | gunzip > \"${f%%.gz.000}\"; done || true" % (a["hz_run"], a["hz_run"], a["hz_run"]))
        else:
            dl.append("gh run download %s -p '%s-t*' -D data/%s || true" % (a["run"], a["tag"], a["run"]))
    w = "$OUT/imitation.bnnw"
    extra = " --all-discards %d" % ip["all_discards"] if ip.get("all_discards") else ""
    if "window" in ip:
        extra += " --window %d" % ip["window"]
    if ip.get("cfg"):
        extra += " --cfg %s" % ip["cfg"]
    if ip.get("chosen"):
        extra += " --chosen %g" % ip["chosen"]
    if ip.get("value_weight") is not None:
        extra += " --value-weight %g" % ip["value_weight"]
    train = quiet("python3 tools/botsim/train/train.py --data $(find data -name '*.bspr' -size +0c) --out %s --steps %d%s" % (w, ip["steps"], extra), "train.txt")
    ea = ip.get("eval_args", "")
    ev = quiet("luajit tools/botsim/train/eval.lua who=net weights=%s sims=0 prefix=%s first=1 seeds=%d decks=%s stakes=%s jsonl=$OUT/games.jsonl%s"
               % (w, b["prefix"], ip["eval_seeds"], ip["decks"], ip["stakes"], " " + ea if ea else ""), "eval.txt")
    sh = shuffle_cmd(ctx.prof, "net", w, ea)
    cmd = "; ".join(["mkdir -p data"] + dl + [train, ev, sh])
    return [job("imitation", cmd, ip["timeout"], torch=True)]


def final_jobs(ctx):
    lp, b = ctx.prof["ladder"], ctx.prof["bench"]
    name = ctx.st["best"]["name"]
    out = []
    for d in all_decks():
        w = "ckpt/%s.bnnw" % name
        ev = quiet("luajit tools/botsim/train/eval.lua who=net weights=%s sims=0 prefix=%s first=1 seeds=%d decks=%s stakes=1,2,3,4,5,6,7,8 jsonl=$OUT/games.jsonl"
                   % (w, b["prefix"], lp.get("final_seeds", 30), d), "eval.txt")
        out.append(job("final-%s" % d, fetch_cmd(ctx.dir, name) + " && " + ev, lp.get("final_timeout", 330)))
    return out


def checks(root):
    lk = gates.leak("\n".join(ci.read_all(ci.files(root, "leak.txt"))))
    sh = gates.all_shuffles(ci.read_jsons(ci.files(root, "shuffle.json")))
    return lk, sh


def games_of(ctx, root):
    return ctx.res.parse_games(ci.files(root, "games.jsonl"))


def white(games, stake=1):
    g = [x for x in games if int(x.get("stake") or 0) == stake]
    return sum(1 for x in g if x.get("won")), len(g), sum(float(x.get("ante") or 0) for x in g)


def finish(ctx, step, phase, root, run_id):
    if step == "fair_bench":
        return finish_bench(ctx, root, run_id)
    if step == "fair_speed":
        return finish_speed(ctx, root, run_id)
    if step == "teacher":
        return finish_teacher(ctx, root, run_id)
    if step == "imitation":
        return finish_imitation(ctx, root, run_id)
    if phase in ("precheck", "verify"):
        lk, sh = checks(root)
        ok = lk["ok"] and sh["ok"]
        return gates.result(ok, "leak test: %s; shuffle check: %s" % (lk["why"] or "ok", sh["why"] or "ok"), leak=lk, shuffle=sh)
    if phase == "final":
        games = games_of(ctx, root)
        ctx.add_rows(ctx.res.aggregate(games, t=ctx.now(), step="ladder", checkpoint=ctx.st["best"]["name"], who="net",
                                       set="BENCH", fair=bool(ctx.st.get("leak_ok") and ctx.st.get("prechecked") == ctx.st["best"]["name"]), ci_run=run_id))
        return gates.result(bool(games), "final benchmark returned no games")
    raise ValueError(step)


def finish_bench(ctx, root, run_id):
    lk, sh = checks(root)
    games = games_of(ctx, root)
    fair = lk["ok"] and sh["ok"]
    ctx.add_rows(ctx.res.aggregate(games, t=ctx.now(), step="fair_bench", checkpoint="fair-seer-lite", who="fair_lite",
                                   set="BENCH", fair=fair, ci_run=run_id))
    w, n, _ = white(games)
    t = sum(float(x.get("time") or 0) for x in games if int(x.get("stake") or 0) == 1)
    ctx.st["baseline"] = {"white": [w, n], "time_sum": t}
    ctx.st["leak_ok"] = lk["ok"]
    return gates.fair_bench(lk, sh, w, n, ctx.prof["bench"]["min_white_rate"])


def finish_speed(ctx, root, run_id):
    lk, sh = checks(root)
    games = games_of(ctx, root)
    ctx.add_rows(ctx.res.aggregate(games, t=ctx.now(), step="fair_speed", checkpoint="fair-seer-fast", who="fair_fast",
                                   set="BENCH", fair=lk["ok"] and sh["ok"], ci_run=run_id))
    w, n, _ = white(games)
    t = [float(x.get("time") or 0) for x in games if int(x.get("stake") or 0) == 1]
    mean = sum(t) / len(t) if t else 0.0
    base = ctx.st.get("baseline") or {}
    bw, bn = base.get("white") or [0, 0]
    return gates.fair_speed(lk, sh, mean, speed_limit(ctx.prof["fair_speed"], base), w, n, bw, bn)


def speed_limit(fs, base):
    if fs.get("max_ratio"):
        bn = (base.get("white") or [0, 0])[1]
        if not bn:
            return 0.0
        return fs["max_ratio"] * float(base.get("time_sum") or 0) / bn
    return fs["max_s"]


def finish_teacher(ctx, root, run_id):
    t, tp = ctx.st["teacher"], ctx.prof["teacher"]
    run = "ci-%s" % run_id
    games = recs = files = size = 0
    for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        p = os.path.join(root, d)
        g = len(ctx.res.parse_games(ci.files(p, "games.jsonl")))
        games += g
        kept = 0
        for f in sorted(os.listdir(p)) if g and os.path.isdir(p) else []:
            b = os.path.join(p, f)
            if f.startswith("teach") and f.endswith(".bspr") and os.path.getsize(b) > 0:
                size += store_teacher(ctx.store, b, "runs/%s/teacher" % run, files)
                files += 1
                kept += 1
        if kept:
            recs += g
    lk = gates.leak("\n".join(ci.read_all(ci.files(root, "leak.txt"))))
    if lk["failed"] is not None:
        t["leak_ok"] = lk["ok"]
    t["games"] += games
    t["records"] += recs
    t["next"] = t.get("next", 1) + sum(1 for j in ctx.st["job"]["jobs"] if j["label"].startswith("t")) * int(tp["per_job"])
    if recs:
        t.setdefault("artifacts", []).append({"hz_run": run, "games": recs, "bytes": size})
    if games == 0:
        return gates.result(False, "teacher batch returned no games")
    goal = teacher_goal(ctx.st, tp)
    if t["games"] < goal:
        return gates.result(True, "", more=True)
    return gates.teacher(t["games"], t["records"], goal, t.get("leak_ok"))


def finish_imitation(ctx, root, run_id, run=None, wfile=None, done=None):
    lk, sh = checks(root)
    games = games_of(ctx, root)
    if done is not None and not done.get("leak_ok"):
        return gates.result(False, "leak test failed on the imitation box")
    fair = bool(sh["ok"] and ctx.st.get("leak_ok"))
    ctx.add_rows(ctx.res.aggregate(games, t=ctx.now(), step="imitation", checkpoint="imitation", who="net",
                                   set="BENCH", fair=fair, ci_run=run_id))
    w, n, ante = white(games)
    mean = ante / n if n else 0.0
    ws = [wfile] if wfile else ci.files(root, "imitation.bnnw")
    if ws and sh["ok"]:
        ctx.store.copy_in(ws[0], "%s/checkpoints/imitation.bnnw" % ctx.dir)
        ctx.st["best"] = {"name": "imitation", "path": "%s/checkpoints/imitation.bnnw" % ctx.dir,
                          "score": {"ante": mean, "rate": gates.rate(w, n)}}
        ctx.st["prechecked"] = "imitation"
    elif not ws:
        return gates.result(False, "training produced no checkpoint")
    return gates.imitation(mean, ctx.prof["imitation"]["min_ante"], sh, n)
