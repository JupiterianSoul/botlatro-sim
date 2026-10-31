import argparse
import glob
import json
import math
import os
import random
import sys
import time

import torch
import torch.nn.functional as Fn

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from bnn import records as R  # noqa: E402
from bnn.model import Net  # noqa: E402


def parse_cfg(text, dims):
    cfg = {"CF": dims["CF"], "JF": dims["JF"], "IF": dims["IF"], "GF": dims["GF"], "FA": dims["FA"], "E": 32, "H": 128,
           "VH": 32, "types": dims["types"]}
    for part in filter(None, text.split(",")):
        k, v = part.split("=")
        cfg[k] = int(v)
    return cfg


def load_data(paths, window, val_every=0, stakes=None):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(glob.glob(os.path.join(p, "*.bspr")), key=os.path.getmtime)
        else:
            files += sorted(glob.glob(p), key=os.path.getmtime)
    dims, recs, runs, val = None, [], [], []
    nrun = 0
    for f in files:
        d, r, x = R.read_lazy(f)
        if dims is None:
            dims = d
        key = ("GF", "CF", "JF", "IF", "FA", "types")
        assert all(d[k] == dims[k] for k in key), f
        runs += [run for run in r if not stakes or run["stake"] in stakes]
        pos = 0
        for run in r:
            part = x[pos:pos + run["n"]]
            pos += run["n"]
            if stakes and run["stake"] not in stakes:
                continue
            nrun += 1
            (val if val_every and nrun % val_every == 1 else recs).extend(part)
        recs += x[pos:]
    if window and len(recs) > window:
        recs = recs[-window:]
    return dims, runs, recs, val


def losses(model, b, ante_w, policy_min_sims=0, out=None, val_w=1.0, adv_w=0.0, depth_w=0.0, val_ante=False):
    z, ante, logits = model(b)
    if out is not None:
        out.append((torch.sigmoid(z).detach(), b["won"], ante.detach() * 8.0, b["ante"] * 8.0))
    lp = Fn.log_softmax(logits, -1)
    lp = torch.where(b["amask"] > 0, lp, torch.zeros_like(lp))
    pol = -(b["pi"] * lp).sum(-1)
    if adv_w > 0 or depth_w > 0:
        wt = torch.ones_like(pol)
        if adv_w > 0:
            top = b["pi"].topk(2, dim=-1).values
            wt = wt + adv_w * (top[:, 0] - top[:, 1])
        if depth_w > 0:
            wt = wt * (1 + depth_w * ((b["ante"] * 8.0 - 1.0) / 7.0).clamp(0.0, 8.0 / 7.0))
        pol = pol * wt / wt.mean()
    if policy_min_sims > 0:
        pm = (b["nsims"] >= policy_min_sims).to(pol.dtype)
        pol = (pol * pm).sum() / pm.sum().clamp(min=1.0)
    else:
        pol = pol.mean()
    val = Fn.binary_cross_entropy_with_logits(z, (b["ante"] * 8.0 / 9.0).clamp(0.0, 1.0) if val_ante else b["won"])
    aux = Fn.mse_loss(ante, b["ante"])
    return pol + val_w * val + ante_w * aux, pol.item(), val.item(), aux.item()


def validate(model, val, dims, batch, policy_min_sims):
    if not val:
        return None
    model.eval()
    tot, n, pairs = [0.0, 0.0, 0.0], 0, []
    with torch.no_grad():
        for i in range(0, len(val), batch):
            chunk = val[i:i + batch]
            _, lp, lv, la = losses(model, R.collate(chunk, dims), 1.0, policy_min_sims, pairs)
            for k, x in enumerate((lp, lv, la)):
                tot[k] += x * len(chunk)
            n += len(chunk)
    model.train()
    pw = torch.cat([p[0] for p in pairs])
    won = torch.cat([p[1] for p in pairs])
    pa = torch.cat([p[2] for p in pairs])
    ta = torch.cat([p[3] for p in pairs])
    return {"policy": round(tot[0] / n, 4), "value": round(tot[1] / n, 4), "ante": round(tot[2] / n, 4),
            "win_pred": round(pw.mean().item(), 4), "win_true": round(won.mean().item(), 4),
            "brier": round(((pw - won) ** 2).mean().item(), 5), "ante_mae": round((pa - ta).abs().mean().item(), 3),
            "ante_bias": round((pa - ta).mean().item(), 3), "records": n}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", nargs="+", default=[])
    ap.add_argument("--init", default="")
    ap.add_argument("--cfg", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--steps", type=int, default=1000)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--wd", type=float, default=1e-4)
    ap.add_argument("--ante-weight", type=float, default=1.0)
    ap.add_argument("--value-weight", type=float, default=1.0)
    ap.add_argument("--policy-min-sims", type=int, default=0)
    ap.add_argument("--window", type=int, default=2000000)
    ap.add_argument("--val-every", type=int, default=20)
    ap.add_argument("--val-max", type=int, default=4096)
    ap.add_argument("--epochs", type=float, default=0.0)
    ap.add_argument("--min-steps", type=int, default=100)
    ap.add_argument("--warmup", type=int, default=0)
    ap.add_argument("--threads", type=int, default=0)
    ap.add_argument("--chosen", type=float, default=0.0)
    ap.add_argument("--all-discards", type=int, default=0)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--log-every", type=int, default=100)
    ap.add_argument("--mix-data", nargs="+", default=[])
    ap.add_argument("--mix", type=float, default=0.0)
    ap.add_argument("--mix-smooth", type=float, default=0.0)
    ap.add_argument("--mix-window", type=int, default=2000000)
    ap.add_argument("--stakes", default="")
    ap.add_argument("--adv-weight", type=float, default=0.0)
    ap.add_argument("--depth-weight", type=float, default=0.0)
    ap.add_argument("--value-ante", type=int, default=0)
    a = ap.parse_args()
    if a.threads:
        torch.set_num_threads(a.threads)
    R.CHOSEN = a.chosen
    random.seed(a.seed)
    torch.manual_seed(a.seed)
    stakes = {int(k) for k in a.stakes.split(",") if k}
    dims, runs, recs, val = load_data(a.data, a.window, a.val_every, stakes) if a.data else (None, [], [], [])
    mix = []
    if a.mix_data and (a.mix > 0 or not a.data):
        mdims, mruns, mix, mval = load_data(a.mix_data, a.mix_window, 0 if a.data else a.val_every)
        if dims is None:
            dims = mdims
        elif mdims is not None:
            assert all(mdims[k] == dims[k] for k in ("GF", "CF", "JF", "IF", "FA", "types")), "mix pool dims differ"
        print(f"seer pool: {len(mix)} recs, {len(mruns)} games, wins {sum(r['won'] for r in mruns)}")
        if not a.data:
            recs, runs, val, mix = mix, mruns, mval, []
            a.mix = 0.0
    if not recs and val:
        recs, val = val, []
    if not recs:
        sys.exit("no records")
    if len(val) > a.val_max:
        val = random.Random(a.seed).sample(val, a.val_max)
    if a.all_discards:
        assert dims["CF"] == 39 and dims["FA"] == 35 and dims["types"].split(",")[1] == "discard", "feature layout changed"
        R.ALL_DISC, R.DISC_CAP = True, a.all_discards
        print("discard check %d actions %d differ %d bad expansions" % R.check_discards(random.Random(a.seed + 1).sample(recs, min(len(recs), 5000)), 5000))
    if a.epochs > 0:
        a.steps = min(a.steps, max(a.min_steps, math.ceil(a.epochs * len(recs) / a.batch)))
    model = Net.from_file(a.init) if a.init else Net(parse_cfg(a.cfg, dims))
    nw = sum(p.numel() for p in model.parameters())
    wins = sum(r["won"] for r in runs)
    print(f"records {len(recs)} runs {len(runs)} wins {wins} weights {nw} val {len(val)} steps {a.steps}")
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=a.wd)
    warm = max(0, min(a.warmup, a.steps - 1))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda k: (k + 1) / warm if k < warm else
                                              0.5 * (1 + math.cos(math.pi * (k - warm) / max(1, a.steps - warm))))
    v0 = validate(model, val, dims, a.batch, a.policy_min_sims) if a.init else None
    if v0:
        print("val0 " + json.dumps(v0, separators=(",", ":")))
    t0 = time.time()
    acc = [0.0, 0.0, 0.0, 0]
    for step in range(1, a.steps + 1):
        nm = min(len(mix), int(round(a.batch * a.mix))) if mix else 0
        rows = random.sample(recs, min(a.batch - nm, len(recs))) + (random.sample(mix, nm) if nm else [])
        batch = R.collate(rows, dims)
        if nm and a.mix_smooth > 0:
            k0 = len(rows) - nm
            am = batch["amask"][k0:]
            batch["pi"][k0:] = (1 - a.mix_smooth) * batch["pi"][k0:] + a.mix_smooth * am / am.sum(-1, keepdim=True).clamp(min=1.0)
        loss, lp, lv, la = losses(model, batch, a.ante_weight, a.policy_min_sims, val_w=a.value_weight, adv_w=a.adv_weight, depth_w=a.depth_weight, val_ante=bool(a.value_ante))
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        opt.step()
        sched.step()
        acc[0] += lp
        acc[1] += lv
        acc[2] += la
        acc[3] += 1
        if step % a.log_every == 0 or step == a.steps:
            n = acc[3]
            print(f"step {step} policy {acc[0] / n:.4f} value {acc[1] / n:.4f} ante {acc[2] / n:.4f} "
                  f"{step * a.batch / (time.time() - t0):.0f} samples/s")
            last = {"policy": round(acc[0] / n, 4), "value": round(acc[1] / n, 4), "ante": round(acc[2] / n, 4)}
            acc = [0.0, 0.0, 0.0, 0]
    v1 = validate(model, val, dims, a.batch, a.policy_min_sims)
    summary = {"records": len(recs), "runs": len(runs), "wins": wins, "steps": a.steps, "epochs": round(a.steps * a.batch / len(recs), 3),
               "train": last, "val": v1, "val0": v0}
    print("summary " + json.dumps(summary, separators=(",", ":")))
    model.save(a.out)
    print(f"saved {a.out}")


if __name__ == "__main__":
    main()
