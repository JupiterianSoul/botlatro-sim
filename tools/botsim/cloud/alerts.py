import json
import os
import secrets
import time
import urllib.request

NTFY_DEFAULT = "https://ntfy.sh"


def topic_file():
    return os.environ.get("BOTSIM_NTFY_TOPIC_FILE") or os.path.join(
        os.environ.get("BOTSIM_CONFIG") or os.path.expanduser("~/.config/botsim"), "ntfy_topic")


def read_topic(path=None):
    try:
        with open(path or topic_file()) as f:
            return f.read().strip() or None
    except OSError:
        return None


def ensure_topic(path=None):
    path = path or topic_file()
    t = read_topic(path)
    if t:
        return t, False
    t = "botlatro-" + secrets.token_hex(12)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(t + "\n")
    return t, True


def ascii_header(s):
    return s.encode("ascii", "replace").decode("ascii")


def send(base, topic, title, message, priority=3, tags="", click=None, timeout=10):
    url = (base or NTFY_DEFAULT).rstrip("/") + "/" + topic
    headers = {"Title": ascii_header(title), "Priority": str(priority)}
    if tags:
        headers["Tags"] = tags
    if click:
        headers["Click"] = click
    req = urllib.request.Request(url, data=message.encode("utf-8"), method="POST", headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return 200 <= r.status < 300


def pct(n, d):
    return "%.1f%%" % (100.0 * n / d) if d else "n/a"


class Alerter:
    def __init__(self, base, topic, state_path, click=None, sender=send):
        self.base = base
        self.topic = topic
        self.state_path = state_path
        self.click = click
        self.sender = sender
        self.sent = {}
        try:
            with open(state_path) as f:
                self.sent = json.load(f).get("sent", {})
        except (OSError, ValueError):
            self.sent = {}

    def save(self):
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        tmp = self.state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"sent": self.sent}, f)
        os.replace(tmp, self.state_path)

    def fire(self, key, title, message, priority=3, tags=""):
        if key in self.sent:
            return False
        try:
            ok = self.sender(self.base, self.topic, title, message, priority=priority, tags=tags, click=self.click)
        except Exception:
            ok = False
        if ok:
            self.sent[key] = time.time()
            self.save()
        return ok

    def check(self, s):
        out = []
        run = s.get("run") or "run"
        tag = " [demo]" if s.get("demo") else ""
        states = s.get("job_states") or {}
        ctl = s.get("control") or {}
        money = s.get("money") or {}
        now = s.get("now") or time.time()
        if any(v in ("starting", "running") for v in states.values()) or s.get("games"):
            dl = s.get("deadline")
            msg = "%d boxes. Boxes delete themselves at %s. Spent so far %.2f of %.2f EUR." % (
                len(s.get("boxes") or []), time.strftime("%H:%M", time.localtime(dl)) if dl else "unknown",
                money.get("spent", 0), money.get("cap", 100))
            if self.fire("start", "Bot-latro %s started%s" % (run, tag), msg, 3, "rocket"):
                out.append("start")
        best = s.get("best")
        if best and best.get("new"):
            key = "best:%s" % best["gen"]
            ref = best.get("vs") or ""
            msg = "Generation %s wins %s of %d fixed seeds (95%% CI %s to %s)%s." % (
                best["gen"], pct(best["wins"], best["n"]), best["n"], best.get("lo", "?"), best.get("hi", "?"), ref)
            if self.fire(key, "New best: generation %s%s" % (best["gen"], tag), msg, 3, "trophy"):
                out.append(key)
        reason = ctl.get("reason") or s.get("stop_request")
        if (ctl.get("state") in ("stopping", "stopped") and reason == "emergency") or s.get("stop_request") == "emergency":
            if self.fire("stop", "Stop pressed on %s%s" % (run, tag), "Emergency stop: the job saves, results are collected, the boxes are deleted.", 4, "octagonal_sign"):
                out.append("stop")
        done = ("done", "saved", "failed", "killed", "exit")
        finished = ctl.get("state") == "stopped" or (states and all(v in done for v in states.values()))
        if finished and "start" in self.sent:
            msg = "%s games. %s" % (format(int(s.get("games") or 0), ","), s.get("summary") or "")
            if self.fire("finished", "Bot-latro %s finished%s" % (run, tag), msg.strip(), 3, "checkered_flag"):
                out.append("finished")
        dl = s.get("deadline")
        if dl and not finished and 0 < dl - now <= float(s.get("deadline_lead", 600)):
            msg = "Boxes delete themselves at %s (in %d min). The job is asked to save a few minutes before." % (
                time.strftime("%H:%M", time.localtime(dl)), max(1, round((dl - now) / 60)))
            if self.fire("deadline", "Deletion soon on %s%s" % (run, tag), msg, 4, "hourglass"):
                out.append("deadline")
        phase = s.get("phase") or ""
        seen = getattr(self, "_phase", None)
        if seen is None or seen[0] != phase:
            self._phase = (phase, now)
        elif phase and not finished and now - seen[1] >= float(s.get("stall_after", 1800)):
            key = "stall:%s:%d" % (phase, seen[1])
            msg = "No progress for %d min, still at: %s" % (round((now - seen[1]) / 60), phase)
            if self.fire(key, "Training stuck on %s%s" % (run, tag), msg, 5, "warning"):
                out.append("stall")
        cap, spent = float(money.get("cap") or 0), float(money.get("spent") or 0)
        for level, prio in ((0.95, 5), (0.8, 4)):
            if cap and spent >= level * cap:
                key = "cap%d" % round(level * 100)
                msg = "Spent %.2f of %.2f EUR (%d%%). This run %.2f EUR." % (spent, cap, round(100 * spent / cap), money.get("run_spent", 0))
                if self.fire(key, "Spend at %d%% of the cap%s" % (round(level * 100), tag), msg, prio, "warning"):
                    out.append(key)
                break
        return out
