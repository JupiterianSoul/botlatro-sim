import json
import os
import struct
import sys

import games as G


def skip_sparse(data, pos):
    (nnz,) = struct.unpack_from("<H", data, pos)
    return pos + 2 + 6 * nnz


def skip_record(data, pos):
    nc, nj, ni, _, na, _ = struct.unpack_from("<4BHH", data, pos)
    pos = skip_sparse(data, pos + 20)
    for _ in range(nc + nj + ni):
        pos = skip_sparse(data, pos)
    for _ in range(na):
        pos = skip_sparse(data, pos + 16)
    return pos


def relabel(data, games):
    out = bytearray(data)
    (tl,) = struct.unpack_from("<H", data, 32)
    pos = 34 + tl
    changed, k = 0, 0
    while pos < len(data):
        if data[pos:pos + 4] != b"RUN2":
            raise ValueError("bad run magic at %d" % pos)
        (nrec,) = struct.unpack_from("<I", data, pos + 4)
        if k >= len(games):
            raise ValueError("more runs than games")
        r = games[k]
        won, ante = (1 if G.real_win(r) else 0), min(G.real_ante(r), 255)
        if (out[pos + 8], out[pos + 9]) != (won, ante):
            out[pos + 8], out[pos + 9] = won, ante
            changed += 1
        pos += 16
        for _ in range(nrec):
            pos = skip_record(data, pos)
        k += 1
    if k + 1 < len(games):
        raise ValueError("runs %d, games %d" % (k, len(games)))
    return bytes(out), k, changed


def main(root):
    runs, changed = 0, 0
    for d, _, files in os.walk(root):
        for f in sorted(files):
            if not (f.startswith("x") and f.endswith(".bspr")):
                continue
            path = os.path.join(d, f)
            if os.path.getsize(path) == 0:
                continue
            with open(os.path.join(d, "g" + f[1:-5] + ".jsonl")) as h:
                games = [json.loads(l) for l in h if l.strip()]
            with open(path, "rb") as h:
                new, n, c = relabel(h.read(), games)
            with open(path, "wb") as h:
                h.write(new)
            runs, changed = runs + n, changed + c
    print("runs %d relabelled %d" % (runs, changed))


if __name__ == "__main__":
    main(sys.argv[1])
