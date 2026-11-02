import os
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from bnn import records as R  # noqa: E402
from bnn.model import Net  # noqa: E402

if sys.argv[1] == "amplify":
    m = Net.from_file(sys.argv[2])
    base = int(sys.argv[4])
    torch.manual_seed(7)
    with torch.no_grad():
        w = m.t0.weight
        w[:, base:base + 10] = torch.randn(w.shape[0], 10) * 2.0
    m.save(sys.argv[3])
    print("amplified GF %d inputs %d..%d" % (m.cfg["GF"], base, base + 9))
    sys.exit(0)

dims, runs, recs = R.read(sys.argv[1])
masked = [r for r in recs if (r["visits"] < 0).any()]
assert masked, "no record has unjudged moves"
for r in masked:
    assert r["visits"][r["chosen"]] >= 0, "the chosen move is unjudged"
b = R.collate(masked, dims)
for k, r in enumerate(masked):
    na = r["atype"].shape[0]
    vis = r["visits"]
    am = b["amask"][k, :na].numpy()
    pi = b["pi"][k, :na].numpy()
    assert np.array_equal(am > 0, vis >= 0), k
    assert abs(float(pi.sum()) - 1.0) < 1e-5, k
    assert float(np.abs(pi[vis < 0]).sum()) == 0.0, k
g = b["g"].numpy()
base = int(sys.argv[2]) if len(sys.argv) > 2 else 0
if base:
    ext = g[:, base:]
    assert ext.shape[1] == 10 and np.abs(ext).sum() > 0, "extended inputs are all zero"
    print("extended inputs nonzero share %.3f, power mean %.3f" % (float((ext != 0).mean()), float(ext[:, 9].mean())))
judged = sum(int((r["visits"] >= 0).sum()) for r in masked)
total = sum(int(r["visits"].shape[0]) for r in masked)
print("records %d, with unjudged moves %d, judged moves %d of %d" % (len(recs), len(masked), judged, total))
print("partd check ok", torch.__version__)
