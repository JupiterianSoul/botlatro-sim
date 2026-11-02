import json
import statistics
import sys
from collections import Counter

from games import load

RESTRICT = {"bl_mouth", "bl_needle", "bl_eye", "bl_psychic", "bl_plant", "bl_final_bell", "bl_final_acorn", "bl_final_leaf"}


def real_win(g):
    return g.get("won") == 1 and g.get("need") == 0


def cause(g, tr):
    f = tr["r"][-1] if tr.get("r") else None
    if not f:
        return "no_fight"
    log = f.get("log") or []
    need = f["need"]
    best = max([x.get("best", 0) for x in log] + [0])
    four = best * max(f.get("hands", 4), 1)
    if f.get("sv") == 1 and four >= need:
        return "foresight_clears_best_hand_enough"
    if f["blind"] in RESTRICT and f.get("sv") == 0 and four >= need:
        return "boss_rule"
    if f.get("cons") and four >= need * 0.5:
        return "unused_consumable"
    if f.get("sv") == 1:
        return "foresight_clears_best_hand_short"
    if f.get("money", 0) >= 25:
        return "weak_build_money_held"
    return "weak_build_money_spent"


def main(paths):
    for root in paths:
        games, st = load(root)
        n = wins = 0
        by = Counter()
        by_ante = Counter()
        by_deck = {}
        solv = solv_n = 0
        for g in games.values():
            n += 1
            if real_win(g):
                wins += 1
                continue
            t = g.get("trace")
            tr = json.loads(t) if isinstance(t, str) else t
            if not tr:
                by["no_trace"] += 1
                continue
            c = cause(g, tr)
            by[c] += 1
            by_deck.setdefault(g["deck"], Counter())[c] += 1
            if tr.get("r"):
                f = tr["r"][-1]
                by_ante[f["ante"]] += 1
                solv_n += 1
                solv += f.get("sv", 0)
        print(f"{root}: games {n}, real wins {wins}, deaths {n - wins}")
        total = sum(by.values()) or 1
        print("| cause | deaths | share |")
        print("| --- | --- | --- |")
        for c, k in by.most_common():
            print(f"| {c} | {k} | {100 * k / total:.1f}% |")
        print(f"solver with the same deck order clears the deadly fight: {solv} of {solv_n} ({100 * solv / max(solv_n, 1):.1f}%)")
        print("deaths by ante:", " ".join(f"{a}:{by_ante[a]}" for a in sorted(by_ante)))
        for d, c in sorted(by_deck.items()):
            print(d, " ".join(f"{k}:{v}" for k, v in c.most_common()))


if __name__ == "__main__":
    main(sys.argv[1:])
