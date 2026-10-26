import os
import subprocess
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)

from bnn import records as R  # noqa: E402
from bnn.model import Net  # noqa: E402

TOL = 1e-5


def lua(*args):
    cmd = ["nice", "-n", "19", "taskset", "-c", "0-3", "luajit", *args]
    subprocess.run(cmd, cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def main():
    out = os.path.join(HERE, "out")
    os.makedirs(out, exist_ok=True)
    rec_path = os.path.join(out, "parity.bspr")
    w_path = os.path.join(out, "parity.bnnw")
    lua("tools/botsim/train/selfplay.lua", "runs=3", "sims=16", "quiet=2", "seed=5", f"out={rec_path}")
    teach_path = os.path.join(out, "parity_teacher.bspr")
    lua("tools/botsim/train/teacher.lua", "runs=4", "eps=0.3", "cut=1", "quiet=2", "seed=5", f"out={teach_path}")
    dims, runs, recs = R.read(rec_path)
    _, truns, trecs = R.read(teach_path)
    cfg = {"CF": dims["CF"], "JF": dims["JF"], "IF": dims["IF"], "GF": dims["GF"], "FA": dims["FA"], "E": 32, "H": 128,
           "VH": 32, "types": dims["types"]}
    torch.manual_seed(1234)
    m = Net(cfg)
    with torch.no_grad():
        for p in m.parameters():
            p.mul_(3.0)
    m.save(w_path)
    m = Net.from_file(w_path)
    worst = {}
    types = dims["types"].split(",")
    seen = sorted({types[t] for r in recs + trecs for t in r["atype"].tolist()}, key=types.index)
    recs = recs + trecs
    runs = runs + truns
    for mode in ("ffi", "plain"):
        lua_out = os.path.join(out, f"parity_{mode}.txt")
        rows = []
        for path in (rec_path, teach_path):
            lua("tools/botsim/train/parity_lua.lua", w_path, path, lua_out, mode)
            rows += [list(map(float, line.split())) for line in open(lua_out)]
        assert len(rows) == len(recs), (len(rows), len(recs))
        for prec, dtype in (("f64", torch.float64), ("f32", torch.float32)):
            mm = m.to(dtype)
            b = R.collate(recs, dims, dtype)
            with torch.no_grad():
                z, ante, logits = mm(b)
            md = 0.0
            for i, row in enumerate(rows):
                na = recs[i]["atype"].shape[0]
                ref = np.array([z[i].item(), ante[i].item()] + logits[i, :na].tolist())
                err = np.abs(ref - np.array(row))
                if prec == "f32":
                    err = err / np.maximum(1.0, np.abs(ref))
                md = max(md, float(np.max(err)))
            worst[(mode, prec)] = md
    scale = float(np.max(np.abs(np.array(rows[0]))))
    print(f"records {len(recs)} runs {len(runs)} output scale ~{scale:.3g}")
    print(f"action types covered ({len(seen)}/{len(types)}): {','.join(seen)}")
    ok = True
    for (mode, prec), md in worst.items():
        good = md < TOL
        ok = ok and good
        kind = "abs" if prec == "f64" else "rel"
        print(f"lua {mode:5s} vs torch {prec}: max {kind} diff {md:.3e} {'OK' if good else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
