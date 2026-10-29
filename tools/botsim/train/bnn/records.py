import itertools
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


CHOSEN = 0.0
ALL_DISC = False
DISC_CAP = 400
C_DEBUFF, C_FLIPPED, C_FORCED = 33, 34, 35
A_N, A_DEBUFF, A_FLIPPED, A_BIAS = 0, 20, 21, 22
_SUBSETS = {}
_RNG = np.random.default_rng(0)


def _subsets(n, forced):
    got = _SUBSETS.get((n, forced))
    if got is None:
        rows = [c for k in range(1, min(5, n) + 1) for c in itertools.combinations(range(n), k) if forced < 0 or forced in c]
        m = np.zeros((len(rows), n), np.float32)
        for i, c in enumerate(rows):
            m[i, list(c)] = 1.0
        got = (m, rows, {k: i for i, k in enumerate(rows)})
        _SUBSETS[(n, forced)] = got
    return got


def discard_fa(sel, c, FA):
    fa = np.zeros((sel.shape[0], FA), np.float32)
    fa[np.arange(sel.shape[0]), A_N + sel.sum(1).astype(np.int64) - 1] = 1.0
    fa[:, A_DEBUFF] = sel @ c[:, C_DEBUFF] / 5
    fa[:, A_FLIPPED] = sel @ c[:, C_FLIPPED] / 5
    fa[:, A_BIAS] = 1.0
    return fa


def all_discards(r):
    at = r["atype"]
    disc = np.nonzero(at == 1)[0]
    c = r["c"]
    nc = c.shape[0]
    if len(disc) == 0 or nc == 0:
        return r
    FA = r["afa"].shape[1]
    forced = np.nonzero(c[:, C_FORCED] > 0)[0]
    sub, keys, pos = _subsets(nc, int(forced[0]) if len(forced) else -1)
    have = {}
    for a in disc:
        have[tuple(int(i) for i in np.nonzero(r["asel"][a, :nc])[0])] = a
    if len(keys) > DISC_CAP:
        hit = sorted(pos[k] for k in have if k in pos)
        pick = set(hit)
        for i in _RNG.permutation(len(keys)):
            if len(pick) >= DISC_CAP:
                break
            pick.add(int(i))
        pick = sorted(pick)
        sub = sub[pick]
        keys = [keys[i] for i in pick]
        pos = {k: i for i, k in enumerate(keys)}
    extra = [a for k, a in have.items() if k not in pos]
    keep = np.nonzero(at != 1)[0]
    S, E = len(keys), len(extra)
    na = len(keep) + S + E
    W = r["asel"].shape[1]
    out = dict(r)
    out["atype"] = np.concatenate([at[keep], np.ones(S, np.int64), at[extra]])
    sel = np.zeros((S, W), np.float32)
    sel[:, :nc] = sub
    out["asel"] = np.concatenate([r["asel"][keep], sel, r["asel"][extra]])
    out["aitem"] = np.concatenate([r["aitem"][keep], np.zeros((S, r["aitem"].shape[1]), np.float32), r["aitem"][extra]])
    out["ajok"] = np.concatenate([r["ajok"][keep], np.zeros((S, r["ajok"].shape[1]), np.float32), r["ajok"][extra]])
    out["afa"] = np.concatenate([r["afa"][keep], discard_fa(sub, c, FA), r["afa"][extra]])
    vis = np.zeros(S, np.float32)
    pri = np.zeros(S, np.float32)
    for k, a in have.items():
        if k in pos:
            vis[pos[k]] = r["visits"][a]
            pri[pos[k]] = r["prior"][a]
    out["visits"] = np.concatenate([r["visits"][keep], vis, r["visits"][extra]])
    out["prior"] = np.concatenate([r["prior"][keep], pri, r["prior"][extra]])
    ch = r["chosen"]
    if at[ch] != 1:
        out["chosen"] = int(np.nonzero(keep == ch)[0][0])
    else:
        k = tuple(int(i) for i in np.nonzero(r["asel"][ch, :nc])[0])
        out["chosen"] = len(keep) + pos[k] if k in pos else len(keep) + S + extra.index(ch)
    assert out["atype"].shape[0] == na
    return out


def check_discards(recs, n):
    checked, bad, missing = 0, 0, 0
    for r in recs[:n]:
        r = r.load() if isinstance(r, Lazy) else r
        at = r["atype"]
        disc = np.nonzero(at == 1)[0]
        if len(disc) == 0:
            continue
        nc = r["c"].shape[0]
        sel = r["asel"][disc, :nc]
        fa = discard_fa(sel, r["c"], r["afa"].shape[1])
        checked += len(disc)
        bad += int((np.abs(fa - r["afa"][disc]).max(1) > 1e-6).sum())
        x = all_discards(r)
        if x["visits"].sum() != r["visits"].sum() or x["visits"][x["chosen"]] != r["visits"][r["chosen"]]:
            missing += 1
        if x["atype"][x["chosen"]] != at[r["chosen"]] or not np.array_equal(x["asel"][x["chosen"]], r["asel"][r["chosen"]]):
            missing += 1
    return checked, bad, missing


def collate(recs, dims, dtype=torch.float32):
    recs = [r.load() if isinstance(r, Lazy) else r for r in recs]
    if ALL_DISC:
        recs = [all_discards(r) for r in recs]
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
        if CHOSEN > 0 and r["chosen"] < na:
            pi[b, :na] *= 1.0 - CHOSEN
            pi[b, r["chosen"]] += CHOSEN
        won[b] = r["won"]
        ante[b] = r["final_ante"] / 8.0
        nsims[b] = r["n_sims"]
    t = lambda a: torch.as_tensor(a, dtype=dtype)
    return {
        "g": t(g), "c": t(c), "cmask": t(cm), "j": t(j), "jmask": t(jm), "i": t(it), "imask": t(im),
        "atype": torch.as_tensor(at), "asel": t(asel), "aitem": t(aitem), "ajok": t(ajok), "afa": t(afa),
        "amask": t(am), "pi": t(pi), "won": t(won), "ante": t(ante), "nsims": t(nsims),
    }
