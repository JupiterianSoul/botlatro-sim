import os
import sys

import torch

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from bnn import records as R  # noqa: E402

n = 0
for path in sys.argv[1:]:
    d0, r0, x0 = R.read(path)
    d1, r1, x1 = R.read_lazy(path)
    assert d0 == d1 and r0 == r1 and len(x0) == len(x1), path
    for k in range(0, len(x0), 16):
        b0, b1 = R.collate(x0[k:k + 16], d0), R.collate(x1[k:k + 16], d1)
        assert all(torch.equal(b0[f], b1[f]) for f in b0), (path, k)
    for a, b in zip(x0, x1):
        assert all(a[f] == b[f] for f in ("chosen", "root_q", "net_v", "n_sims", "phase", "won", "final_ante")), path
    R.CHOSEN = 1.0
    b = R.collate(x0[:16], d0)
    for k, r in enumerate(x0[:16]):
        assert float(b["pi"][k, r["chosen"]]) == 1.0 and abs(float(b["pi"][k].sum()) - 1.0) < 1e-5, (path, k)
    R.CHOSEN = 0.5
    b = R.collate(x0[:16], d0)
    assert torch.allclose(b["pi"].sum(1), torch.ones(b["pi"].shape[0])), path
    R.CHOSEN = 0.0
    n += len(x0)
print("lazy records match: %d records in %d files" % (n, len(sys.argv) - 1))
