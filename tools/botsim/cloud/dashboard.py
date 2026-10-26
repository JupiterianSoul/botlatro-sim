import argparse
import glob
import hmac
import http.server
import json
import math
import os
import re
import secrets
import socket
import sys
import tarfile
import threading
import time
import urllib.parse
import urllib.request

CLOUD = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, CLOUD)
from common import load_json, box_cost, ledger_spent, CAP_EUR, CREDIT_EUR
import alerts

ETC = os.environ.get("BOTSIM_ETC", "/etc/botsim")
HOME = os.environ.get("BOTSIM_HOME", "/opt/botsim")
RUN_DIR = os.path.join(HOME, "run")
LEDGER = os.environ.get("BOTSIM_LEDGER", os.path.join(CLOUD, "spend.json"))
PAGE = os.path.join(CLOUD, "dashboard.html")
STATE_DIR = os.environ.get("BOTSIM_DASH_STATE") or os.path.expanduser("~/.cache/botsim-dash")
TB = 300
CHUNK = 64 << 20
NODE_CHUNK = 4 << 20
NG = 8
NA = 8
CELL = NG + 2 * NA
XFER = os.environ.get("BOTSIM_XFER") or os.path.join(HOME, "xfer")
XFER_MAX = 512 << 20
XFER_NAME = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")
DONE_STATES = ("done", "saved", "failed", "killed", "exit")


def load_avg():
    try:
        return round(os.getloadavg()[0], 2)
    except OSError:
        return None


def job_alive():
    try:
        pid = int(open(os.path.join(RUN_DIR, "job.pid")).read().strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def read_lines(path, offset, limit=CHUNK):
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read(limit)
    except FileNotFoundError:
        return [], offset
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    out, pos = [], 0
    while pos <= end:
        nl = data.index(b"\n", pos)
        line = data[pos:nl]
        if line.strip():
            try:
                row = json.loads(line)
                if isinstance(row, dict):
                    out.append((row, offset + pos, nl - pos))
            except ValueError:
                pass
        pos = nl + 1
    return out, offset + end + 1


def wilson(w, n, z=1.96):
    if n <= 0:
        return None, None
    p = w / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def num(v, default=0):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else default


class Tail:
    def __init__(self, name, paths):
        self.name = name
        self.paths = paths
        self.offset = 0

    def pick(self):
        best, size = None, -1
        for p in self.paths:
            try:
                s = os.path.getsize(p)
            except OSError:
                continue
            if s > size:
                best, size = p, s
        return best, size


class Filt:
    def __init__(self, q):
        def one(k, d=""):
            v = q.get(k)
            return (v[0] if isinstance(v, list) else v) if v else d

        def rng(k):
            v = one(k)
            if not v or "-" not in v:
                return None, None
            a, _, b = v.partition("-")
            try:
                return (int(a) if a else None), (int(b) if b else None)
            except ValueError:
                return None, None

        self.g0, self.g1 = rng("g")
        self.a0, self.a1 = rng("a")
        self.decks = {d for d in one("d").split(",") if d}
        self.stakes = {int(s) for s in one("s").split(",") if s.strip().isdigit()}
        self.chal = one("c", "any")
        self.res = one("r", "any")
        try:
            self.win = max(0, int(one("w", "0")))
        except ValueError:
            self.win = 0
        self.split = one("sp", "stake")
        self.key = json.dumps([self.g0, self.g1, self.a0, self.a1, sorted(self.decks), sorted(self.stakes), self.chal, self.res, self.win, self.split])

    def gen_ok(self, gen):
        return (self.g0 is None or gen >= self.g0) and (self.g1 is None or gen <= self.g1)

    def base(self, gen, deck, stake, chal):
        if self.g0 is not None and gen < self.g0:
            return False
        if self.g1 is not None and gen > self.g1:
            return False
        if self.decks and deck not in self.decks:
            return False
        if self.stakes and stake not in self.stakes:
            return False
        if self.chal == "none":
            return not chal
        if self.chal != "any":
            return chal == self.chal
        return True

    def won_ok(self, won):
        return self.res == "any" or (self.res == "won") == bool(won)

    def ante_ok(self, ante):
        if ante == 0:
            return self.a0 is None and self.a1 is None
        return (self.a0 is None or ante >= self.a0) and (self.a1 is None or ante <= self.a1)

    def tbmin(self, now):
        return int((now - self.win) // TB) if self.win else None

    def t_ok(self, t, now):
        return not self.win or t >= now - self.win

    def split_of(self, deck, stake, chal):
        if self.split == "deck":
            return deck
        if self.split == "chal":
            return chal or "standard"
        if self.split == "none":
            return "all"
        return str(stake)


class Agg:
    def __init__(self):
        self.lock = threading.RLock()
        self.version = 0
        self.G = {}
        self.D = {}
        self.J = {}
        self.EV = {}
        self.gens = {}
        self.prog = {}
        self.states = {}
        self.first_state = {}
        self.bench = None
        self.ckpt = None
        self.records = []
        self.rec_by_id = {}
        self.events = []
        self.seq = 0
        self.decks, self.stakes, self.chals, self.sets = set(), set(), set(), {}
        self.gmin = self.gmax = None
        self.demo = False
        self.job = None
        self.n_games = 0
        self.t_min = self.t_max = None
        self.cache = {}

    def event(self, t, level, msg):
        self.seq += 1
        self.events.append((self.seq, t, level, msg))
        if len(self.events) > 400:
            del self.events[:100]

    def feed(self, box, r, path, off, ln):
        t = r.get("t")
        if not isinstance(t, (int, float)):
            return
        ty = r.get("type")
        g = r.get("gen")
        if isinstance(g, (int, float)) and not isinstance(g, bool) and ty != "eval":
            self.gmin = g if self.gmin is None else min(self.gmin, g)
            self.gmax = g if self.gmax is None else max(self.gmax, g)
        self.t_min = t if self.t_min is None else min(self.t_min, t)
        self.t_max = t if self.t_max is None else max(self.t_max, t)
        if ty == "game":
            self.add_game(r, t)
        elif ty == "games":
            self.add_games_v1(r, t)
        elif ty == "progress" and isinstance(r.get("games"), (int, float)):
            self.prog.setdefault(box, []).append((t, r["games"], num(r.get("decisions"), None), num(r.get("sims"), None),
                                                 num(r.get("work_done"), None), num(r.get("work_total"), None),
                                                 num(r.get("load1"), None), r.get("workers"), r.get("gen"), r.get("cores")))
        elif ty == "gen" and isinstance(g, (int, float)):
            d = self.gens.setdefault(int(g), {"gen": int(g)})
            for k, v in r.items():
                if k not in ("type", "box") and isinstance(v, (int, float)) and not isinstance(v, bool):
                    d[k] = v
        elif ty == "eval":
            self.add_eval(r, t)
        elif ty == "record":
            self.add_record(box, r, t, path, off, ln)
        elif ty == "state":
            prev = self.states.get(box, {}).get("state")
            self.states[box] = r
            self.first_state.setdefault(box, r)
            if r.get("demo") or r.get("job") == "fake":
                self.demo = True
            if r.get("job"):
                self.job = r.get("job")
            if r.get("state") != prev:
                self.event(t, "warn" if r.get("state") in ("failed", "killed") else "info",
                           "%s: %s%s" % (box, r.get("state"), (" (" + str(r["msg"]) + ")") if r.get("msg") else ""))
        elif ty == "bench":
            if self.bench is None or t >= self.bench["t"]:
                self.bench = dict(r, box=box)
        elif ty == "checkpoint":
            self.ckpt = dict(r, box=box)
        elif ty == "log":
            self.event(t, r.get("level") or "info", "%s: %s" % (box, str(r.get("msg", ""))[:300]))

    def add_game(self, r, t):
        gen = int(num(r.get("gen")))
        deck = str(r.get("deck") or "?")
        stake = int(num(r.get("stake")))
        chal = str(r.get("chal") or "")
        won = 1 if r.get("won") else 0
        ante = int(num(r.get("ante")))
        tb = int(t // TB)
        k = (gen, deck, stake, chal, won, ante, tb)
        c = self.G.get(k)
        if c is None:
            c = self.G[k] = [0.0] * CELL
        dec = num(r.get("dec"))
        c[0] += 1
        c[1] += num(r.get("round"))
        c[2] += num(r.get("money"))
        c[3] += num(r.get("hands"))
        c[4] += num(r.get("discards"))
        c[5] += dec
        c[6] += num(r.get("sims")) * dec
        c[7] += num(r.get("dur"))
        mpa = r.get("mpa")
        if isinstance(mpa, list):
            for i, m in enumerate(mpa[:NA]):
                if isinstance(m, (int, float)):
                    c[NG + i] += m
                    c[NG + NA + i] += 1
        if not won:
            dk = (gen, deck, stake, chal, ante, tb, str(r.get("death") or "?"))
            self.D[dk] = self.D.get(dk, 0) + 1
        js = r.get("jokers")
        if isinstance(js, list):
            for j in set(js):
                jk = (gen, deck, stake, chal, won, ante, str(j))
                self.J[jk] = self.J.get(jk, 0) + 1
        self.decks.add(deck)
        self.stakes.add(stake)
        if chal:
            self.chals.add(chal)
        self.n_games += 1

    def add_games_v1(self, r, t):
        gen, deck, stake = int(num(r.get("gen"))), str(r.get("deck") or "?"), int(num(r.get("stake")))
        n, w = int(num(r.get("games"))), int(num(r.get("wins")))
        tb = int(t // TB)
        for won, cnt in ((1, w), (0, n - w)):
            if cnt > 0:
                k = (gen, deck, stake, "", won, 0, tb)
                c = self.G.get(k)
                if c is None:
                    c = self.G[k] = [0.0] * CELL
                c[0] += cnt
        self.decks.add(deck)
        self.stakes.add(stake)
        self.n_games += max(0, n)

    def add_eval(self, r, t):
        who = str(r.get("who") or ("gen" if r.get("gen") is not None else "?"))
        gen = int(num(r.get("gen"), -1)) if who == "gen" else -1
        st = str(r.get("set") or "default")
        k = (st, who, gen, str(r.get("deck") or "*"), int(num(r.get("stake"))))
        n = num(r.get("n"))
        e = self.EV.setdefault(k, [0, 0, 0.0, 0.0, 0.0, 0])
        e[0] += n
        e[1] += num(r.get("wins"))
        e[2] += num(r.get("ante")) * n
        e[3] = max(e[3], t)
        if r.get("ante_sq") is not None:
            e[4] += num(r.get("ante_sq"))
            e[5] += n
        self.sets[st] = max(self.sets.get(st, 0), t)
        if r.get("promoted") and who == "gen":
            self.EV.setdefault((st, "_promoted", gen, "*", 0), [0, 0, 0.0, t])

    def add_record(self, box, r, t, path, off, ln):
        rid = str(r.get("id") or "%s-%d" % (box, off))
        moves = r.get("moves") if isinstance(r.get("moves"), list) else []
        meta = {"id": rid, "t": t, "box": box, "gen": int(num(r.get("gen"))), "deck": str(r.get("deck") or "?"),
                "stake": int(num(r.get("stake"))), "chal": str(r.get("chal") or ""), "won": 1 if r.get("won") else 0,
                "ante": int(num(r.get("ante"))), "seed": r.get("seed"), "moves": len(moves), "death": r.get("death"),
                "_src": path, "_off": off, "_len": ln}
        if rid not in self.rec_by_id:
            self.records.append(meta)
        self.rec_by_id[rid] = meta

    def eval_view(self, f, set_name=None):
        if not self.sets:
            return None
        st = set_name if set_name in self.sets else max(self.sets, key=self.sets.get)
        gen_rows, refs, promoted = {}, {}, set()
        for (s, who, gen, deck, stake), e in self.EV.items():
            if s != st:
                continue
            if who == "_promoted":
                promoted.add(gen)
                continue
            if deck != "*" and f.decks and deck not in f.decks:
                continue
            if stake and f.stakes and stake not in f.stakes:
                continue
            if who == "gen":
                if not f.gen_ok(gen):
                    continue
                d = gen_rows.setdefault(gen, [0, 0, 0.0, 0.0, 0.0, 0])
            else:
                d = refs.setdefault(who, [0, 0, 0.0, 0.0, 0.0, 0])
            d[0] += e[0]
            d[1] += e[1]
            d[2] += e[2]
            d[3] = max(d[3], e[3])
            d[4] += e[4]
            d[5] += e[5]

        def row(name, d):
            lo, hi = wilson(d[1], d[0])
            ante = d[2] / d[0] if d[0] else None
            alo = ahi = None
            if ante is not None and d[5] and d[5] == d[0] and d[0] > 1:
                var = max(0.0, (d[4] - d[0] * ante * ante) / (d[0] - 1))
                half = 1.96 * math.sqrt(var / d[0])
                alo, ahi = ante - half, ante + half
            return {"who": name, "n": d[0], "wins": d[1], "rate": d[1] / d[0] if d[0] else None, "lo": lo, "hi": hi,
                    "ante": ante, "ante_lo": alo, "ante_hi": ahi, "t": d[3]}

        gens = []
        best, best_key = None, None
        for gen in sorted(gen_rows):
            rw = row("gen", gen_rows[gen])
            rw["gen"] = gen
            rw["promoted"] = gen in promoted
            prev = best
            key = (rw["ante"], rw["wins"])
            better = rw["ante"] is not None and (best_key is None or key > best_key)
            if (gen in promoted) if promoted else better:
                best, best_key = gen, key
            rw["best_before"] = prev
            gens.append(rw)
        return {"set": st, "gens": gens, "refs": [row(k, v) for k, v in sorted(refs.items())], "best": best}

    def view(self, f, now):
        tbmin = f.tbmin(now)
        tot = [0.0] * CELL
        wins = 0.0
        ante_known = [0.0, 0.0]
        by_gen, by_tb = {}, {}
        ante = {}
        heat = {}
        econ = {0: [0.0] * (2 * NA), 1: [0.0] * (2 * NA)}
        jden = [0.0, 0.0]
        sv_n = {}
        for k, c in self.G.items():
            gen, deck, stake, chal, won, an, tb = k
            if not f.base(gen, deck, stake, chal) or not f.won_ok(won) or not f.ante_ok(an):
                continue
            n = c[0]
            if an:
                jden[won] += n
            if tbmin is not None and tb < tbmin:
                continue
            for i in range(CELL):
                tot[i] += c[i]
            if won:
                wins += n
            if an:
                ante_known[0] += n
                ante_known[1] += an * n
                a = ante.setdefault(an, [0, 0])
                a[won] += n
            sv = f.split_of(deck, stake, chal)
            sv_n[sv] = sv_n.get(sv, 0) + n
            for key, store in (((gen, sv), by_gen), ((tb, sv), by_tb)):
                d = store.get(key)
                if d is None:
                    d = store[key] = [0, 0, 0.0, 0]
                d[0] += n
                if won:
                    d[1] += n
                if an:
                    d[2] += an * n
                    d[3] += n
            h = heat.get((gen, deck, stake))
            if h is None:
                h = heat[(gen, deck, stake)] = [0, 0]
            h[0] += n
            if won:
                h[1] += n
            e = econ[won]
            for i in range(2 * NA):
                e[i] += c[NG + i]
        n = tot[0]
        lo, hi = wilson(wins, n)
        tiles = {"games": n, "wins": wins, "rate": wins / n if n else None, "lo": lo, "hi": hi,
                 "ante": ante_known[1] / ante_known[0] if ante_known[0] else None,
                 "round": tot[1] / n if n else None, "money": tot[2] / n if n else None,
                 "dec": tot[5] / n if n else None, "spd": tot[6] / tot[5] if tot[5] else None,
                 "dur": tot[7] / n if n else None}
        keep = sorted(sv_n, key=lambda s: -sv_n[s])
        if f.split == "deck" and len(keep) > 8:
            top = set(keep[:7])
        else:
            top = None

        def fold(store):
            out = {}
            for (x, sv), d in store.items():
                if top is not None and sv not in top:
                    sv = "other"
                e = out.setdefault(sv, {}).setdefault(x, [0, 0, 0.0, 0])
                for i in range(4):
                    e[i] += d[i]
            return {sv: [[x] + v for x, v in sorted(pts.items())] for sv, pts in out.items()}

        win_gen = fold(by_gen)
        win_tb = {sv: [[p[0] * TB + TB / 2] + p[1:] for p in pts] for sv, pts in fold(by_tb).items()}
        per_gen_n = {}
        for (gen, deck, stake), h in heat.items():
            per_gen_n[gen] = per_gen_n.get(gen, 0) + h[0]
        topn = max(per_gen_n.values() or [0])
        big = [g for g, c in per_gen_n.items() if c >= 0.3 * topn]
        heat_gen = max(big) if big else None
        hm_all, hm_latest = {}, {}
        for (gen, deck, stake), h in heat.items():
            for store, ok in ((hm_all, True), (hm_latest, gen == heat_gen)):
                if ok:
                    c = store.setdefault(deck, {}).setdefault(str(stake), [0, 0])
                    c[0] += h[0]
                    c[1] += h[1]
        death, death_total, death_stake = {}, 0, {}
        if f.res != "won":
            for (gen, deck, stake, chal, an, tb, blind), cnt in self.D.items():
                if tbmin is not None and tb < tbmin:
                    continue
                if not f.base(gen, deck, stake, chal) or not f.ante_ok(an):
                    continue
                d = death.setdefault(blind, {"n": 0, "stakes": {}, "antes": {}})
                d["n"] += cnt
                d["stakes"][stake] = d["stakes"].get(stake, 0) + cnt
                d["antes"][an] = d["antes"].get(an, 0) + cnt
                death_stake[stake] = death_stake.get(stake, 0) + cnt
                death_total += cnt
        top_death = sorted(death.items(), key=lambda kv: -kv[1]["n"])[:12]
        jok = {}
        for (gen, deck, stake, chal, won, an, j), cnt in self.J.items():
            if not f.base(gen, deck, stake, chal) or not f.won_ok(won) or not f.ante_ok(an):
                continue
            d = jok.setdefault(j, [0, 0])
            d[won] += cnt
        jl = []
        for j, (l, w) in jok.items():
            jl.append([j, w / jden[1] if jden[1] else 0.0, l / jden[0] if jden[0] else 0.0, w, l])
        if jden[1] and jden[0]:
            jl.sort(key=lambda x: -(x[1] + 0.25 * x[2]))
        else:
            jl.sort(key=lambda x: -(x[3] + x[4]))
        econ_out = {}
        for won, e in econ.items():
            econ_out["won" if won else "lost"] = [[i + 1, e[i] / e[NA + i], e[NA + i]] for i in range(NA) if e[NA + i] > 0]
        gens = [dict(v) for g, v in sorted(self.gens.items()) if f.gen_ok(g)]
        return {"tiles": tiles, "win_gen": win_gen, "win_tb": win_tb, "split": f.split,
                "ante": [[a, v[0], v[1]] for a, v in sorted(ante.items())],
                "heat": {"all": hm_all, "latest": hm_latest, "gen": heat_gen},
                "death": {"total": death_total, "stakes": {str(k): v for k, v in death_stake.items()},
                          "top": [{"blind": b, "n": d["n"], "stakes": {str(k): v for k, v in d["stakes"].items()},
                                   "antes": {str(k): v for k, v in d["antes"].items()}} for b, d in top_death]},
                "jokers": {"won_games": jden[1], "lost_games": jden[0], "top": jl[:14]},
                "econ": econ_out, "eval": self.eval_view(f), "train": gens,
                "records": sum(1 for m in self.records if self.rec_ok(m, f, now))}

    def rec_ok(self, m, f, now):
        return f.base(m["gen"], m["deck"], m["stake"], m["chal"]) and f.won_ok(m["won"]) and f.ante_ok(m["ante"]) and f.t_ok(m["t"], now)

    def throughput(self, now, mode):
        allp = [p for rs in self.prog.values() for p in rs]
        if not allp:
            return {"t0": None, "boxes": {}, "total": []}
        t0 = min(p[0] for p in allp)
        t1 = max(p[0] for p in allp)
        width = max(30.0, (t1 - t0) / 60.0)
        nb = int((t1 - t0) // width) + 1
        total = {}
        boxes = {}
        for name, rs in self.prog.items():
            acc = {}
            for a, b in zip(rs, rs[1:]):
                dt = b[0] - a[0]
                if dt <= 0:
                    continue
                k = min(nb - 1, int((b[0] - t0) // width))
                e = acc.setdefault(k, [0.0, 0.0, 0.0, 0.0, 0])
                e[0] += (b[1] - a[1]) / dt
                if a[2] is not None and b[2] is not None:
                    e[1] += (b[2] - a[2]) / dt
                    if a[3] is not None and b[3] is not None and b[2] > a[2]:
                        e[2] += b[3] - a[3]
                        e[3] += b[2] - a[2]
                e[4] += 1
            pts = []
            for k in sorted(acc):
                e = acc[k]
                tm = t0 + (k + 0.5) * width
                pts.append([round(tm, 1), round(e[0] / e[4], 3), round(e[1] / e[4], 2), round(e[2] / e[3], 1) if e[3] else None])
                tt = total.setdefault(k, [tm, 0.0, 0.0, 0.0, 0.0])
                tt[1] += e[0] / e[4]
                tt[2] += e[1] / e[4]
                tt[3] += e[2]
                tt[4] += e[3]
            boxes[name] = pts
        tot = [[round(v[0], 1), round(v[1], 3), round(v[2], 2), round(v[3] / v[4], 1) if v[4] else None] for k, v in sorted(total.items())]
        return {"t0": t0, "boxes": boxes, "total": tot}


class BaseSource:
    def __init__(self):
        self.agg = Agg()
        self.tails = {}
        self.rlock = threading.Lock()
        threading.Thread(target=self.refresher, daemon=True).start()

    def tail_list(self):
        return []

    def refresh(self):
        with self.rlock:
            self.refresh_locked()

    def refresh_locked(self):
        for name, paths in self.tail_list():
            tl = self.tails.get(name)
            if tl is None:
                tl = self.tails[name] = Tail(name, paths)
            tl.paths = paths
            while True:
                path, size = tl.pick()
                if path is None or size <= tl.offset:
                    break
                rows, off = read_lines(path, tl.offset)
                if off == tl.offset:
                    break
                with self.agg.lock:
                    for r, o, ln in rows:
                        self.agg.feed(name, r, path, o, ln)
                    tl.offset = off
                    self.agg.version += 1

    def refresher(self):
        while True:
            try:
                self.refresh()
            except Exception as e:
                print("refresh failed: %s" % e, flush=True)
            time.sleep(2)


class BoxSource(BaseSource):
    mode = "box"

    def __init__(self):
        self.node = load_json(os.path.join(ETC, "node.json"), {}) or {}
        self.info = {}
        self.lock = threading.Lock()
        self.state_dir = os.path.join(STATE_DIR, str(self.node.get("run", "run")))
        self.mirror = os.path.join(self.state_dir, "mirror")
        os.makedirs(self.mirror, exist_ok=True)
        super().__init__()
        if self.node.get("role") == "head":
            threading.Thread(target=self.poll_nodes, daemon=True).start()

    def run(self):
        return load_json(os.path.join(ETC, "run.json"), {}) or {}

    def control(self):
        return load_json(os.path.join(HOME, "control.json"), {}) or {}

    def tail_list(self):
        me = self.node.get("name", "head")
        out = [(me, [os.path.join(RUN_DIR, "metrics.jsonl")])]
        names = [b["name"] for b in self.run().get("boxes", []) if b["name"] != me]
        names += [os.path.basename(d) for d in glob.glob(os.path.join(RUN_DIR, "boxes", "*")) if os.path.basename(d) not in names]
        for n in names:
            out.append((n, [os.path.join(RUN_DIR, "boxes", n, "metrics.jsonl"), os.path.join(self.mirror, n + ".jsonl")]))
        return out

    def poll_nodes(self):
        while True:
            run, ctl = self.run(), self.control()
            deleted = ctl.get("deleted") or {}
            for b in run.get("boxes", []):
                name = b["name"]
                if name == self.node.get("name") or name in deleted:
                    continue
                mp = os.path.join(self.mirror, name + ".jsonl")
                try:
                    off = os.path.getsize(mp)
                except OSError:
                    off = 0
                url = "http://%s:%s/%s/api/node?raw=1&since=%d" % (b["ip"], self.node["port"], self.node["secret"], off)
                try:
                    with urllib.request.urlopen(url, timeout=15) as r:
                        data = r.read()
                        hdr = r.headers
                    if data and int(hdr.get("X-Since", -1)) == off:
                        with open(mp, "ab") as fh:
                            fh.write(data)
                    try:
                        la = float(hdr.get("X-Load1"))
                    except (TypeError, ValueError):
                        la = None
                    with self.lock:
                        self.info[name] = {"load1": la,
                                           "cores": int(hdr.get("X-Cores") or 0) or None,
                                           "job_active": hdr.get("X-Job-Active") == "1", "seen": time.time()}
                except Exception:
                    pass
            time.sleep(5)

    def meta(self):
        run, ctl = self.run(), self.control()
        now = time.time()
        deleted = ctl.get("deleted") or {}
        me = self.node.get("name")
        boxes = []
        for b in run.get("boxes", []):
            with self.lock:
                info = dict(self.info.get(b["name"], {}))
            if b["name"] == me:
                info = {"load1": load_avg(), "cores": os.cpu_count(), "job_active": job_alive(), "seen": now}
            gone = b["name"] in deleted
            boxes.append({"name": b["name"], "type": b.get("type"), "role": b.get("role"), "cores": info.get("cores") or b.get("cores"),
                          "load1": None if gone else info.get("load1"), "job_active": False if gone else info.get("job_active"),
                          "alive": not gone and (now - info.get("seen", 0) < 60), "deleted": gone})
        spent = float(run.get("spent_before", 0))
        run_spent, per_hour, projected = 0.0, 0.0, 0.0
        deadline = min([float(b["deadline"]) for b in run.get("boxes", []) if b["name"] not in deleted and b.get("deadline")] or [0]) or None
        if ctl.get("keep_until"):
            deadline = min(deadline or 1e18, float(ctl["keep_until"]))
        for b in run.get("boxes", []):
            end = deleted.get(b["name"]) or now
            price = float(b["price_hourly_gross"])
            run_spent += box_cost(float(b["created"]), end, price)
            if b["name"] not in deleted:
                per_hour += price
                projected += box_cost(float(b["created"]), max(now, deadline or now), price)
            else:
                projected += box_cost(float(b["created"]), end, price)
        money = {"spent": spent + run_spent, "run_spent": run_spent, "cap": float(run.get("cap", CAP_EUR)), "run_cap": run.get("run_cap"),
                 "per_hour": per_hour, "credit": CREDIT_EUR, "before": spent, "projected": spent + projected}
        stop_req = None
        for p in ("STOP_REQUEST", "STOP_REQUEST.done"):
            try:
                stop_req = open(os.path.join(RUN_DIR, p)).read().strip() or "emergency"
                break
            except OSError:
                pass
        return {"run": run.get("run", self.node.get("run")), "boxes": boxes, "money": money, "deadline": deadline,
                "control": ctl, "can_stop": self.node.get("role") == "head", "stop_request": stop_req}

    def node_raw(self, since):
        path = os.path.join(RUN_DIR, "metrics.jsonl")
        try:
            with open(path, "rb") as f:
                f.seek(since)
                data = f.read(NODE_CHUNK)
                end = data.rfind(b"\n")
                if end < 0 and len(data) == NODE_CHUNK:
                    data += f.read(CHUNK)
                    end = data.rfind(b"\n")
        except (FileNotFoundError, ValueError):
            data, end = b"", -1
        return data[:end + 1] if end >= 0 else b""

    def node_payload(self, since):
        rows = []
        off = since
        if since >= 0:
            got, off = read_lines(os.path.join(RUN_DIR, "metrics.jsonl"), since, NODE_CHUNK)
            rows = [r for r, _, _ in got]
        return {"name": self.node.get("name"), "rows": rows, "offset": off,
                "load1": load_avg(), "cores": os.cpu_count(), "job_active": job_alive()}


class LocalSource(BaseSource):
    mode = "local"

    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.state_dir = os.path.join(STATE_DIR, "local")
        super().__init__()

    def tail_list(self):
        return [(os.path.basename(os.path.dirname(f)), [f]) for f in sorted(glob.glob(os.path.join(self.path, "*", "metrics.jsonl")))]

    def meta(self):
        run = load_json(os.path.join(self.path, "run.json"), {}) or {}
        ledger = load_json(LEDGER, {}) or {}
        rid = run.get("run") or os.path.basename(self.path)
        run_spent = sum(box_cost(e["created"], e.get("deleted") or time.time(), e["price_hourly_gross"])
                        for e in ledger.get("servers", []) if e.get("run") == rid)
        names = {n for n, _ in self.tail_list()} | {b["name"] for b in run.get("boxes", [])}
        by = {b["name"]: b for b in run.get("boxes", [])}
        boxes = [{"name": n, "type": by.get(n, {}).get("type"), "role": by.get(n, {}).get("role"), "cores": by.get(n, {}).get("cores"),
                  "load1": None, "job_active": False, "alive": False, "deleted": True} for n in sorted(names)]
        spent = ledger_spent(ledger)
        money = {"spent": spent, "run_spent": run_spent, "cap": float(ledger.get("cap_eur", CAP_EUR)),
                 "run_cap": run.get("run_cap"), "per_hour": 0.0, "credit": float(ledger.get("credit_eur", CREDIT_EUR)),
                 "before": spent - run_spent, "projected": spent}
        return {"run": rid, "boxes": boxes, "money": money, "deadline": None, "control": {"state": "history"}, "can_stop": False,
                "stop_request": None}


def rate_of(rs, window):
    if len(rs) < 2:
        return None
    last = rs[-1]
    first = last
    for r in reversed(rs):
        if last[0] - r[0] > window:
            break
        first = r
    if first is last:
        first = rs[-2]
    dt = last[0] - first[0]
    return (last[1] - first[1]) / dt if dt > 0 else None


def build_state(src):
    now = time.time()
    meta = src.meta()
    agg = src.agg
    with agg.lock:
        total_games, total_gps, per_box = 0, 0.0, {}
        left, basis = None, None
        for name, rs in agg.prog.items():
            if not rs:
                continue
            live = now - rs[-1][0] < 120 or src.mode == "local"
            rate = rate_of(rs, 60) if live else 0.0
            dps = None
            if live and len(rs) >= 2 and rs[-1][2] is not None:
                first = next((r for r in rs if rs[-1][0] - r[0] <= 60 and r[2] is not None), rs[-2])
                if first is rs[-1]:
                    first = rs[-2]
                dt = rs[-1][0] - first[0]
                if dt > 0 and first[2] is not None:
                    dps = (rs[-1][2] - first[2]) / dt
            per_box[name] = {"games": rs[-1][1], "gps": rate, "dps": dps, "workers": rs[-1][7], "load1": rs[-1][6], "last": rs[-1][0]}
            total_games += rs[-1][1]
            total_gps += rate or 0.0
            tot = [r for r in rs if r[4] is not None and r[5] is not None]
            if len(tot) < 2 or src.mode == "local" or now - tot[-1][0] > 120:
                continue
            last = tot[-1]
            first = next((r for r in tot if last[0] - r[0] <= 600), tot[0])
            dt = last[0] - first[0]
            if dt < 20:
                continue
            rate_w = (last[4] - first[4]) / dt
            if rate_w <= 0:
                continue
            rem = max(0.0, (last[5] - last[4]) / rate_w)
            if left is None or rem > left:
                left, basis = rem, int(dt)
        capped = False
        if left is not None and meta.get("deadline") and src.mode == "box" and left > meta["deadline"] - now:
            left, capped = max(0.0, meta["deadline"] - now), True
        states = {k: v.get("state") for k, v in agg.states.items()}
        msgs = {k: v.get("msg") for k, v in agg.states.items() if v.get("state") == "running" and v.get("msg")}
        boxes = []
        for b in meta["boxes"]:
            p = per_box.get(b["name"], {})
            boxes.append(dict(b, games=p.get("games", 0), gps=p.get("gps"), dps=p.get("dps"), workers=p.get("workers"),
                              load1=b.get("load1") if b.get("load1") is not None else p.get("load1"), job_state=states.get(b["name"]), job_msg=msgs.get(b["name"])))
        known = {b["name"] for b in boxes}
        for name, p in per_box.items():
            if name not in known:
                boxes.append({"name": name, "games": p["games"], "gps": p["gps"], "dps": p.get("dps"), "workers": p.get("workers"),
                              "load1": p.get("load1"), "job_state": states.get(name), "job_msg": msgs.get(name), "alive": src.mode == "box", "deleted": False})
        dps_total = sum(p["dps"] or 0 for p in per_box.values() if p.get("dps") is not None) if any(p.get("dps") is not None for p in per_box.values()) else None
        dims = {"decks": sorted(agg.decks), "stakes": sorted(agg.stakes), "chals": sorted(agg.chals),
                "gmin": agg.gmin, "gmax": agg.gmax, "sets": sorted(agg.sets)}
        ev = agg.eval_view(Filt({}))
        best = None
        if ev and ev["best"] is not None:
            b = next(g for g in ev["gens"] if g["gen"] == ev["best"])
            best = {"gen": b["gen"], "rate": b["rate"], "lo": b["lo"], "hi": b["hi"], "n": b["n"], "wins": b["wins"], "ante": b["ante"]}
        return {"mode": src.mode, "now": now, "run": meta["run"], "boxes": boxes, "games": max(total_games, agg.n_games),
                "games_logged": agg.n_games, "gps": round(total_gps, 2), "dps": dps_total, "gen": agg.gmax, "best": best,
                "money": meta["money"], "deadline": meta["deadline"], "time_left": left, "time_left_basis": basis, "time_left_capped": capped,
                "control": meta["control"], "can_stop": meta["can_stop"], "stop_request": meta.get("stop_request"),
                "demo": agg.demo, "job": agg.job, "phase": next((msgs[b["name"]] for b in boxes if b.get("role") == "head" and b["name"] in msgs), next(iter(msgs.values()), None)), "bench": agg.bench, "checkpoint": agg.ckpt, "dims": dims,
                "version": agg.version, "job_states": states, "alerts": bool(getattr(src, "alerter", None))}


def rnd(o):
    if isinstance(o, float):
        if abs(o) >= 1e6:
            return round(o, 1)
        return round(o, 3) if abs(o) >= 100 else float("%.5g" % o)
    if isinstance(o, list):
        return [rnd(x) for x in o]
    if isinstance(o, dict):
        return {k: rnd(v) for k, v in o.items()}
    return o


def build_view(src, q):
    f = Filt(q)
    agg = src.agg
    now = time.time()
    with agg.lock:
        c = agg.cache.get(f.key)
        fresh = c is not None and (c[0] == agg.version or now - c[1] < max(2.0, 5 * c[2])) and (not f.win or now - c[1] < 15)
        if not fresh:
            t0 = time.time()
            res = agg.view(f, now)
            res["throughput"] = agg.throughput(now, src.mode)
            res = rnd(res)
            if len(agg.cache) > 64:
                agg.cache.clear()
            c = agg.cache[f.key] = (agg.version, now, time.time() - t0, res)
        version, hit = c[0], c[3]
        try:
            ev = int((q.get("ev") or ["0"])[0])
        except ValueError:
            ev = 0
        events = [list(e) for e in agg.events if e[0] > ev][-80:]
    return {"version": version, "fkey": f.key, "panels": hit, "events": events, "ev": agg.seq}


def list_records(src, q):
    f = Filt(q)
    now = time.time()
    with src.agg.lock:
        rs = [m for m in src.agg.records if src.agg.rec_ok(m, f, now)]
    total = len(rs)
    rs = sorted(rs, key=lambda m: -m["t"])[:200]
    return {"total": total, "records": [{k: v for k, v in m.items() if not k.startswith("_")} for m in rs]}


def get_record(src, rid):
    with src.agg.lock:
        m = src.agg.rec_by_id.get(rid)
    if not m:
        return None
    try:
        with open(m["_src"], "rb") as f:
            f.seek(m["_off"])
            row = json.loads(f.read(m["_len"]))
    except (OSError, ValueError):
        return None
    row.pop("type", None)
    row["id"] = rid
    row["box"] = m["box"]
    return row


def alert_snapshot(src):
    s = build_state(src)
    ev = s.get("best")
    agg = src.agg
    with agg.lock:
        evv = agg.eval_view(Filt({}))
    best = None
    if evv and evv["best"] is not None and len(evv["gens"]) >= 2:
        b = next(g for g in evv["gens"] if g["gen"] == evv["best"])
        first = evv["gens"][0]["gen"]
        if b["gen"] != first:
            vs = ""
            rules = next((r for r in evv["refs"] if r["who"] == "rules"), None)
            if rules and rules["rate"] is not None:
                vs = ", rules bot %.1f%%" % (100 * rules["rate"])
            best = {"gen": b["gen"], "n": b["n"], "wins": b["wins"], "lo": "%.1f%%" % (100 * b["lo"]), "hi": "%.1f%%" % (100 * b["hi"]),
                    "vs": vs, "new": True}
    s["best"] = best
    summary = ""
    if ev:
        summary = "Best generation %s: average ante %.2f, %.1f%% wins on the fixed seeds." % (ev["gen"], ev.get("ante") or 0, 100 * (ev["rate"] or 0))
    s["summary"] = summary
    return s


def alert_loop(src):
    while True:
        try:
            for key in src.alerter.check(alert_snapshot(src)):
                with src.agg.lock:
                    src.agg.event(time.time(), "info", "phone alert sent: " + key)
        except Exception as e:
            print("alerts failed: %s" % e, flush=True)
        time.sleep(float(os.environ.get("BOTSIM_ALERT_EVERY", "15")))


def xfer_path(name):
    if not name or not XFER_NAME.match(name) or any(p in (".", "..") or p.startswith(".") for p in name.split("/")):
        return None
    return os.path.join(XFER, *name.split("/"))


def xfer_list(sub):
    base = xfer_path(sub) if sub else XFER
    out = []
    if base and os.path.isdir(base):
        for n in sorted(os.listdir(base)):
            fp = os.path.join(base, n)
            if os.path.isfile(fp) and not n.startswith("."):
                st = os.stat(fp)
                out.append({"name": n, "size": st.st_size, "mtime": st.st_mtime})
    return out


def make_handler(src, secret):
    prefix = "/" + secret

    class H(http.server.BaseHTTPRequestHandler):
        server_version = "botsim"

        def log_message(self, *a):
            pass

        def send(self, code, body, ctype="application/json", headers=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, separators=(",", ":")).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def route(self):
            path, _, query = self.path.partition("?")
            seg = path.split("/")
            if len(seg) < 2 or not hmac.compare_digest(seg[1].encode(), secret.encode()):
                return None, None
            return "/" + "/".join(seg[2:]), urllib.parse.parse_qs(query)

        def do_GET(self):
            path, q = self.route()
            if path is None:
                return self.send(404, "not found", "text/plain")
            if path == "/":
                if self.path.split("?")[0] == prefix:
                    self.send_response(302)
                    self.send_header("Location", prefix + "/")
                    self.end_headers()
                    return
                return self.send(200, open(PAGE, "rb").read(), "text/html; charset=utf-8")
            if path == "/api/state":
                return self.send(200, build_state(src))
            if path == "/api/view":
                out = build_view(src, q)
                v = (q.get("v") or [""])[0]
                if v == str(out["version"]) and (q.get("fk") or [""])[0] == out["fkey"] and not (q.get("w") or ["0"])[0].strip("0"):
                    out["panels"] = None
                return self.send(200, {"state": build_state(src), "view": out})
            if path == "/api/records":
                return self.send(200, list_records(src, q))
            if path == "/api/record":
                r = get_record(src, (q.get("id") or [""])[0])
                return self.send(200, r) if r else self.send(404, {"error": "no such record"})
            if path == "/api/node" and src.mode == "box":
                try:
                    since = int((q.get("since") or ["-1"])[0])
                except ValueError:
                    since = -1
                if (q.get("raw") or [""])[0] == "1" and since >= 0:
                    data = src.node_raw(since)
                    la = load_avg()
                    return self.send(200, data, "application/octet-stream", {
                        "X-Since": str(since), "X-Offset": str(since + len(data)), "X-Load1": "" if la is None else str(la),
                        "X-Cores": str(os.cpu_count() or 0), "X-Job-Active": "1" if job_alive() else "0"})
                return self.send(200, src.node_payload(since))
            if path == "/api/xfer" and src.mode == "box":
                if (q.get("ls") or [None])[0] is not None:
                    return self.send(200, {"files": xfer_list((q.get("ls") or [""])[0])})
                fp = xfer_path((q.get("get") or [""])[0])
                if not fp or not os.path.isfile(fp):
                    return self.send(404, {"error": "no such file"})
                with open(fp, "rb") as f:
                    return self.send(200, f.read(), "application/octet-stream")
            if path == "/api/results.tgz" and src.mode == "box":
                self.send_response(200)
                self.send_header("Content-Type", "application/gzip")
                self.end_headers()
                skip = {"boxes", "STOP", "STOP_REQUEST", "STOP_REQUEST.done", "job.pid"}
                with tarfile.open(fileobj=self.wfile, mode="w|gz") as t:
                    for name in sorted(os.listdir(RUN_DIR)):
                        if name not in skip:
                            t.add(os.path.join(RUN_DIR, name), arcname=name)
                return
            return self.send(404, "not found", "text/plain")

        def xfer_post(self, n):
            q = urllib.parse.parse_qs(self.path.partition("?")[2])
            fp = xfer_path((q.get("name") or [""])[0])
            if not fp or n > XFER_MAX:
                if n:
                    self.rfile.read(min(n, 4096))
                return self.send(400, {"error": "bad name or too big"})
            if (q.get("rm") or [""])[0] == "1":
                try:
                    os.remove(fp)
                except OSError:
                    pass
                return self.send(200, {"ok": True})
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            tmp = os.path.join(os.path.dirname(fp), ".part-" + os.path.basename(fp))
            left = n
            with open(tmp, "wb") as f:
                while left > 0:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    f.write(chunk)
                    left -= len(chunk)
            if left:
                os.remove(tmp)
                return self.send(400, {"error": "short body"})
            os.replace(tmp, fp)
            return self.send(200, {"ok": True, "size": n})

        def do_POST(self):
            path, _ = self.route()
            n = int(self.headers.get("Content-Length") or 0)
            if path == "/api/xfer" and src.mode == "box":
                return self.xfer_post(n)
            if n:
                self.rfile.read(min(n, 4096))
            if path is None or src.mode != "box":
                return self.send(404, "not found", "text/plain")
            if path == "/api/stop" and src.node.get("role") == "head":
                os.makedirs(RUN_DIR, exist_ok=True)
                p = os.path.join(RUN_DIR, "STOP_REQUEST")
                if not os.path.exists(p):
                    with open(p, "w") as f:
                        f.write("emergency")
                return self.send(200, {"ok": True})
            if path == "/api/node-stop":
                os.makedirs(RUN_DIR, exist_ok=True)
                open(os.path.join(RUN_DIR, "STOP"), "w").close()
                return self.send(200, {"ok": True})
            return self.send(404, "not found", "text/plain")

    return H


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    ap = argparse.ArgumentParser(description="botsim training dashboard")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--box", action="store_true", help="serve on a training box (reads /etc/botsim/node.json)")
    g.add_argument("--local", metavar="RESULTS_DIR", help="show pulled results, no box needed")
    ap.add_argument("--port", type=int)
    ap.add_argument("--secret")
    ap.add_argument("--host", help="bind address in local mode (default 127.0.0.1)")
    ap.add_argument("--dump", action="store_true", help="print the state JSON once and exit")
    ap.add_argument("--dump-view", metavar="QUERY", help="print the view JSON for a filter query (like d=b_red&s=1) and exit")
    a = ap.parse_args()
    if a.box:
        src = BoxSource()
        secret, port, host = src.node["secret"], int(src.node["port"]), os.environ.get("BOTSIM_BIND", "0.0.0.0")
        topic = src.node.get("ntfy_topic")
        if topic and src.node.get("role") == "head":
            src.alerter = alerts.Alerter(src.node.get("ntfy_url") or alerts.NTFY_DEFAULT, topic,
                                         os.path.join(src.state_dir, "alerts.json"))
            threading.Thread(target=alert_loop, args=(src,), daemon=True).start()
    else:
        src = LocalSource(a.local)
        secret, port, host = a.secret or secrets.token_urlsafe(18), a.port or free_port(), a.host or "127.0.0.1"
    if a.dump or a.dump_view is not None:
        src.refresh()
        if a.dump:
            print(json.dumps(build_state(src), indent=1))
        else:
            print(json.dumps(build_view(src, urllib.parse.parse_qs(a.dump_view)), indent=1))
        return
    srv = http.server.ThreadingHTTPServer((host, port), make_handler(src, secret))
    print("dashboard: http://%s:%d/%s/" % (host if host != "0.0.0.0" else socket.gethostname(), port, secret), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
