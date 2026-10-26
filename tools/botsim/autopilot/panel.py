import json
import os
import re
import subprocess
import threading
import time

import store

CACHE = os.environ.get("BOTSIM_AP_PANEL_CACHE") or os.path.expanduser("~/.cache/botsim/results")
MIN_INTERVAL = 60
LOG_LINES = 20

CELL_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)%\s*\((\d+)\)\s*$")
BEST_RE = re.compile(r"^Best fair checkpoint:\s*(.*?)\s*\((.*?),\s*(.*?)\)\s*$")


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def parse_board(results_md):
    lines = (results_md or "").splitlines()
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == "## Board":
            start = i + 1
            break
    out = {"checkpoint": None, "who": None, "set": None, "stakes": [], "decks": [], "cells": {}}
    if start is None:
        return out
    i = start
    while i < len(lines) and not lines[i].startswith("## "):
        ln = lines[i]
        m = BEST_RE.match(ln.strip())
        if m:
            out["checkpoint"], out["who"], out["set"] = m.group(1), m.group(2), m.group(3)
        elif ln.strip().startswith("| deck"):
            head = split_row(ln)
            out["stakes"] = [int(re.sub(r"\D", "", h) or 0) for h in head[1:]]
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                cols = split_row(lines[i])
                deck = cols[0]
                out["decks"].append(deck)
                for s, c in zip(out["stakes"], cols[1:]):
                    cm = CELL_RE.match(c)
                    if cm:
                        out["cells"]["%s|%d" % (deck, s)] = {"pct": float(cm.group(1)), "n": int(cm.group(2))}
                i += 1
            continue
        i += 1
    return out


def parse_status_line(results_md):
    for ln in (results_md or "").splitlines():
        if ln.startswith("step "):
            return ln.strip()
    return ""


def tail_log(log_md, n=LOG_LINES):
    lines = [ln.rstrip() for ln in (log_md or "").splitlines() if ln.strip()]
    return lines[-n:]


def num(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def gates_summary(state):
    out = []
    for step, g in sorted((state.get("gates") or {}).items()):
        g = g if isinstance(g, dict) else {}
        out.append({"step": step, "fails": int(num(g.get("fails"))), "last": g.get("last") or {}})
    return out


def spend_summary(state):
    paid = state.get("paid") or {}
    approved = num(paid.get("approved_eur"))
    spent = num(paid.get("spent_eur"))
    return {"spent_eur": round(spent, 2), "approved_eur": round(approved, 2),
            "round_cap_eur": round(num(paid.get("round_cap_eur")), 2),
            "fraction": round(min(1.0, spent / approved), 4) if approved > 0 else 0.0,
            "over": approved > 0 and spent > approved}


def job_summary(state):
    job = state.get("job")
    if not isinstance(job, dict):
        return None
    out = {"kind": job.get("kind")}
    for k in ("tag", "run_id", "run", "dispatched", "started", "deadline", "round_cost_eur"):
        if job.get(k) is not None:
            out[k] = job[k]
    return out


def live_link(state, hz_run):
    job = state.get("job")
    if not isinstance(job, dict) or job.get("kind") != "hetzner" or not isinstance(hz_run, dict):
        return None
    url = hz_run.get("dashboard_url")
    if not url:
        return None
    return {"run": job.get("run") or hz_run.get("run"), "url": url}


def summarize(state, results_md, log_md, hz_run=None, now=None):
    state = state if isinstance(state, dict) else {}
    return {
        "ok": bool(state),
        "status": state.get("status"),
        "reason": state.get("reason") or "",
        "step": state.get("step"),
        "attempt": state.get("attempt"),
        "profile": state.get("profile"),
        "stake": state.get("stake"),
        "updated": state.get("updated"),
        "gates": gates_summary(state),
        "spend": spend_summary(state),
        "flags": state.get("flags") or {},
        "job": job_summary(state),
        "live": live_link(state, hz_run),
        "log": tail_log(log_md),
        "board": parse_board(results_md),
        "headline": parse_status_line(results_md),
        "fetched": now,
    }


def run_git(root, *args, timeout=120):
    return subprocess.run(["git"] + list(args), cwd=root, env=store.git_env(), capture_output=True, text=True, timeout=timeout)


def refresh_cache(root=CACHE, remote=store.REMOTE):
    if not os.path.isdir(os.path.join(root, ".git")):
        os.makedirs(os.path.dirname(root), exist_ok=True)
        p = subprocess.run(["git", "clone", "--depth", "1", remote, root], env=store.git_env(),
                           capture_output=True, text=True, timeout=120)
        if p.returncode != 0:
            raise RuntimeError("clone failed: " + (p.stderr or "").strip()[-300:])
        return
    p = run_git(root, "fetch", "--depth", "1", "origin")
    if p.returncode != 0:
        raise RuntimeError("fetch failed: " + (p.stderr or "").strip()[-300:])
    p = run_git(root, "reset", "--hard", "FETCH_HEAD")
    if p.returncode != 0:
        raise RuntimeError("reset failed: " + (p.stderr or "").strip()[-300:])


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def read_cache(root=CACHE, sub="autopilot", now=None):
    base = os.path.join(root, sub)
    try:
        state = json.loads(read_text(os.path.join(base, "state.json")) or "{}")
    except ValueError:
        state = {}
    hz_run = None
    job = state.get("job") if isinstance(state, dict) else None
    if isinstance(job, dict) and job.get("kind") == "hetzner" and job.get("run") and re.match(r"^[A-Za-z0-9_.-]+$", str(job["run"])):
        try:
            hz_run = json.loads(read_text(os.path.join(base, "hz", "%s.json" % job["run"])) or "null")
        except ValueError:
            hz_run = None
    return summarize(state, read_text(os.path.join(base, "RESULTS.md")), read_text(os.path.join(base, "log.md")), hz_run, now)


class Fetcher:
    def __init__(self, root=CACHE, sub="autopilot", interval=MIN_INTERVAL, refresh=refresh_cache, clock=time.time):
        self.root, self.sub, self.interval, self.refresh, self.clock = root, sub, interval, refresh, clock
        self.lock = threading.Lock()
        self.last = 0.0
        self.error = None
        self.cached = None

    def get(self):
        with self.lock:
            now = self.clock()
            if self.cached is None or now - self.last >= self.interval:
                self.last = now
                try:
                    self.refresh(self.root)
                    self.error = None
                except Exception as e:
                    self.error = str(e)[:300]
                self.cached = read_cache(self.root, self.sub, int(now))
            out = dict(self.cached)
            out["error"] = self.error
            return out
