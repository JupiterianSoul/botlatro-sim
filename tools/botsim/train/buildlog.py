import json
import sys
from collections import defaultdict

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import games as G


def rows(r):
    out = []
    for part in (r.get("bl") or "").split(","):
        f = part.split(":")
        if len(f) == 5:
            out.append(tuple(int(x) for x in f))
    return out


def table(games):
    by = defaultdict(lambda: [0, 0, 0, 0, 0])
    for r in games:
        rs = rows(r)
        for i, (a, n, top, money, uses) in enumerate(rs[:-1]):
            if rs[i + 1][0] == a and i + 2 < len(rs):
                continue
            t = by[a]
            t[0] += 1
            t[1] += n
            t[2] += top
            t[3] += money
            t[4] += rs[i + 1][4] - uses
    lines = ["ante  games  deck  top_lv  money  uses_in_ante"]
    for a in sorted(by):
        t = by[a]
        k = t[0]
        lines.append("%4d  %5d  %5.1f  %5.2f  %5.1f  %5.2f" % (a, k, t[1] / k, t[2] / k, t[3] / k, t[4] / k))
    return "\n".join(lines)


def teacher(games):
    n, fb = defaultdict(int), defaultdict(int)
    for r in games:
        t = r.get("tch") or {}
        for k, v in (t.get("n") or {}).items():
            n[k] += v
        for k, v in (t.get("fb") or {}).items():
            fb[k] += v
    g = max(1, len(games))
    a = ", ".join("%s %.2f" % (k, n[k] / g) for k in sorted(n))
    b = ", ".join("%s %.1f" % (k, fb[k] / g) for k in sorted(fb))
    return "teacher moves per game: " + (a or "none") + "\nfallbacks per game: " + (b or "none")


def main(argv):
    for root in argv[1:]:
        games = list(G.load(root)[0].values())
        print("==", root, len(games), "games")
        print(table(games))
        print(teacher(games))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
