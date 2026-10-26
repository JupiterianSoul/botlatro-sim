#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import time

REMOTE = "git@github.com:JupiterianSoul/botlatro-results.git"
CONF = os.environ.get("BOTSIM_CONFIG", os.path.expanduser("~/.config/botsim"))
KEY = os.path.join(CONF, "results_deploy_key")
KNOWN = os.path.join(CONF, "github_known_hosts")
NAME = "Gabriel Quart"
EMAIL = "gabriel.quart.15@gmail.com"


def say(*a):
    print(*a, flush=True)


class Local:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        os.makedirs(self.root, exist_ok=True)

    def path(self, rel):
        return os.path.join(self.root, rel)

    def sync(self):
        return True

    def exists(self, rel):
        return os.path.exists(self.path(rel))

    def read_text(self, rel, default=None):
        try:
            with open(self.path(rel)) as f:
                return f.read()
        except OSError:
            return default

    def read_json(self, rel, default=None):
        t = self.read_text(rel)
        if t is None:
            return default
        try:
            return json.loads(t)
        except ValueError:
            return default

    def write_text(self, rel, text):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        tmp = p + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, p)

    def write_json(self, rel, obj):
        self.write_text(rel, json.dumps(obj, indent=1, sort_keys=True) + "\n")

    def append(self, rel, line):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "a") as f:
            f.write(line.rstrip("\n") + "\n")

    def copy_in(self, src, rel):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        shutil.copyfile(src, p)

    def copy_out(self, rel, dst):
        os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
        shutil.copyfile(self.path(rel), dst)

    def save(self, msg):
        return True


def git_env():
    env = dict(os.environ)
    env["GIT_SSH_COMMAND"] = "ssh -i %s -o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes" % (KEY, KNOWN)
    env["GIT_AUTHOR_NAME"] = env["GIT_COMMITTER_NAME"] = NAME
    env["GIT_AUTHOR_EMAIL"] = env["GIT_COMMITTER_EMAIL"] = EMAIL
    return env


class Git(Local):
    def __init__(self, root=None, remote=REMOTE):
        root = root or os.environ.get("BOTSIM_AP_CLONE") or os.path.expanduser("~/.cache/botsim/results-repo")
        self.remote = remote
        self.root = os.path.abspath(root)

    def git(self, *args, check=True):
        p = subprocess.run(["git"] + list(args), cwd=self.root, env=git_env(), capture_output=True, text=True, timeout=600)
        if check and p.returncode != 0:
            raise RuntimeError("git %s failed: %s" % (args[0], (p.stderr or p.stdout).strip()[-400:]))
        return p

    def sync(self):
        if not os.path.isdir(os.path.join(self.root, ".git")):
            os.makedirs(os.path.dirname(self.root), exist_ok=True)
            p = subprocess.run(["git", "clone", "--depth", "50", self.remote, self.root], env=git_env(),
                               capture_output=True, text=True, timeout=600)
            if p.returncode != 0:
                raise RuntimeError("cannot clone the results repo: %s" % (p.stderr or "").strip()[-400:])
            return True
        self.git("fetch", "origin")
        self.git("reset", "--hard", "origin/HEAD")
        return True

    def save(self, msg):
        self.git("add", "-A")
        if not self.git("status", "--porcelain").stdout.strip():
            return True
        self.git("commit", "-q", "-m", msg)
        for i in range(5):
            if self.git("push", "-q", "origin", "HEAD", check=False).returncode == 0:
                return True
            say("push refused, pull --rebase and retry (%d)" % (i + 1))
            if self.git("pull", "--rebase", "-q", "origin", check=False).returncode != 0:
                self.git("rebase", "--abort", check=False)
                return False
            time.sleep(2 + 3 * i)
        return False


def open_store(local=None):
    return Local(local) if local else Git()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 3 or argv[0] != "fetch":
        raise SystemExit("usage: store.py fetch REL_PATH DEST")
    s = Git(os.environ.get("BOTSIM_AP_CLONE") or os.path.join(os.getcwd(), ".results-repo"))
    s.sync()
    if not s.exists(argv[1]):
        raise SystemExit("not in the results repo: %s" % argv[1])
    s.copy_out(argv[1], argv[2])
    say("fetched %s" % argv[1])


if __name__ == "__main__":
    main()
