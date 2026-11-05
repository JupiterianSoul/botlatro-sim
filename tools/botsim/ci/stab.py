import sys, glob, json, math, re
meta = {}
for m in re.finditer(r'key = "(j_[a-z_0-9]+)".*?rarity = (\d+), cost = (\d+)', open(sys.argv[1]).read()):
    meta[m.group(1)] = min(int(m.group(2)), 3)
SCAL = sorted("j_hologram j_trousers j_green_joker j_ride_the_bus j_runner j_square j_wee j_lucky_cat j_constellation j_obelisk j_campfire j_ceremonial j_flash j_red_card j_madness j_vampire j_castle j_glass j_throwback j_caino j_yorick j_hit_the_road j_fortune_teller j_supernova".split())
rows = {}
i = 0
for f in sorted(glob.glob(sys.argv[2])):
    for line in open(f):
        d = json.loads(line); i += 1
        sc = 10.0 if d["won"] else float(d["ante"])
        for r in d.get("vl", []):
            c = [0, 0, 0]
            et = ns = poly = 0
            for j in r["jok"]:
                if j[0] in meta: c[meta[j[0]] - 1] += 1
                if len(j) > 3 and j[3]: et += 1
                if j[0] in SCAL: ns += 1
                if (j[1] or 0) == 3: poly += 1
            lp = math.log(max(r["pv"], 1) / max(r["need"], 1))
            rows.setdefault(r["ante"], []).append((sc, i % 2, r["deck"] if "deck" in r else d["deck"], [r["nv"]] + c + [ns, poly, et, r["money"], lp, r["hsize"]]))
decks = sorted({x[2] for a in rows for x in rows[a]})
def inv(A):
    n = len(A)
    M = [A[r][:] + [1.0 if q == r else 0.0 for q in range(n)] for r in range(n)]
    for c in range(n):
        piv = max(range(c, n), key=lambda r: abs(M[r][c])); M[c], M[piv] = M[piv], M[c]
        p = M[c][c]
        if abs(p) < 1e-12: continue
        M[c] = [v / p for v in M[c]]
        for r in range(n):
            if r != c and M[r][c] != 0:
                f = M[r][c]; M[r] = [a - f * b for a, b in zip(M[r], M[c])]
    return [row[n:] for row in M]
def fit(R):
    X = [[1.0] + x[3] + [1.0 if x[2] == dk else 0.0 for dk in decks[1:]] for x in R]
    y = [x[0] for x in R]
    k = len(X[0])
    A = [[sum(x[p] * x[q] for x in X) for q in range(k)] for p in range(k)]
    b = [sum(x[p] * yy for x, yy in zip(X, y)) for p in range(k)]
    Ai = inv(A)
    coef = [sum(Ai[p][q] * b[q] for q in range(k)) for p in range(k)]
    res = [yy - sum(ci * xi for ci, xi in zip(coef, x)) for x, yy in zip(X, y)]
    s2 = sum(e * e for e in res) / (len(y) - k)
    return coef, [math.sqrt(max(s2 * Ai[p][p], 0)) for p in range(k)]
S = 5
out = []
for a in range(2, 9):
    R = rows.get(a, [])
    if len(R) < 150: continue
    c, se = fit(R)
    h = [fit([x for x in R if x[1] == s])[0] for s in (0, 1)]
    k = 9.0 / c[1]
    v, s = c[S], se[S]
    t = v * (v * v) / (v * v + s * s) * k if h[0][S] * h[1][S] > 0 else 0.0
    print("ante %d n %d scaling %+.3f (se %.3f; halves %+.3f %+.3f) leaf factor %.2f table %.4f" % (a, len(R), v, s, h[0][S], h[1][S], k, t))
    for key in SCAL:
        out.append("J %d %s %.4f %d" % (a, key, t, len(R)))
open(sys.argv[3], "w").write("\n".join(out) + "\n")
print(len(out), "lines")
