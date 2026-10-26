import struct
import sys
import types


class _Arr:
    def __init__(self, shape):
        self.shape = shape
        if len(shape) == 1:
            self.v = [0.0] * shape[0]
        else:
            self.v = [_Arr(shape[1:]) for _ in range(shape[0])]

    def __getitem__(self, i):
        if isinstance(i, tuple):
            return self.v[i[0]][i[1]]
        return self.v[i]

    def __setitem__(self, i, x):
        if isinstance(i, tuple):
            self.v[i[0]][i[1]] = x
        elif isinstance(i, list):
            for k, val in zip(i, x):
                self.v[k] = val
        else:
            self.v[i] = x

    def __iter__(self):
        return iter(self.v)


def _shim_numpy():
    np = types.ModuleType("numpy")
    np.float32, np.int64 = "f4", "i8"
    np.zeros = lambda shape, dtype=None: _Arr(shape if isinstance(shape, tuple) else (shape,))

    def frombuffer(data, dtype, count, offset):
        fmt = {"<u2": "H", "<f4": "f"}[dtype]
        return list(struct.unpack_from("<%d%s" % (count, fmt), data, offset))

    np.frombuffer = frombuffer
    return np


try:
    import numpy
except ImportError:
    sys.modules["numpy"] = _shim_numpy()
try:
    import torch
except ImportError:
    t = types.ModuleType("torch")
    t.float32 = "f4"
    sys.modules["torch"] = t

sys.path.insert(0, "tools/botsim/train")
from bnn import records

total, runs, wins = 0, 0, 0
for path in sys.argv[1:]:
    dims, rs, recs = records.read(path)
    runs += len(rs)
    wins += sum(r["won"] for r in rs)
    assert sum(r["n"] for r in rs) == len(recs), "record count matches the run headers"
    for rec in recs:
        total += 1
        visits = list(rec["visits"])
        assert sum(1 for v in visits if v > 0) == 1, "visits must be one-hot"
        assert visits[rec["chosen"]] > 0, "chosen action carries the visits"
print(f"dims {dims} runs {runs} wins {wins} records {total}: ok")
