import glob
import json
import math
import os
import sys

IGNORE_SAME = {"time", "bl", "vl", "tch", "veto"}


def part_files(root):
    if os.path.isfile(root):
        return [root]
    files = sorted(glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True))
    out = []
    for f in files:
        d = os.path.dirname(f)
        others = [x for x in files if os.path.dirname(x) == d and x != f]
        if os.path.basename(f) in ("games.jsonl", "eval.jsonl") and others:
            continue
        out.append(f)
    return out


def load(root):
    games = {}
    st = {"files": 0, "lines": 0, "bad": 0, "dups": 0, "conflicts": 0}
    for f in part_files(root):
        st["files"] += 1
        with open(f, errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                st["lines"] += 1
                try:
                    r = json.loads(line)
                except ValueError:
                    st["bad"] += 1
                    continue
                if not isinstance(r, dict) or "seed" not in r or "won" not in r:
                    continue
                k = (r.get("deck"), r.get("stake"), r["seed"])
                if k in games:
                    st["dups"] += 1
                    if not same(games[k], r):
                        st["conflicts"] += 1
                    continue
                games[k] = r
    return games, st


def same(a, b):
    keys = (set(a) | set(b)) - IGNORE_SAME
    return all(a.get(k) == b.get(k) for k in keys)


def real_win(r):
    if not r.get("won"):
        return False
    return r.get("need", 0) == 0


def real_ante(r):
    if r.get("won") and not real_win(r):
        return r["ante"] - 1
    return r["ante"]


def has_need(games):
    return all("need" in r for r in games.values())


def stakes_of(games):
    return sorted({k[1] for k in games})


def paired(new, base):
    keys = [k for k in new if k in base]
    d = [real_ante(new[k]) - real_ante(base[k]) for k in keys]
    n = len(d)
    if n < 2:
        return {"n": n, "diff": 0.0, "z": 0.0, "same": 0}
    m = sum(d) / n
    var = sum((x - m) ** 2 for x in d) / (n - 1)
    z = m / math.sqrt(var / n) if var > 0 else 0.0
    return {"n": n, "diff": m, "z": z, "same": sum(1 for k in keys if same(new[k], base[k]))}


def summary(games):
    n = len(games)
    if not n:
        return {"n": 0, "flag": 0, "wins": 0, "ante": 0.0, "early": 0, "odd_end": 0, "time": 0.0}
    v = list(games.values())
    return {
        "n": n,
        "flag": sum(1 for r in v if r.get("won")),
        "wins": sum(1 for r in v if real_win(r)),
        "ante": sum(real_ante(r) for r in v) / n,
        "early": sum(1 for r in v if not real_win(r) and real_ante(r) <= 2),
        "odd_end": sum(1 for r in v if r.get("end", "end") != "end"),
        "time": sum(r.get("time", 0) for r in v) / n,
    }


def only_stake(games, st):
    return {k: r for k, r in games.items() if k[1] == st}


def warn(lab, st):
    if st["bad"] or st["dups"]:
        print("%s: %d unreadable lines, %d duplicate games, %d duplicates differ" % (lab, st["bad"], st["dups"], st["conflicts"]))


def cmd_summary(roots):
    for root in roots:
        lab = os.path.basename(root.rstrip("/"))
        g, st = load(root)
        warn(lab, st)
        for s in stakes_of(g):
            sub = only_stake(g, s)
            a = summary(sub)
            note = "" if has_need(sub) else " need field missing, wins not verified"
            print("%-14s st %d n %d real wins %d flag %d ante %.3f early %d odd ends %d s/g %.0f%s" % (
                lab, s, a["n"], a["wins"], a["flag"], a["ante"], a["early"], a["odd_end"], a["time"], note))
    return 0


def cmd_cmp(base_arg, roots):
    base, st = {}, None
    for b in base_arg.split(","):
        g, st = load(b)
        warn(os.path.basename(b.rstrip("/")), st)
        base.update(g)
    for root in roots:
        lab = os.path.basename(root.rstrip("/"))
        g, st = load(root)
        warn(lab, st)
        for s in stakes_of(g):
            sub = only_stake(g, s)
            bs = only_stake(base, s)
            p = paired(sub, bs)
            if p["n"] < 2:
                print(lab, s, "no base")
                continue
            keys = [k for k in sub if k in bs]
            a = summary({k: sub[k] for k in keys})
            b = summary({k: bs[k] for k in keys})
            print("%-14s st %d n %d (only new %d, only base %d) ante %.2f base %.2f real wins %d vs %d flag %d vs %d early %d vs %d paired %+.3f z %+.1f s/g %.0f same %d" % (
                lab, s, p["n"], len(sub) - p["n"], len(bs) - p["n"], a["ante"], b["ante"], a["wins"], b["wins"], a["flag"], b["flag"],
                a["early"], b["early"], p["diff"], p["z"], a["time"], p["same"]))
    return 0


def cmd_same(roots):
    ref, st = load(roots[0])
    warn(roots[0], st)
    bad = 0
    print("%s: %d games" % (roots[0], len(ref)))
    for root in roots[1:]:
        g, st = load(root)
        warn(root, st)
        missing = [k for k in ref if k not in g] + [k for k in g if k not in ref]
        diff = [k for k in ref if k in g and not same(ref[k], g[k])]
        print("%s: %d games, %d identical, %d differ, %d not in both" % (root, len(g), len(ref) - len(diff) - sum(1 for k in ref if k not in g), len(diff), len(missing)))
        for k in diff[:5]:
            keys = sorted(x for x in (set(ref[k]) | set(g[k])) - IGNORE_SAME if ref[k].get(x) != g[k].get(x) and x != "curve")
            print("  diff", k, [(x, ref[k].get(x), g[k].get(x)) for x in keys])
        bad += len(diff) + len(missing) + st["bad"] + st["conflicts"]
    print("reproduced" if bad == 0 else "NOT reproduced: %d problems" % bad)
    return 1 if bad else 0


def cmd_mklist(n, first):
    decks = ["b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula", "b_ghost", "b_abandoned", "b_checkered",
             "b_zodiac", "b_painted", "b_anaglyph", "b_plasma", "b_erratic"]
    stakes = [8, 8, 5, 2]
    for i in range(n):
        print("%s BENCH%d %d" % (decks[i % len(decks)], first + i, stakes[(i // len(decks)) % len(stakes)]))
    return 0


def main(argv):
    if len(argv) < 2:
        print("games.py summary DIR.. | cmp BASE[,BASE] DIR.. | same DIR DIR.. | mklist N FIRST")
        return 2
    cmd = argv[1]
    if cmd == "summary":
        return cmd_summary(argv[2:])
    if cmd == "cmp":
        return cmd_cmp(argv[2], argv[3:])
    if cmd == "same":
        return cmd_same(argv[2:])
    if cmd == "mklist":
        return cmd_mklist(int(argv[2]), int(argv[3]))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
