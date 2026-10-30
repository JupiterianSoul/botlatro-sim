import math
import re

LEAK_RE = re.compile(r"fair tests: (\d+) passed, (\d+) failed")


def leak(text):
    m = None
    for m in LEAK_RE.finditer(text or ""):
        pass
    if not m:
        return {"ok": False, "passed": 0, "failed": None, "why": "no leak test result line"}
    p, f = int(m.group(1)), int(m.group(2))
    return {"ok": f == 0 and p > 0, "passed": p, "failed": f, "why": "" if f == 0 and p > 0 else "%d leak tests failed" % f}


def shuffle(obj):
    if not isinstance(obj, dict):
        return {"ok": False, "games": 0, "identical": 0, "why": "no shuffle check result"}
    g, i = int(obj.get("games") or 0), int(obj.get("identical") or 0)
    ok = g > 0 and g == i
    return {"ok": ok, "games": g, "identical": i, "why": "" if ok else "%d of %d shuffled games differ" % (g - i, g)}


def all_shuffles(objs):
    if not objs:
        return shuffle(None)
    res = [shuffle(o) for o in objs]
    g = sum(r["games"] for r in res)
    i = sum(r["identical"] for r in res)
    bad = [r["why"] for r in res if not r["ok"]]
    return {"ok": not bad, "games": g, "identical": i, "why": "; ".join(bad)}


def rate(wins, n):
    return float(wins) / n if n else 0.0


def worse(wins_new, n_new, wins_base, n_base, z_crit=1.645):
    if not n_new or not n_base:
        return True
    p1, p2 = rate(wins_base, n_base), rate(wins_new, n_new)
    p = float(wins_base + wins_new) / (n_base + n_new)
    se = math.sqrt(p * (1 - p) * (1.0 / n_base + 1.0 / n_new))
    if se == 0:
        return p2 < p1
    return (p1 - p2) / se > z_crit


def result(ok, why, **extra):
    d = {"ok": bool(ok), "why": "" if ok else why}
    d.update(extra)
    return d


def fair_bench(lk, sh, white_wins, white_n, min_rate):
    if not lk["ok"]:
        return result(False, "leak test: " + lk["why"], leak=lk, shuffle=sh)
    if not sh["ok"]:
        return result(False, "shuffle check: " + sh["why"], leak=lk, shuffle=sh)
    if not white_n:
        return result(False, "no white games came back", leak=lk, shuffle=sh)
    r = rate(white_wins, white_n)
    return result(r >= min_rate, "white win rate %.1f%% under %.1f%%" % (100 * r, 100 * min_rate),
                  leak=lk, shuffle=sh, white=[white_wins, white_n])


def fair_speed(lk, sh, mean_s, max_s, wins, n, base_wins, base_n):
    if not lk["ok"]:
        return result(False, "leak test: " + lk["why"])
    if not sh["ok"]:
        return result(False, "shuffle check: " + sh["why"])
    if not n:
        return result(False, "no games came back")
    if mean_s > max_s:
        return result(False, "%.1f s per game, over %.0f" % (mean_s, max_s), mean_s=mean_s)
    if worse(wins, n, base_wins, base_n):
        return result(False, "wins %d/%d worse than baseline %d/%d" % (wins, n, base_wins, base_n), mean_s=mean_s)
    return result(True, "", mean_s=mean_s, wins=[wins, n])


def teacher(games, records, need, leak_ok):
    if not leak_ok:
        return result(False, "leak test did not pass on this commit")
    if games < need:
        return result(False, "%d of %d teacher games" % (games, need))
    if records < need:
        return result(False, "%d of %d teacher records" % (records, need))
    return result(True, "", games=games, records=records)


def imitation(mean_ante, min_ante, sh, n):
    if not n:
        return result(False, "net eval returned no games")
    if not sh["ok"]:
        return result(False, "shuffle check of the net: " + sh["why"])
    return result(mean_ante >= min_ante, "white mean ante %.2f under %.2f" % (mean_ante, min_ante), mean_ante=mean_ante)


def score_key(score):
    score = score or {}
    return (float(score.get("ante") or 0), float(score.get("rate") or 0))


def improves(new, best):
    if not new:
        return False
    if not best:
        return True
    return score_key(new) > score_key(best)


def paired(new, base):
    old = {(g["deck"], g["stake"], g["seed"]): g for g in base}
    d = [g["ante"] - old[(g["deck"], g["stake"], g["seed"])]["ante"] for g in new if (g["deck"], g["stake"], g["seed"]) in old]
    n = len(d)
    if not n:
        return {"n": 0, "diff": 0.0, "z": 0.0, "ante": 0.0, "wins": 0, "base_wins": 0}
    m = sum(d) / float(n)
    var = sum((x - m) ** 2 for x in d) / (n - 1) if n > 1 else 0.0
    if var > 0:
        z = m / math.sqrt(var / n)
    else:
        z = 99.0 if m > 0 else (-99.0 if m < 0 else 0.0)
    return {"n": n, "diff": round(m, 4), "z": round(z, 2), "ante": sum(g["ante"] for g in new) / float(len(new)),
            "wins": sum(g["won"] for g in new), "base_wins": sum(g["won"] for g in base)}


def expert_better(res, min_z, floor_z=-2.0):
    if res["both"]["n"] == 0:
        return False, "no paired games"
    if res["held"]["diff"] <= 0:
        return False, "held-out diff %+.2f not positive" % res["held"]["diff"]
    if res["gate"]["diff"] < 0:
        return False, "gate diff %+.2f negative" % res["gate"]["diff"]
    if res["both"]["z"] < min_z:
        return False, "gate and held-out z %.2f under %.2f" % (res["both"]["z"], min_z)
    bad = [k for k in sorted(res) if k.startswith("stake") and res[k]["z"] < floor_z]
    if bad:
        return False, "loses on " + ", ".join(bad)
    return True, "better: %+.2f, z %.2f" % (res["both"]["diff"], res["both"]["z"])


def promote(wins, n, need_rate):
    return n > 0 and rate(wins, n) >= need_rate
