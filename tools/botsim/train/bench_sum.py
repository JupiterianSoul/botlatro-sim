import json
import math
import sys


def load(path):
    g = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("{"):
                r = json.loads(line)
                if "seed" in r:
                    g[(r.get("deck", ""), r.get("stake", 0), r["seed"])] = r
    return g


def main():
    args = sys.argv[1:]
    base = None
    if args and args[0].startswith("--base="):
        base = load(args[0][7:])
        args = args[1:]
    for path in args:
        g = load(path)
        n = len(g)
        if n == 0:
            print(f"{path}: no games")
            continue
        antes = [r["ante"] for r in g.values()]
        wins = sum(r.get("won", 0) for r in g.values())
        early = sum(1 for r in g.values() if not r.get("won") and r["ante"] <= 2)
        sec = sum(r.get("time", 0) for r in g.values()) / n
        line = f"{path}: n {n} mean ante {sum(antes) / n:.2f} wins {wins} early {early} s/game {sec:.3f}"
        if base:
            d = [g[k]["ante"] - base[k]["ante"] for k in g if k in base]
            if len(d) > 1:
                m = sum(d) / len(d)
                sd = math.sqrt(sum((x - m) ** 2 for x in d) / (len(d) - 1))
                z = m / (sd / math.sqrt(len(d))) if sd > 0 else 0.0
                line += f" paired {m:+.2f} z {z:.1f}"
        print(line)


main()
