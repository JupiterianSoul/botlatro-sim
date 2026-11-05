import glob
import json
import statistics
import sys


def rows(pattern):
    out = {}
    for path in sorted(glob.glob(pattern)):
        for line in open(path):
            line = line.strip()
            if not line.startswith("{"):
                continue
            g = json.loads(line)
            out[(g["deck"], g["stake"], g["seed"])] = g
    return out


def per_ante(games, antes):
    t = {a: {"n": 0, "money": [], "deck": [], "top": [], "uses": []} for a in antes}
    for g in games.values():
        seen = set()
        for part in (g.get("bl") or "").split(","):
            f = part.split(":")
            if len(f) < 5:
                continue
            a = int(f[0])
            if a in t and a not in seen:
                seen.add(a)
                t[a]["n"] += 1
                t[a]["deck"].append(int(f[1]))
                t[a]["top"].append(int(f[2]))
                t[a]["money"].append(int(f[3]))
                t[a]["uses"].append(int(f[4]))
    return t


PLANETS = set("c_mercury c_venus c_earth c_mars c_jupiter c_saturn c_uranus c_neptune c_pluto c_planet_x c_ceres c_eris".split())


def vl_ante(games, a):
    R = [r for g in games.values() for r in g.get("vl", []) if r["ante"] == a and "enh" in r]
    if not R:
        return None
    n = len(R)
    m = lambda f: sum(f(r) for r in R) / n
    return "  ante %d  vl %4d  planets used %.2f  tarots used %.2f  telescope %.2f  observatory %.2f  planets held %.2f  glass %.2f  steel %.2f  lucky %.2f  mult %.2f  bonus %.2f  other enh %.2f  red seal %.2f  other seal %.2f  poly %.2f  foil/holo %.2f" % (
        a, n, m(lambda r: r["pu"]), m(lambda r: r["tu"]), m(lambda r: "v_telescope" in r["v"]), m(lambda r: "v_observatory" in r["v"]),
        m(lambda r: sum(1 for c in r["cons"] if c in PLANETS)), m(lambda r: r["enh"][3]), m(lambda r: r["enh"][4]), m(lambda r: r["enh"][7]),
        m(lambda r: r["enh"][1]), m(lambda r: r["enh"][0]), m(lambda r: r["enh"][2] + r["enh"][5] + r["enh"][6]), m(lambda r: r["seal"][1]),
        m(lambda r: r["seal"][0] + r["seal"][2] + r["seal"][3]), m(lambda r: r["ced"][2]), m(lambda r: r["ced"][0] + r["ced"][1]))


def main(argv):
    if len(argv) < 2:
        print("build.py GLOB [GLOB ...]  (per ante entered: games, median money, share with $25+, mean deck size, share under 50 cards, mean top hand level, mean consumables used so far; with vlog=1 games also planets and tarots used, Telescope and Observatory, enhanced cards, seals and card editions)")
        return 2
    antes = [2, 3, 4, 5, 6]
    sets = [rows(p) for p in argv[1:]]
    common = set(sets[0])
    for s in sets[1:]:
        common &= set(s)
    print("common games", len(common))
    for p, s in zip(argv[1:], sets):
        t = per_ante({k: s[k] for k in common}, antes)
        print(p)
        for a in antes:
            r = t[a]
            if r["n"] == 0:
                continue
            m = r["money"]
            d = r["deck"]
            print("  ante %d  n %4d  money %5.1f  $25+ %.2f  deck %5.1f  <50 %.2f  top %.2f  uses %.2f" % (
                a, r["n"], statistics.median(m), sum(1 for x in m if x >= 25) / len(m),
                statistics.mean(d), sum(1 for x in d if x < 50) / len(d),
                statistics.mean(r["top"]), statistics.mean(r["uses"])))
        for a in antes + [7, 8]:
            v = vl_ante({k: s[k] for k in common}, a)
            if v:
                print(v)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
