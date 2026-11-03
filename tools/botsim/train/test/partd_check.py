import os
import sys

import numpy as np
import torch
import torch.nn.functional as Fn

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
R.MASK = False
b2 = R.collate(masked, dims)
assert float(b2["amask"].sum()) == float(sum(r["atype"].shape[0] for r in masked)), "mask off keeps every move"
assert torch.allclose(b2["pi"].sum(1), torch.ones(len(masked))), "mask off targets sum to 1"
R.MASK = True
R.ANCHOR = True
b3 = R.collate(masked, dims)
assert torch.equal(b3["amask"], b2["amask"]), "anchor keeps every move in the softmax"
assert torch.equal(b3["judged"], b["amask"]), "anchor marks the judged moves"
assert torch.equal(b3["pi"], b["pi"]), "anchor keeps the judged targets"
m = Net.from_file(sys.argv[3]) if len(sys.argv) > 3 else None
if m is not None:
    if m.cfg["GF"] < dims["GF"]:
        from train import widen
        m = widen(m, dims["GF"])
    from train import losses
    with torch.no_grad():
        _, lp0, _, _ = losses(m, b3, 1.0, ref=m)
        p = Fn.softmax(m(b3)[2], -1)
        pi = p * (b3["amask"] - b3["judged"]) + (1 - (p * (b3["amask"] - b3["judged"])).sum(-1, keepdim=True)) * b3["pi"]
        assert torch.allclose(pi.sum(-1), torch.ones(len(masked)), atol=1e-4), "anchored targets sum to 1"
    print("anchored policy loss at the start %.4f" % lp0)
R.ANCHOR = False
judged = sum(int((r["visits"] >= 0).sum()) for r in masked)
total = sum(int(r["visits"].shape[0]) for r in masked)
print("records %d, with unjudged moves %d, judged moves %d of %d" % (len(recs), len(masked), judged, total))
print("partd check ok", torch.__version__)
