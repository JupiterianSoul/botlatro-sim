import glob
import json
import math
import sys
from collections import defaultdict

HAND_JOKER = {
    "j_jolly": "Pair", "j_sly": "Pair", "j_duo": "Pair",
    "j_zany": "Three of a Kind", "j_wily": "Three of a Kind", "j_trio": "Three of a Kind",
    "j_mad": "Two Pair", "j_clever": "Two Pair", "j_trousers": "Two Pair",
    "j_family": "Four of a Kind",
    "j_crazy": "Straight", "j_devious": "Straight", "j_order": "Straight", "j_runner": "Straight", "j_superposition": "Straight",
    "j_droll": "Flush", "j_crafty": "Flush", "j_tribe": "Flush",
    "j_seance": "Straight Flush",
}
CONTAINS = {
    "Pair": {"Pair", "Two Pair", "Three of a Kind", "Full House", "Four of a Kind", "Five of a Kind", "Flush House", "Flush Five"},
    "Two Pair": {"Two Pair", "Full House", "Flush House"},
    "Three of a Kind": {"Three of a Kind", "Full House", "Four of a Kind", "Five of a Kind", "Flush House", "Flush Five"},
    "Four of a Kind": {"Four of a Kind", "Five of a Kind", "Flush Five"},
    "Straight": {"Straight", "Straight Flush"},
    "Flush": {"Flush", "Straight Flush", "Flush House", "Flush Five"},
    "Straight Flush": {"Straight Flush"},
}


def load(globs):
    runs = []
    for g in globs:
        for f in sorted(glob.glob(g)):
            for line in open(f):
                d = json.loads(line)
                if "jl" not in d:
                    continue
                final = d["ante"] + (1 if d["won"] else 0)
                rows = {r["a"]: r for r in d["jl"]}
                runs.append({"deck": d["deck"], "final": final, "real": d["won"] == 1 and d["need"] == 0, "rows": rows})
    return runs


def matched(entry, holds, ok):
    by_deck = defaultdict(lambda: [0, 0])
    for r in entry:
        if not holds(r):
            x = by_deck[r["deck"]]
            x[0] += 1
            x[1] += ok(r)
    n, obs, exp, var = 0, 0, 0.0, 0.0
    for r in entry:
        if holds(r):
            x = by_deck[r["deck"]]
            if x[0] == 0:
                continue
            p = x[1] / x[0]
            n += 1
            obs += ok(r)
            exp += p
            var += p * (1 - p)
    z = (obs - exp) / math.sqrt(var) if var > 0 else 0.0
    return n, obs, exp, z


def njok(r, ante):
    return min(len(r["rows"][ante]["j"]), 5)


def ante_value(entry, ante, holds, shrink):
    by = defaultdict(lambda: [0, 0.0])
    for r in entry:
        if not holds(r):
            x = by[(r["deck"], njok(r, ante))]
            x[0] += 1
            x[1] += r["final"]
    n, d = 0, 0.0
    for r in entry:
        if holds(r):
            x = by[(r["deck"], njok(r, ante))]
            if x[0] < 3:
                continue
            n += 1
            d += r["final"] - x[1] / x[0]
    if n == 0:
        return 0, 0.0
    return n, d / n * n / (n + shrink)


def write_tab(runs, path, mn):
    out = []
    for ante in range(3, 7):
        entry = [r for r in runs if ante in r["rows"]]
        keys = lambda r, a=ante: {k.split(":")[0] for k in r["rows"][a]["j"]}
        top = lambda r, a=ante: r["rows"][a]["t"]
        count = defaultdict(int)
        for r in entry:
            for k in keys(r):
                count[k] += 1
        single = {}
        for k, c in sorted(count.items()):
            if c < mn:
                continue
            n, v = ante_value(entry, ante, lambda r, k=k: k in keys(r), 50)
            single[k] = v
            out.append("J %d %s %.4f %d" % (ante, k, v, n))
            h = HAND_JOKER.get(k)
            if h:
                nf, vf = ante_value(entry, ante, lambda r, k=k: k in keys(r) and top(r) in CONTAINS[h], 50)
                no, vo = ante_value(entry, ante, lambda r, k=k: k in keys(r) and top(r) not in CONTAINS[h], 50)
                if nf >= mn // 2:
                    out.append("F %d %s %.4f %d" % (ante, k, vf, nf))
                if no >= mn // 2:
                    out.append("O %d %s %.4f %d" % (ante, k, vo, no))
        pairs = defaultdict(int)
        for r in entry:
            ks = sorted(k for k in keys(r) if k in single)
            for x in range(len(ks)):
                for y in range(x + 1, len(ks)):
                    pairs[(ks[x], ks[y])] += 1
        for (a, b), c in sorted(pairs.items()):
            if c < mn:
                continue
            n, v = ante_value(entry, ante, lambda r, a=a, b=b: a in keys(r) and b in keys(r), 100)
            out.append("P %d %s %s %.4f %d" % (ante, a, b, (v - single[a] - single[b]) * n / (n + 100), n))
    open(path, "w").write("\n".join(out) + "\n")
    return len(out)


def main(argv):
    if len(argv) < 2:
        print("jokers.py GLOB... [--ante 4] [--min 30] [--out FILE] [--tab FILE]  (joker held entering the ante against runs without it, matched by deck: share that get through the next two antes)")
        return 2
    ante, mn, out, tab, globs = 4, 30, None, None, []
    i = 1
    while i < len(argv):
        if argv[i] == "--ante":
            ante, i = int(argv[i + 1]), i + 2
        elif argv[i] == "--min":
            mn, i = int(argv[i + 1]), i + 2
        elif argv[i] == "--out":
            out, i = argv[i + 1], i + 2
        elif argv[i] == "--tab":
            tab, i = argv[i + 1], i + 2
        else:
            globs.append(argv[i])
            i += 1
    runs = load(globs)
    if tab:
        print("table lines", write_tab(runs, tab, mn), "in", tab)
    entry = [r for r in runs if ante in r["rows"]]
    goal = ante + 3
    ok = lambda r: 1 if r["final"] >= goal else 0
    lines = []
    lines.append("runs %d, entering ante %d: %d, through ante %d: %d (%.3f)" % (len(runs), ante, len(entry), ante + 2, sum(ok(r) for r in entry), sum(ok(r) for r in entry) / max(len(entry), 1)))
    keys = lambda r: {k.split(":")[0] for k in r["rows"][ante]["j"]}
    count = defaultdict(int)
    for r in entry:
        for k in keys(r):
            count[k] += 1
    table = []
    for k, c in count.items():
        if c < mn:
            continue
        n, obs, exp, z = matched(entry, lambda r, k=k: k in keys(r), ok)
        if n:
            table.append((z, k, n, obs / n, exp / n))
    table.sort(reverse=True)
    lines.append("")
    lines.append("joker held entering ante %d (at least %d runs): runs, through ante %d with it, matched rate without it, difference, z" % (ante, mn, ante + 2))
    for z, k, n, a, b in table:
        lines.append("%-22s %5d  %.3f  %.3f  %+.3f  z %+5.2f" % (k, n, a, b, a - b, z))
    pairs = defaultdict(int)
    for r in entry:
        ks = sorted(keys(r))
        for x in range(len(ks)):
            for y in range(x + 1, len(ks)):
                pairs[(ks[x], ks[y])] += 1
    ptab = []
    for (a, b), c in pairs.items():
        if c < mn:
            continue
        n, obs, exp, z = matched(entry, lambda r, a=a, b=b: a in keys(r) and b in keys(r), ok)
        single = []
        for k in (a, b):
            n1, o1, e1, _ = matched(entry, lambda r, k=k: k in keys(r), ok)
            single.append(o1 / n1 if n1 else 0)
        if n:
            ptab.append((z, a, b, n, obs / n, exp / n, max(single)))
    ptab.sort(reverse=True)
    lines.append("")
    lines.append("pairs held together entering ante %d (at least %d runs): runs, through ante %d, matched rate without the pair, z, best single holder rate" % (ante, mn, ante + 2))
    for z, a, b, n, x, e, s in ptab:
        lines.append("%-18s %-18s %5d  %.3f  %.3f  z %+5.2f  single %.3f" % (a, b, n, x, e, z, s))
    lines.append("")
    lines.append("hand jokers against the top hand (highest level, ties by plays) at each ante entered: held, matching, share")
    for a in range(2, 9):
        held = match = 0
        for r in runs:
            row = r["rows"].get(a)
            if not row:
                continue
            for k in row["j"]:
                h = HAND_JOKER.get(k.split(":")[0])
                if h:
                    held += 1
                    match += row["t"] in CONTAINS[h]
        if held:
            lines.append("ante %d  %5d  %5d  %.3f" % (a, held, match, match / held))
    text = "\n".join(lines)
    print(text)
    if out:
        open(out, "w").write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
