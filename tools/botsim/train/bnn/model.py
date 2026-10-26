import torch
import torch.nn as nn
import torch.nn.functional as Fn

from . import weights as W


class Net(nn.Module):
    def __init__(self, cfg):
        super().__init__()
        self.cfg = dict(cfg)
        E, H, VH = cfg["E"], cfg["H"], cfg["VH"]
        self.E = E
        self.types = W.type_list(cfg)
        self.card = nn.Linear(cfg["CF"], E)
        self.joker = nn.Linear(cfg["JF"], E)
        self.item = nn.Linear(cfg["IF"], E)
        self.t0 = nn.Linear(cfg["GF"] + 6 * E, H)
        self.t1 = nn.Linear(H, H)
        self.v0 = nn.Linear(H, VH)
        self.v1 = nn.Linear(VH, 2)
        self.pol = nn.ModuleList([nn.Linear(H, 2 * E + cfg["FA"]) for _ in self.types])

    def encode_set(self, layer, x, mask):
        e = Fn.relu(layer(x)) * mask.unsqueeze(-1)
        return e, e.sum(1), e.max(1).values

    def forward(self, b):
        ce, csum, cmax = self.encode_set(self.card, b["c"], b["cmask"])
        je, jsum, jmax = self.encode_set(self.joker, b["j"], b["jmask"])
        ie, isum, imax = self.encode_set(self.item, b["i"], b["imask"])
        x = torch.cat([b["g"], csum, cmax, jsum, jmax, isum, imax], -1)
        q = Fn.relu(self.t1(Fn.relu(self.t0(x))))
        v = self.v1(Fn.relu(self.v0(q)))
        U = torch.stack([p(q) for p in self.pol], 1)
        idx = b["atype"].clamp(min=0).unsqueeze(-1).expand(-1, -1, U.shape[-1])
        Ua = torch.gather(U, 1, idx)
        E = self.E
        cs = (torch.einsum("bae,bce->bac", Ua[..., :E], ce) * b["asel"]).sum(-1)
        ei = (torch.einsum("bae,bie->bai", Ua[..., E:2 * E], ie) * b["aitem"]).sum(-1)
        ej = (torch.einsum("bae,bje->baj", Ua[..., E:2 * E], je) * b["ajok"]).sum(-1)
        logits = cs + ei + ej + (b["afa"] * Ua[..., 2 * E:]).sum(-1)
        logits = logits.masked_fill(b["amask"] <= 0, float("-inf"))
        return v[:, 0], v[:, 1], logits

    def export_tensors(self):
        def wt(l):
            return l.weight.detach().cpu().double().numpy().T.copy()

        def bs(l):
            return l.bias.detach().cpu().double().numpy().copy()

        t = {
            "enc.card.w": wt(self.card), "enc.card.b": bs(self.card),
            "enc.joker.w": wt(self.joker), "enc.joker.b": bs(self.joker),
            "enc.item.w": wt(self.item), "enc.item.b": bs(self.item),
            "trunk.0.w": wt(self.t0), "trunk.0.b": bs(self.t0),
            "trunk.1.w": wt(self.t1), "trunk.1.b": bs(self.t1),
            "value.0.w": wt(self.v0), "value.0.b": bs(self.v0),
            "value.1.w": wt(self.v1), "value.1.b": bs(self.v1),
        }
        for name, l in zip(self.types, self.pol):
            t[f"pol.{name}.w"] = wt(l)
            t[f"pol.{name}.b"] = bs(l)
        return t

    def save(self, path):
        W.save(path, self.cfg, self.export_tensors())

    def load_tensors(self, t):
        def put(l, name):
            with torch.no_grad():
                l.weight.copy_(torch.as_tensor(t[name + ".w"]).T)
                l.bias.copy_(torch.as_tensor(t[name + ".b"]))

        put(self.card, "enc.card")
        put(self.joker, "enc.joker")
        put(self.item, "enc.item")
        put(self.t0, "trunk.0")
        put(self.t1, "trunk.1")
        put(self.v0, "value.0")
        put(self.v1, "value.1")
        for name, l in zip(self.types, self.pol):
            put(l, f"pol.{name}")

    @classmethod
    def from_file(cls, path):
        cfg, t = W.load(path)
        m = cls(cfg)
        m.load_tensors(t)
        return m

