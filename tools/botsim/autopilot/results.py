import argparse
import json
import math
import sys
import time


def parse_games(paths):
    games = []
    for p in paths:
        try:
            fh = open(p, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(d, dict) or "deck" not in d or "won" not in d:
                    continue
                games.append({
                    "deck": d["deck"],
                    "stake": int(d.get("stake", 1)),
                    "seed": d.get("seed"),
                    "won": 1 if d["won"] else 0,
                    "ante": int(d.get("ante", 0)),
                    "time": float(d.get("time", 0.0)),
                })
    return games


def aggregate(games, t=None, step="", checkpoint="", who="", set="", fair=False, ci_run=None):
    cells = {}
    for g in games:
        k = (g["deck"], g["stake"])
        c = cells.setdefault(k, {"n": 0, "wins": 0, "ante_sum": 0, "time_sum": 0.0})
        c["n"] += 1
        c["wins"] += g["won"]
        c["ante_sum"] += g["ante"]
        c["time_sum"] += g["time"]
    rows = []
    for (deck, stake) in sorted(cells):
        c = cells[(deck, stake)]
        rows.append({
            "t": int(time.time()) if t is None else t, "step": step, "checkpoint": checkpoint, "who": who,
            "set": set, "deck": deck, "stake": stake, "n": c["n"], "wins": c["wins"],
            "ante_sum": c["ante_sum"], "time_sum": round(c["time_sum"], 2), "fair": bool(fair), "ci_run": ci_run,
        })
    return rows


def wilson(wins, n, z=1.96):
    if n <= 0:
        return (0.0, 0.0)
    p = wins / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, (c - h) / d), min(1.0, (c + h) / d))


def win_rate(rows, stake=None):
    wins = n = 0
    for r in rows:
        if stake is None or r["stake"] == stake:
            wins += r["wins"]
            n += r["n"]
    return (wins, n)


def pct(wins, n):
    if n <= 0:
        return "n/a"
    lo, hi = wilson(wins, n)
    return "%.1f%% (%.1f to %.1f)" % (100 * wins / n, 100 * lo, 100 * hi)


def line(r, label):
    n = r["n"]
    ante = "%.2f" % (r["ante_sum"] / n) if n else "n/a"
    spg = "%.1f" % (r["time_sum"] / n) if n else "n/a"
    return "| %s | %s | %d | %d | %s | %s | %s |" % (label, r["stake"], n, r["wins"], pct(r["wins"], n), ante, spg)


def merge(rows):
    out = {}
    for r in rows:
        k = (r["checkpoint"], r["who"], r["set"], r["deck"], r["stake"], bool(r.get("fair")))
        m = out.get(k)
        if m is None:
            out[k] = dict(r)
        else:
            for f in ("n", "wins", "ante_sum", "time_sum"):
                m[f] += r[f]
    return list(out.values())


def table(rows):
    out = ["| deck | stake | n | wins | win % (95% CI) | mean ante | s/game |", "| --- | --- | --- | --- | --- | --- | --- |"]
    rows = sorted(rows, key=lambda r: (r["stake"], r["deck"]))
    for r in rows:
        out.append(line(r, r["deck"]))
    for st in sorted({r["stake"] for r in rows}):
        sub = [r for r in rows if r["stake"] == st]
        tot = {"stake": st, "n": sum(r["n"] for r in sub), "wins": sum(r["wins"] for r in sub),
               "ante_sum": sum(r["ante_sum"] for r in sub), "time_sum": sum(r["time_sum"] for r in sub)}
        out.append(line(tot, "**overall**"))
    return out


def render(state, rows):
    state = state or {}
    paid = state.get("paid", {})
    head = "step %s, status %s" % (state.get("step", "n/a"), state.get("status", "n/a"))
    if state.get("reason"):
        head += " (%s)" % state["reason"]
    head += ", spent %s of %s EUR approved" % (paid.get("spent_eur", 0), paid.get("approved_eur", 0))
    upd = state.get("updated")
    if upd:
        head += ", updated " + time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(upd))
    out = ["# Bot-latro autopilot results", "", head, ""]
    rows = merge(rows or [])
    counted = [r for r in rows if r["fair"]]
    skipped = [r for r in rows if not r["fair"]]
    groups = {}
    for r in counted:
        groups.setdefault((r["checkpoint"], r["who"], r["set"]), []).append(r)
    for (ck, who, st), grp in sorted(groups.items()):
        out += ["## %s (%s, %s)" % (ck, who, st), ""] + table(grp) + [""]
    best = None
    best_rate = -1.0
    for key, grp in groups.items():
        w, n = win_rate(grp)
        if n and w / n > best_rate:
            best, best_rate = key, w / n
    out += ["## Board", ""]
    if best is None:
        out += ["No fair checkpoint measured yet.", ""]
    else:
        grp = groups[best]
        stakes = sorted({r["stake"] for r in grp})
        decks = sorted({r["deck"] for r in grp})
        cell = {(r["deck"], r["stake"]): r for r in grp}
        out += ["Best fair checkpoint: %s (%s, %s)" % best, ""]
        out += ["| deck | " + " | ".join("stake %d" % s for s in stakes) + " |", "| --- |" + " --- |" * len(stakes)]
        for d in decks:
            cs = []
            for s in stakes:
                r = cell.get((d, s))
                cs.append("%.0f%% (%d)" % (100 * r["wins"] / r["n"], r["n"]) if r and r["n"] else "-")
            out.append("| %s | %s |" % (d, " | ".join(cs)))
        out.append("")
    out += ["## Not counted", ""]
    if not skipped:
        out += ["Nothing."]
    else:
        seen = {}
        for r in skipped:
            k = (r["checkpoint"], r["who"], r["set"])
            seen[k] = seen.get(k, 0) + r["n"]
        for (ck, who, st), n in sorted(seen.items()):
            out.append("- %s (%s, %s): %d games, leak or shuffle check not passed" % (ck, who, st, n))
    out.append("")
    return "\n".join(out)


def read_rows(path):
    rows = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return rows
    with fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                try:
                    rows.append(json.loads(ln))
                except ValueError:
                    pass
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(prog="results.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("--state", required=True)
    r.add_argument("--rows", required=True)
    r.add_argument("--out", required=True)
    i = sub.add_parser("ingest")
    i.add_argument("--checkpoint", required=True)
    i.add_argument("--who", required=True)
    i.add_argument("--step", default="")
    i.add_argument("--set", dest="set_", default="BENCH")
    i.add_argument("--fair", type=int, default=0)
    i.add_argument("--ci-run", type=int, default=None)
    i.add_argument("files", nargs="+")
    a = ap.parse_args(argv)
    if a.cmd == "render":
        try:
            state = json.load(open(a.state, encoding="utf-8"))
        except (OSError, ValueError):
            state = {}
        text = render(state, read_rows(a.rows))
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text)
        return 0
    rows = aggregate(parse_games(a.files), step=a.step, checkpoint=a.checkpoint, who=a.who, set=a.set_,
                     fair=bool(a.fair), ci_run=a.ci_run)
    for row in rows:
        print(json.dumps(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
