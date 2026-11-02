import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "train"))
import games as G
def load_all(spec):
    out = {}
    for d in spec.split(","):
        g, _ = G.load(d)
        out.update(g)
    return out
B = load_all(sys.argv[1]); N = load_all(sys.argv[2])
keys = [k for k in N if k in B]
def ra(r):
    return 9 if G.real_win(r) else G.real_ante(r)
row = []
for a in range(1, 9):
    def rate(S):
        alive = [k for k in keys if ra(S[k]) >= a]
        cl = [k for k in alive if ra(S[k]) > a]
        return len(cl), len(alive)
    cb, ab = rate(B); cn, an = rate(N)
    row.append("a%d %.3f/%.3f" % (a, cn / an if an else 0, cb / ab if ab else 0))
print("n", len(keys), "clear new/base:", " ".join(row))
