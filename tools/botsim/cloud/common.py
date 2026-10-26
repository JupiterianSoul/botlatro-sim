import json
import math
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API_DEFAULT = "https://api.hetzner.cloud/v1"
CAP_EUR = 100.0
CREDIT_EUR = 25.0
LABEL = "botsim=1"
HOUR = 3600


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__("%s %s: %s" % (status, code, message))
        self.status = status
        self.code = code
        self.message = message


class Api:
    def __init__(self, token, base=None, timeout=30):
        self.token = token
        self.base = (base or os.environ.get("BOTSIM_API") or API_DEFAULT).rstrip("/")
        self.timeout = timeout

    def call(self, method, path, body=None):
        data = None
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                err = json.loads(raw).get("error", {})
            except Exception:
                err = {}
            raise ApiError(e.code, err.get("code", "http_error"), err.get("message", raw[:200].decode("utf-8", "replace"))) from None
        return json.loads(raw) if raw else {}

    def get(self, path):
        return self.call("GET", path)

    def servers(self, selector=LABEL):
        out, page = [], 1
        while True:
            r = self.get("/servers?label_selector=%s&per_page=50&page=%d" % (urllib.request.quote(selector), page))
            out.extend(r.get("servers", []))
            nxt = (r.get("meta") or {}).get("pagination", {}).get("next_page")
            if not nxt:
                return out
            page = nxt

    def delete_server(self, sid):
        try:
            self.call("DELETE", "/servers/%d" % int(sid))
            return True
        except ApiError as e:
            if e.status == 404:
                return False
            raise


def read_token(path=None):
    path = path or os.environ.get("BOTSIM_TOKEN_FILE") or os.path.expanduser("~/.config/botsim/hetzner_token")
    with open(path) as f:
        tok = f.read().strip()
    if not tok:
        raise SystemExit("empty token file: " + path)
    return tok


def parse_time(s):
    if isinstance(s, (int, float)):
        return float(s)
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


def billed_hours(created, end):
    return max(1, math.ceil(max(0.0, end - created) / HOUR - 1e-9))


def box_cost(created, end, price_hourly):
    return billed_hours(created, end) * price_hourly


def next_hour_boundary(created, now):
    return created + billed_hours(created, now) * HOUR


def deadline_offset(hours, margin=180):
    secs = hours * HOUR
    full = math.ceil(hours - 1e-9) * HOUR
    return min(secs, full - margin)


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path, data, mode=None):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode if mode is not None else 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def ledger_spent(ledger, now=None):
    now = now or time.time()
    total = 0.0
    for e in ledger.get("servers", []):
        end = e.get("deleted") or now
        total += box_cost(e["created"], end, e["price_hourly_gross"])
    for a in ledger.get("adjustments", []):
        total += float(a.get("eur", 0))
    return total


def read_metrics(path, offset=0):
    rows = []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except FileNotFoundError:
        return rows, offset
    end = data.rfind(b"\n")
    if end < 0:
        return rows, offset
    for line in data[:end].split(b"\n"):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass
    return rows, offset + end + 1
