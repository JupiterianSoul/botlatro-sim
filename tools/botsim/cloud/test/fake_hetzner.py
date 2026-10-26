import argparse
import copy
import http.server
import json
import os
import threading
import time
import urllib.parse
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "fixtures", "hetzner_real.json")


def load_fixture():
    with open(FIXTURE) as f:
        return json.load(f)


class State:
    def __init__(self, token, fail_type, fail_locations, make_available, ssh_pub, slow_post, fixed_ip):
        self.fx = load_fixture()
        self.token = token
        self.fail_type = fail_type
        self.fail_locations = set(fail_locations)
        self.slow_post = slow_post
        self.fixed_ip = fixed_ip
        self.types = {t["name"]: t for t in copy.deepcopy(self.fx["server_types"]["server_types"])}
        for name in make_available:
            for l in self.types[name]["locations"]:
                l["available"] = True
        self.ssh_keys = copy.deepcopy(self.fx["ssh_keys"])
        if ssh_pub:
            with open(ssh_pub) as f:
                self.ssh_keys["ssh_keys"][0]["public_key"] = f.read().strip()
        self.locations = {l["name"]: l for l in self.fx["locations"]["locations"]}
        self.servers = {}
        self.next_id = 1000
        self.lock = threading.Lock()
        self.log = []

    def make_server(self, sid, body):
        srv = copy.deepcopy(self.fx["server"])
        ip = self.fixed_ip or "127.0.0.%d" % (sid - 1000 + 1)
        srv.update({"id": sid, "name": body["name"], "status": "initializing", "labels": body.get("labels", {}),
                    "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "server_type": copy.deepcopy(self.types[body["server_type"]]),
                    "location": copy.deepcopy(self.locations[body.get("location", "fsn1")])})
        srv["public_net"]["ipv4"]["ip"] = ip
        srv["public_net"]["ipv4"]["id"] = sid
        return srv


def pagination(n):
    return {"pagination": {"last_page": 1, "next_page": None, "page": 1, "per_page": 50, "previous_page": None, "total_entries": n}}


def handler(st):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body):
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def err(self, code, ecode, msg):
            self.reply(code, {"error": {"code": ecode, "message": msg, "details": {}}})

        def auth(self):
            if self.headers.get("Authorization") != "Bearer " + st.token:
                self.err(401, "unauthorized", "unable to authenticate")
                return False
            return True

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(u.query)
            if u.path == "/_userdata":
                with st.lock:
                    return self.reply(200, {"user_data": getattr(st, "user_data", {}).get(q.get("name", [""])[0])})
            if u.path == "/_log":
                with st.lock:
                    return self.reply(200, {"log": st.log, "servers": list(st.servers.values())})
            if not self.auth():
                return
            st.log.append(["GET", self.path])
            if u.path == "/v1/servers":
                with st.lock:
                    for s in st.servers.values():
                        s["status"] = "running"
                    out = list(st.servers.values())
                sel = q.get("label_selector", [""])[0]
                for cond in filter(None, sel.split(",")):
                    k, _, v = cond.partition("=")
                    out = [s for s in out if s["labels"].get(k) == v]
                if "name" in q:
                    out = [s for s in out if s["name"] == q["name"][0]]
                return self.reply(200, {"servers": out, "meta": pagination(len(out))})
            if u.path == "/v1/server_types":
                return self.reply(200, {"server_types": list(st.types.values()), "meta": pagination(len(st.types))})
            if u.path == "/v1/pricing":
                return self.reply(200, st.fx["pricing"])
            if u.path == "/v1/ssh_keys":
                return self.reply(200, dict(st.ssh_keys, meta=pagination(len(st.ssh_keys["ssh_keys"]))))
            if u.path == "/v1/locations":
                return self.reply(200, st.fx["locations"])
            if u.path == "/v1/datacenters":
                return self.err(410, "gone", "datacenters are deprecated")
            if u.path.startswith("/v1/servers/"):
                sid = int(u.path.rsplit("/", 1)[1])
                if sid in st.servers:
                    return self.reply(200, {"server": st.servers[sid]})
                return self.err(404, "not_found", "server not found")
            self.err(404, "not_found", "no route")

        def do_POST(self):
            if not self.auth():
                return
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            st.log.append(["POST", self.path, {k: v for k, v in body.items() if k != "user_data"}])
            if self.path != "/v1/servers":
                return self.err(404, "not_found", "no route")
            t = st.types.get(body.get("server_type"))
            if not t:
                return self.err(422, "invalid_input", "unknown server type")
            if body.get("location") not in st.locations:
                return self.err(422, "invalid_input", "unknown location")
            avail = {l["name"]: l["available"] for l in t["locations"]}
            if body["server_type"] == st.fail_type or body.get("location") in st.fail_locations or not avail.get(body.get("location")):
                return self.err(412, "resource_unavailable", "server type %s is unavailable in %s" % (body["server_type"], body.get("location")))
            for s in st.servers.values():
                if s["name"] == body["name"]:
                    return self.err(409, "uniqueness_error", "server name is already used")
            with st.lock:
                st.next_id += 1
                sid = st.next_id
                srv = st.make_server(sid, body)
                srv["user_data_len"] = len(body.get("user_data", ""))
                st.servers[sid] = srv
                st.user_data = getattr(st, "user_data", {})
                st.user_data[body["name"]] = body.get("user_data", "")
            if st.slow_post:
                time.sleep(st.slow_post)
            self.reply(201, {"server": srv, "action": {"id": sid, "command": "create_server", "status": "running"},
                             "next_actions": [], "root_password": None})

        def do_DELETE(self):
            if not self.auth():
                return
            st.log.append(["DELETE", self.path])
            sid = int(self.path.rsplit("/", 1)[1])
            with st.lock:
                if sid not in st.servers:
                    return self.err(404, "not_found", "server not found")
                del st.servers[sid]
            self.reply(200, {"action": {"id": sid, "command": "delete_server", "status": "running"}})

    return H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--token", default="test-token")
    ap.add_argument("--fail-type")
    ap.add_argument("--fail-location", action="append", default=[])
    ap.add_argument("--make-available", action="append", default=[])
    ap.add_argument("--ssh-pub")
    ap.add_argument("--slow-post", type=float, default=0)
    ap.add_argument("--fixed-ip")
    a = ap.parse_args()
    st = State(a.token, a.fail_type, a.fail_location, a.make_available, a.ssh_pub, a.slow_post, a.fixed_ip)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), handler(st))
    print("fake hetzner on http://127.0.0.1:%d/v1" % srv.server_address[1], flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
