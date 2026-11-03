import os
import random
import sys

import torch
import torch.nn.functional as Fn

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from bnn import records as R  # noqa: E402
from bnn.model import Net  # noqa: E402

nets = [a for a in sys.argv[1:] if a.endswith(".bnnw")]
files = [a for a in sys.argv[1:] if not a.endswith(".bnnw")]
recs, dims = [], None
for f in files:
    d, _, rs = R.read(f)
    dims = dims or d
    recs += [r for r in rs if (r["visits"] < 0).any() and (r["visits"] >= 0).any()]
recs = random.Random(1).sample(recs, min(len(recs), 4000))
R.MASK, R.ANCHOR = True, True
for name in nets:
    m = Net.from_file(name).eval()
    if m.cfg["GF"] < dims["GF"]:
        from train import widen
        m = widen(m, dims["GF"]).eval()
    tot, top, n = 0.0, 0.0, 0
    tt = {}
    with torch.no_grad():
        for i in range(0, len(recs), 256):
            b = R.collate(recs[i:i + 256], dims)
            p = Fn.softmax(m(b)[2], -1)
            un = (b["amask"] - b["judged"]).clamp(min=0)
            mass = (p * un).sum(-1)
            best = p.argmax(-1)
            hit = un.gather(1, best.unsqueeze(1)).squeeze(1)
            tot += float(mass.sum())
            top += float(hit.sum())
            n += p.shape[0]
            first = b["atype"][:, 0]
            for k in range(p.shape[0]):
                t = int(first[k])
                a = tt.setdefault(t, [0.0, 0])
                a[0] += float(mass[k])
                a[1] += 1
    per = " ".join("t%d %.3f(%d)" % (t, v[0] / v[1], v[1]) for t, v in sorted(tt.items()))
    print("%s records %d unjudged mass %.3f argmax unjudged %.3f | %s" % (os.path.basename(os.path.dirname(name)) or name, n, tot / n, top / n, per))
