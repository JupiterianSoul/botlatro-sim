import struct

import numpy as np

MAGIC = b"BNNW"
VERSION = 2


def shapes(cfg):
    E, H, VH = cfg["E"], cfg["H"], cfg["VH"]
    s = [
        ("enc.card.w", (cfg["CF"], E)), ("enc.card.b", (E,)),
        ("enc.joker.w", (cfg["JF"], E)), ("enc.joker.b", (E,)),
        ("enc.item.w", (cfg["IF"], E)), ("enc.item.b", (E,)),
        ("trunk.0.w", (cfg["GF"] + 6 * E, H)), ("trunk.0.b", (H,)),
        ("trunk.1.w", (H, H)), ("trunk.1.b", (H,)),
        ("value.0.w", (H, VH)), ("value.0.b", (VH,)),
        ("value.1.w", (VH, 2)), ("value.1.b", (2,)),
    ]
    for t in type_list(cfg):
        s.append((f"pol.{t}.w", (H, 2 * E + cfg["FA"])))
        s.append((f"pol.{t}.b", (2 * E + cfg["FA"],)))
    return s


def type_list(cfg):
    return [t for t in str(cfg["types"]).split(",") if t]


def cfg_string(cfg):
    return ";".join(f"{k}={cfg[k]}" for k in sorted(cfg))


def parse_cfg(text):
    cfg = {}
    for part in text.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                cfg[k] = int(v)
            except ValueError:
                try:
                    cfg[k] = float(v)
                except ValueError:
                    cfg[k] = v
    return cfg


def encode(cfg, tensors):
    cs = cfg_string(cfg).encode()
    out = [MAGIC, struct.pack("<II", VERSION, len(cs)), cs]
    order = shapes(cfg)
    out.append(struct.pack("<I", len(order)))
    for name, dims in order:
        nb = name.encode()
        out.append(struct.pack("<B", len(nb)) + nb + struct.pack("<B", len(dims)))
        out.append(struct.pack("<" + "I" * len(dims), *dims))
    for name, dims in order:
        a = np.asarray(tensors[name], dtype="<f4")
        assert a.shape == tuple(dims), (name, a.shape, dims)
        out.append(a.tobytes(order="C"))
    return b"".join(out)


def decode(data):
    assert data[:4] == MAGIC, "bad weight magic"
    ver, clen = struct.unpack_from("<II", data, 4)
    assert ver == VERSION, f"unsupported weight version {ver}"
    pos = 12
    cfg = parse_cfg(data[pos:pos + clen].decode())
    pos += clen
    (nt,) = struct.unpack_from("<I", data, pos)
    pos += 4
    meta = []
    for _ in range(nt):
        ln = data[pos]
        name = data[pos + 1:pos + 1 + ln].decode()
        pos += 1 + ln
        nd = data[pos]
        pos += 1
        dims = struct.unpack_from("<" + "I" * nd, data, pos)
        pos += 4 * nd
        meta.append((name, dims))
    tensors = {}
    for name, dims in meta:
        n = int(np.prod(dims))
        tensors[name] = np.frombuffer(data, dtype="<f4", count=n, offset=pos).reshape(dims).copy()
        pos += 4 * n
    return cfg, tensors


def save(path, cfg, tensors):
    with open(path, "wb") as f:
        f.write(encode(cfg, tensors))


def load(path):
    with open(path, "rb") as f:
        return decode(f.read())
