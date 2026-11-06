import os
import random
import sys

import torch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from bnn import records as R  # noqa: E402
from bnn.model import Net  # noqa: E402
from train import widen  # noqa: E402

mode, p0, p1 = sys.argv[1], sys.argv[2], sys.argv[3]
recs = []
dims = None
for path in sys.argv[4:]:
    d, _, rs = R.read(path)
    dims = dims or d
    recs.extend(rs)
recs = random.Random(1).sample(recs, min(4096, len(recs)))
m0, m1 = Net.from_file(p0), Net.from_file(p1)
if m1.cfg["GF"] < dims["GF"]:
    dims = dict(dims, GF=m1.cfg["GF"])
if m0.cfg["GF"] < dims["GF"]:
    m0 = widen(m0, dims["GF"])
m0.eval()
m1.eval()
R.MASK = False
dp, dv, da, n = 0.0, 0.0, 0.0, 0
with torch.no_grad():
    for i in range(0, len(recs), 512):
        b = R.collate(recs[i:i + 512], dims)
        z0, a0, l0 = m0(b)
        z1, a1, l1 = m1(b)
        am = b["amask"] > 0
        dp = max(dp, float((l0 - l1).abs()[am].max()))
        dv += float((torch.sigmoid(z0) - torch.sigmoid(z1)).abs().sum())
        da += float(((a0 - a1) * 8.0).abs().sum())
        n += len(z0)
print("records %d policy logit max diff %.3g value mean diff %.4f ante mean diff %.3f" % (n, dp, dv / n, da / n))
if mode == "frozen":
    assert dp < 1e-4, "policy moved"
    assert da / n > 0 or dv / n > 0, "value did not move"
if mode == "policy":
    assert da / n < 1e-6 and dv / n < 1e-6, "value moved"
    assert dp > 0, "policy did not move"
print("frozen check ok")
