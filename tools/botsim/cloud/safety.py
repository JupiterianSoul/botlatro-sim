import os
import shutil
import signal
import subprocess
import tempfile
import time

HOST_KEY_ALGO = "ssh-ed25519"


class Interrupted(Exception):
    def __init__(self, where, sig):
        super().__init__("%s during %s" % (sig, where))
        self.where = where
        self.sig = sig


class StepFailed(Exception):
    pass


class Guard:
    def __init__(self):
        self.sig = None
        self.immediate = False

    def install(self):
        for s in (signal.SIGINT, signal.SIGTERM):
            signal.signal(s, self._handle)

    def _handle(self, signum, frame):
        name = signal.Signals(signum).name
        if self.immediate or self.sig:
            raise KeyboardInterrupt(name)
        self.sig = name
        print("\n%s received: finishing the current step, then stopping cleanly (send it again to force)" % name, flush=True)

    def check(self, where):
        hook = os.environ.get("BOTSIM_TEST_INTERRUPT")
        if hook and hook == where:
            os.kill(os.getpid(), signal.SIGINT)
            time.sleep(0.05)
        if self.sig:
            raise Interrupted(where, self.sig)


GUARD = Guard()


def nap(secs, where="wait"):
    t_end = time.time() + secs
    while True:
        GUARD.check(where)
        left = t_end - time.time()
        if left <= 0:
            return
        time.sleep(min(0.5, left))


def run_cmd(argv, input_text=None, timeout=None, cwd=None):
    p = subprocess.Popen(argv, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)
    t_end = time.time() + timeout if timeout else None
    pending = input_text
    while True:
        try:
            out, err = p.communicate(input=pending, timeout=0.5)
            return p.returncode, out, err
        except subprocess.TimeoutExpired:
            pending = None
            if GUARD.sig or (t_end and time.time() > t_end):
                p.terminate()
                try:
                    out, err = p.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    out, err = p.communicate()
                if GUARD.sig:
                    return 130, out, err
                return 124, out, (err or "") + "\ntimed out after %ds" % timeout


def gen_host_key():
    d = tempfile.mkdtemp(prefix="botsim-hk-")
    try:
        path = os.path.join(d, "k")
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "botsim-host", "-f", path], check=True,
                       capture_output=True)
        with open(path) as f:
            priv = f.read()
        with open(path + ".pub") as f:
            pub = " ".join(f.read().split()[:2])
        return priv, pub
    finally:
        shutil.rmtree(d, ignore_errors=True)


def host_keys_cloud_config(priv, pub):
    out = ["ssh_deletekeys: true", "ssh_keys:", "  ed25519_private: |"]
    out += ["    " + line for line in priv.strip("\n").split("\n")]
    out.append("  ed25519_public: %s botsim-host" % pub)
    return out


def run_dir(conf, run):
    d = os.path.join(conf, "runs", run)
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def known_hosts_path(conf, run):
    return os.path.join(run_dir(conf, run), "known_hosts")


def write_known_hosts(conf, run, boxes):
    path = known_hosts_path(conf, run)
    lines = ["%s %s" % (b["name"], b["host_pub"]) for b in boxes if b.get("host_pub") and not b.get("trust_new")]
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    os.replace(tmp, path)
    return path


def ssh_opts(conf, run, box, key):
    pinned = bool(box.get("host_pub")) and not box.get("trust_new")
    opts = ["-i", key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
            "-o", "HostKeyAlias=" + box["name"], "-o", "CheckHostIP=no",
            "-o", "UserKnownHostsFile=" + known_hosts_path(conf, run), "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no", "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=" + ("yes" if pinned else "accept-new")]
    if pinned:
        opts += ["-o", "HostKeyAlgorithms=" + HOST_KEY_ALGO]
    port = os.environ.get("BOTSIM_SSH_PORT")
    if port:
        opts += ["-p", port]
    return opts


def ssh_user():
    return os.environ.get("BOTSIM_SSH_USER", "root")


KINDS = [
    ("hostkey", ("remote host identification has changed", "host key verification failed", "host key mismatch",
                 "no matching host key type")),
    ("auth", ("permission denied",)),
    ("key_missing", ("no such identity", "identity file")),
    ("refused", ("connection refused",)),
    ("timeout", ("timed out",)),
    ("unreachable", ("no route to host", "network is unreachable", "host is unreachable")),
    ("closed", ("connection reset", "connection closed", "kex_exchange_identification", "closed by remote host",
                "broken pipe")),
    ("dns", ("could not resolve",)),
]

HINTS = {
    "hostkey": "the box answered with a host key that is not the one pinned at up. Right after boot this can be a race; if it lasts, something else answers on that IP",
    "auth": "the box refused the botsim key. Check that ~/.ssh/botsim_hetzner matches the 'botsim-hetzner' key on the account (hz.py doctor)",
    "key_missing": "the local private key is missing",
    "refused": "sshd is not listening yet (box still booting)",
    "timeout": "no answer (box still booting, or a firewall)",
    "unreachable": "no route to the box",
    "closed": "sshd closed the connection (usually still starting)",
    "dns": "bad address",
    "other": "unexpected ssh error",
}


def classify(rc, err):
    s = (err or "").lower()
    for kind, needles in KINDS:
        if any(n in s for n in needles):
            return kind
    return "other" if rc != 0 else "ok"


def last_line(err):
    lines = [x.strip() for x in (err or "").strip().splitlines() if x.strip() and not x.startswith("@@@")]
    return lines[-1] if lines else "(no message)"


def wait_ssh(argv_for, say, boot_timeout=None, retry=None, hostkey_grace=None, auth_grace=None):
    boot_timeout = float(boot_timeout or os.environ.get("BOTSIM_SSH_BOOT_TIMEOUT", 300))
    retry = float(retry or os.environ.get("BOTSIM_SSH_RETRY", 5))
    hostkey_grace = float(hostkey_grace or os.environ.get("BOTSIM_SSH_HOSTKEY_GRACE", 60))
    auth_grace = float(auth_grace or os.environ.get("BOTSIM_SSH_AUTH_GRACE", 90))
    t0 = time.time()
    first = {}
    others = 0
    tries = 0
    while True:
        GUARD.check("ssh-wait")
        tries += 1
        rc, out, err = run_cmd(argv_for("true"), timeout=40)
        GUARD.check("ssh-wait")
        if rc == 0:
            if tries > 1:
                say("  ssh ok after %d tries (%ds)" % (tries, time.time() - t0))
            return
        kind = classify(rc, err)
        now = time.time()
        first.setdefault(kind, now)
        say("  ssh try %d (+%ds): %s: %s" % (tries, now - t0, kind, last_line(err)))
        others = others + 1 if kind == "other" else 0
        reason = None
        if kind == "key_missing":
            reason = kind
        elif kind == "hostkey" and now - first[kind] >= hostkey_grace:
            reason = kind
        elif kind == "auth" and now - first[kind] >= auth_grace:
            reason = kind
        elif others >= 3:
            reason = kind
        elif now - t0 >= boot_timeout:
            reason = kind
        if reason:
            raise StepFailed("ssh gave up after %d tries in %ds: %s (%s). Last error: %s" % (
                tries, now - t0, reason, HINTS.get(reason, ""), last_line(err)))
        nap(retry, "ssh-wait")
