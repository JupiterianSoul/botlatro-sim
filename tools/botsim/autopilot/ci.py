import json
import os

WORKFLOW = "botsim-work.yml"


def ref():
    return os.environ.get("BOTSIM_AP_REF") or "main"


def run_name(tag):
    return "botsim work %s" % tag


def last_json(out):
    for line in reversed((out or "").strip().splitlines()):
        line = line.strip()
        if line[:1] in "{[":
            try:
                return json.loads(line)
            except ValueError:
                continue
    return None


def dispatch(run, tag, jobs, dir_, chain=True):
    argv = ["gh", "workflow", "run", WORKFLOW, "--ref", ref(), "-f", "tag=" + tag,
            "-f", "jobs=" + json.dumps(jobs, separators=(",", ":")), "-f", "chain=" + (ref() if chain else ""), "-f", "dir=" + dir_]
    rc, out = run(argv)
    return rc == 0, out


def find_run(run, tag, limit=100):
    rc, out = run(["gh", "run", "list", "--workflow", WORKFLOW, "--limit", str(limit),
                   "--json", "databaseId,displayTitle,status,conclusion,createdAt"])
    if rc != 0:
        return None
    try:
        runs = json.loads(out or "[]")
    except ValueError:
        return None
    want = run_name(tag)
    hits = [r for r in runs if r.get("displayTitle") == want]
    if not hits:
        return None
    hits.sort(key=lambda r: r.get("createdAt") or "")
    r = hits[0]
    return {"id": r.get("databaseId"), "status": r.get("status"), "conclusion": r.get("conclusion")}


def view_run(run, run_id):
    rc, out = run(["gh", "run", "view", str(run_id), "--json", "databaseId,displayTitle,status,conclusion"])
    if rc != 0:
        return None
    try:
        r = json.loads(out)
    except ValueError:
        return None
    return {"id": r.get("databaseId"), "status": r.get("status"), "conclusion": r.get("conclusion"), "title": r.get("displayTitle")}


def download(run, run_id, dest):
    os.makedirs(dest, exist_ok=True)
    rc, out = run(["gh", "run", "download", str(run_id), "-D", dest])
    return rc == 0, out


def files(root, name):
    found = []
    for d, _, fs in os.walk(root):
        for f in fs:
            if f == name or (name.startswith("*") and f.endswith(name[1:])):
                found.append(os.path.join(d, f))
    return sorted(found)


def read_all(paths):
    out = []
    for p in paths:
        try:
            with open(p) as f:
                out.append(f.read())
        except OSError:
            pass
    return out


def read_jsons(paths):
    objs = []
    for t in read_all(paths):
        try:
            objs.append(json.loads(t))
        except ValueError:
            objs.append(None)
    return objs
