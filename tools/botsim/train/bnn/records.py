import struct

import numpy as np
import torch

MAGIC = b"BSPR"
VERSION = 2

ENT_KIND = {"buy": 1, "buy_use": 1, "sell_joker": 2, "sell_cons": 1, "use": 1, "redeem": 1, "open": 1, "pick": 1,
            "move_joker": 2}


def _sparse(data, pos, n):
    (nnz,) = struct.unpack_from("<H", data, pos)
    pos += 2
    v = np.zeros(n, dtype=np.float32)
    if nnz:
        idx = np.frombuffer(data, dtype="<u2", count=nnz, offset=pos)
        pos += 2 * nnz
        v[idx] = np.frombuffer(data, dtype="<f4", count=nnz, offset=pos)
        pos += 4 * nnz
    return v, pos


def _rows(data, pos, count, n):
    out = np.zeros((count, n), dtype=np.float32)
    for i in range(count):
        out[i], pos = _sparse(data, pos, n)
    return out, pos


def read(path):
    with open(path, "rb") as f:
        data = f.read()
    return parse(data)


def read_lazy(path):
    with open(path, "rb") as f:
        data = f.read()
    return parse(data, lazy=True)


class Lazy:
    __slots__ = ("ctx", "pos", "won", "final_ante")

    def __init__(self, ctx, pos, won, final_ante):
        self.ctx, self.pos, self.won, self.final_ante = ctx, pos, won, final_ante

    def __getitem__(self, k):
        if k == "won":
            return self.won
        if k == "final_ante":
            return self.final_ante
        return self.load()[k]

    def load(self):
        return _record(self.ctx, self.pos, self.won, self.final_ante)[0]


def _skip_sparse(data, pos):
    (nnz,) = struct.unpack_from("<H", data, pos)
    return pos + 2 + 6 * nnz


def _skip(ctx, pos):
    data = ctx[0]
    nc, nj, ni, phase, na, chosen = struct.unpack_from("<4BHH", data, pos)
    pos = _skip_sparse(data, pos + 20)
    for _ in range(nc + nj + ni):
        pos = _skip_sparse(data, pos)
    for _ in range(na):
        pos = _skip_sparse(data, pos + 16)
    return pos


def _record(ctx, pos, won, final_ante):
    data, GF, CF, JF, IF, FA, MS, tent = ctx
    nc, nj, ni, phase, na, chosen = struct.unpack_from("<4BHH", data, pos)
    root_q, net_v, n_sims = struct.unpack_from("<ffI", data, pos + 8)
    pos += 20
    g, pos = _sparse(data, pos, GF)
    c, pos = _rows(data, pos, nc, CF)
    j, pos = _rows(data, pos, nj, JF)
    it, pos = _rows(data, pos, ni, IF)
    atype = np.zeros(na, dtype=np.int64)
    asel = np.zeros((na, max(nc, 1)), dtype=np.float32)
    aitem = np.zeros((na, max(ni, 1)), dtype=np.float32)
    ajok = np.zeros((na, max(nj, 1)), dtype=np.float32)
    visits = np.zeros(na, dtype=np.float32)
    prior = np.zeros(na, dtype=np.float32)
    afa = np.zeros((na, FA), dtype=np.float32)
    for a in range(na):
        t, n = data[pos], data[pos + 1]
        sel = data[pos + 2:pos + 2 + MS]
        ent = data[pos + 2 + MS]
        pos += 8
        vis, pr = struct.unpack_from("<If", data, pos)
        pos += 8
        atype[a] = t - 1
        for i in range(n):
            asel[a, sel[i]] = 1.0
        if ent != 255:
            k = tent[t - 1]
            if k == 1:
                aitem[a, ent] = 1.0
            elif k == 2:
                ajok[a, ent] = 1.0
        visits[a] = vis
        prior[a] = pr
        afa[a], pos = _sparse(data, pos, FA)
    return {
        "g": g, "c": c, "j": j, "i": it, "atype": atype, "asel": asel, "aitem": aitem, "ajok": ajok, "afa": afa,
        "visits": visits, "prior": prior, "chosen": chosen, "root_q": root_q, "net_v": net_v, "n_sims": n_sims,
        "phase": phase, "won": won, "final_ante": final_ante,
    }, pos


def parse(data, lazy=False):
    assert data[:4] == MAGIC, "bad record magic"
    ver, GF, CF, JF, IF, FA, MS = struct.unpack_from("<7I", data, 4)
    assert ver == VERSION, f"unsupported record version {ver}"
    pos = 32
    (tl,) = struct.unpack_from("<H", data, pos)
    types = data[pos + 2:pos + 2 + tl].decode().split(",")
    pos += 2 + tl
    tent = np.array([ENT_KIND.get(t, 0) for t in types], dtype=np.int64)
    dims = {"version": ver, "GF": GF, "CF": CF, "JF": JF, "IF": IF, "FA": FA, "MS": MS, "types": ",".join(types)}
    ctx = (data, GF, CF, JF, IF, FA, MS, tent)
    recs = []
    runs = []
    while pos < len(data):
        assert data[pos:pos + 4] == b"RUN2", "bad run magic"
        nrec, won, final_ante, deck_idx, stake, run_index = struct.unpack_from("<IBBBBI", data, pos + 4)
        pos += 16
        runs.append({"n": nrec, "won": won, "final_ante": final_ante, "deck": deck_idx, "stake": stake, "index": run_index})
        for _ in range(nrec):
            if lazy:
                recs.append(Lazy(ctx, pos, float(won), float(final_ante)))
                pos = _skip(ctx, pos)
            else:
                r, pos = _record(ctx, pos, float(won), float(final_ante))
                recs.append(r)
    return dims, runs, recs


def collate(recs, dims, dtype=torch.float32):
    recs = [r.load() if isinstance(r, Lazy) else r for r in recs]
    B = len(recs)
    C = max(1, max(r["c"].shape[0] for r in recs))
    J = max(1, max(r["j"].shape[0] for r in recs))
    I = max(1, max(r["i"].shape[0] for r in recs))
    A = max(1, max(r["atype"].shape[0] for r in recs))
    g = np.zeros((B, dims["GF"]), np.float32)
    c = np.zeros((B, C, dims["CF"]), np.float32)
    cm = np.zeros((B, C), np.float32)
    j = np.zeros((B, J, dims["JF"]), np.float32)
    jm = np.zeros((B, J), np.float32)
    it = np.zeros((B, I, dims["IF"]), np.float32)
    im = np.zeros((B, I), np.float32)
    at = np.zeros((B, A), np.int64)
    asel = np.zeros((B, A, C), np.float32)
    aitem = np.zeros((B, A, I), np.float32)
    ajok = np.zeros((B, A, J), np.float32)
    afa = np.zeros((B, A, dims["FA"]), np.float32)
    am = np.zeros((B, A), np.float32)
    pi = np.zeros((B, A), np.float32)
    won = np.zeros(B, np.float32)
    ante = np.zeros(B, np.float32)
    nsims = np.zeros(B, np.float32)
    for b, r in enumerate(recs):
        nc, nj, ni, na = r["c"].shape[0], r["j"].shape[0], r["i"].shape[0], r["atype"].shape[0]
        g[b] = r["g"]
        c[b, :nc] = r["c"]
        cm[b, :nc] = 1
        j[b, :nj] = r["j"]
        jm[b, :nj] = 1
        it[b, :ni] = r["i"]
        im[b, :ni] = 1
        at[b, :na] = r["atype"]
        asel[b, :na, :r["asel"].shape[1]] = r["asel"]
        aitem[b, :na, :r["aitem"].shape[1]] = r["aitem"]
        ajok[b, :na, :r["ajok"].shape[1]] = r["ajok"]
        afa[b, :na] = r["afa"]
        am[b, :na] = 1
        tot = r["visits"].sum()
        pi[b, :na] = r["visits"] / tot if tot > 0 else 1.0 / na
        won[b] = r["won"]
        ante[b] = r["final_ante"] / 8.0
        nsims[b] = r["n_sims"]
    t = lambda a: torch.as_tensor(a, dtype=dtype)
    return {
        "g": t(g), "c": t(c), "cmask": t(cm), "j": t(j), "jmask": t(jm), "i": t(it), "imask": t(im),
        "atype": torch.as_tensor(at), "asel": t(asel), "aitem": t(aitem), "ajok": t(ajok), "afa": t(afa),
        "amask": t(am), "pi": t(pi), "won": t(won), "ante": t(ante), "nsims": t(nsims),
    }
