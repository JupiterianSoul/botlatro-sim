import sys, glob, json, math, re
from collections import defaultdict
meta = {}
for m in re.finditer(r'key = "(j_[a-z_0-9]+)".*?rarity = (\d+), cost = (\d+)', open(sys.argv[1]).read()):
    meta[m.group(1)] = min(int(m.group(2)), 3)
EDS = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else []
rows = defaultdict(list)
i = 0
for f in sorted(glob.glob(sys.argv[2])):
    for line in open(f):
        d = json.loads(line); i += 1
        sc = 10.0 if d["won"] else float(d["ante"])
        for r in d.get("vl", []):
            c = [0, 0, 0] + [0] * len(EDS)
            for j in r["jok"]:
                if j[0] in meta: c[meta[j[0]] - 1] += 1
                if (j[1] or 0) in EDS: c[3 + EDS.index(j[1])] += 1
            rows[r["ante"]].append((sc, r["nv"], c, d["deck"], i % 2))
def ols(X, y):
    k = len(X[0])
    A = [[sum(x[p] * x[q] for x in X) for q in range(k)] for p in range(k)]
    b = [sum(x[p] * yy for x, yy in zip(X, y)) for p in range(k)]
    n = len(A)
    M = [A[r] + [b[r]] for r in range(n)]
    for c in range(n):
        piv = max(range(c, n), key=lambda r: abs(M[r][c])); M[c], M[piv] = M[piv], M[c]
        for r in range(n):
            if r != c:
                f = M[r][c] / M[c][c]; M[r] = [a - f * bb for a, bb in zip(M[r], M[c])]
    coef = [M[r][n] / M[r][r] for r in range(n)]
    res = [yy - sum(ci * xi for ci, xi in zip(coef, x)) for x, yy in zip(X, y)]
    s2 = sum(e * e for e in res) / (len(y) - k)
    inv = []
    for col in range(n):
        e = [1.0 if r == col else 0.0 for r in range(n)]
        M2 = [A[r][:] + [e[r]] for r in range(n)]
        for c in range(n):
            piv = max(range(c, n), key=lambda r: abs(M2[r][c])); M2[c], M2[piv] = M2[piv], M2[c]
            for r in range(n):
                if r != c:
                    f = M2[r][c] / M2[c][c]; M2[r] = [a - f * bb for a, bb in zip(M2[r], M2[c])]
        inv.append(M2[col][n] / M2[col][col])
    return coef, [math.sqrt(s2 * v) for v in inv]
decks = sorted({x[3] for a in rows for x in rows[a]})
def fit(R):
    X = [[1.0, x[1]] + x[2] + [1.0 if x[3] == dk else 0.0 for dk in decks[1:]] for x in R]
    return ols(X, [x[0] for x in R])
out = []
for a in range(2, 7):
    R = rows[a]
    if len(R) < 150: continue
    (c, se) = fit(R)
    h = [fit([x for x in R if x[4] == s])[0] for s in (0, 1)]
    k = 9.0 / c[1]
    print("ante %d n %d nv %.2f | common %+.3f (se %.3f; halves %+.3f %+.3f) uncommon %+.3f (se %.3f; %+.3f %+.3f) rare %+.3f (se %.3f; %+.3f %+.3f) | leaf factor %.2f" % (a, len(R), c[1], c[2], se[2], h[0][2], h[1][2], c[3], se[3], h[0][3], h[1][3], c[4], se[4], h[0][4], h[1][4], k))
    for r in range(3):
        v, s = c[2 + r], se[2 + r]
        v = v * (v * v) / (v * v + s * s) * k if h[0][2 + r] * h[1][2 + r] > 0 else 0.0
        for key, rr in sorted(meta.items()):
            if rr == r + 1:
                out.append("J %d %s %.4f %d" % (a, key, v, len(R)))
    for q, e in enumerate(EDS):
        v, s = c[5 + q], se[5 + q]
        print("ante %d edition %d %+.3f (se %.3f; halves %+.3f %+.3f)" % (a, e, v, s, h[0][5 + q], h[1][5 + q]))
        v = v * (v * v) / (v * v + s * s) * k if h[0][5 + q] * h[1][5 + q] > 0 else 0.0
        out.append("E %d %d %.4f %d" % (a, e, v, len(R)))
open(sys.argv[3], "w").write("\n".join(out) + "\n")
print(len(out), "lines")
