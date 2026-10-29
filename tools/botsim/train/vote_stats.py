import glob
import random
import sys

import numpy as np

sys.path.insert(0, "tools/botsim/train")
from bnn import records as R  # noqa: E402

files = sorted(glob.glob(sys.argv[1]))
n = int(sys.argv[2]) if len(sys.argv) > 2 else 50000
recs = []
for f in files:
    _, _, x = R.read_lazy(f)
    recs += x
random.seed(1)
recs = random.sample(recs, min(n, len(recs)))
st = {"play": [], "disc": []}
for r in recs:
    r = r.load()
    at, vis, ch = r["atype"], r["visits"], r["chosen"]
    if not (at == 1).any():
        continue
    tot = vis.sum()
    if tot <= 0:
        continue
    dm = vis[at == 1].sum() / tot
    nd = int(((at == 1) & (vis > 0)).sum())
    st["disc" if at[ch] == 1 else "play"].append((vis[ch] / tot, dm, nd))
for k, v in st.items():
    a = np.array(v)
    print("%s chosen: %d records | chosen vote share mean %.3f median %.3f | discard vote mass mean %.3f | share with discard mass > 0.5: %.3f | voted discards per record %.2f"
          % (k, len(a), a[:, 0].mean(), np.median(a[:, 0]), a[:, 1].mean(), (a[:, 1] > 0.5).mean(), a[:, 2].mean()))
