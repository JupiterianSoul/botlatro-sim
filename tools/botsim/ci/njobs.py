import json
import os
import re
import sys

REPO = " -R JupiterianSoul/botlatro-sim"
HERE = os.path.dirname(os.path.abspath(__file__))
POLL = ("for i in $(seq 1 {w}); do gh run download {r}" + REPO + " -n {n} -D net 2>/dev/null && break; rm -rf net; "
        "[ \"$(gh run view {r}" + REPO + " --json status -q .status)\" = completed ] && break; sleep 60; done; "
        "ls -la net/net.bnnw || exit 1; ")
LEAK = "git fetch -q --depth 1 origin ci-bench-t1 && git checkout FETCH_HEAD -- tools/botsim/seer/leak_probe.lua; "
BASE_W = "weights=tools/botsim/r5val.bnnw"


def lines(name):
    out = []
    for l in open(os.path.join(HERE, name)).read().splitlines():
        if "|" in l:
            out.append(l.split("|", 1))
    return out


def build(run, specs):
    out = []
    decks = [(k, v) for k, v in lines("w13_decks.txt") if re.match(r"d13-", k)]
    checks = [(k, v) for k, v in lines("w13_bench.txt") if k in ("bsh", "bk-none", "bk-world")]
    ladder = [(k, v) for k, v in lines("w13_ladder.txt") if "-lad-" in k]
    for spec in specs:
        lab, rest = spec.split("=", 1)
        art, *flags = rest.split("@")
        first = [f[1:] for f in flags if f.startswith("s")]
        opts = " ".join(f[1:].replace("+", " ") for f in flags if f.startswith("o")).strip()
        only = [d for f in flags if f.startswith("d") for d in f[1:].split(",") if d]
        wait = POLL.format(w=330, r=run, n=art)
        todo = [(lab + "-" + k.split("-", 1)[1], v) for k, v in decks if not only or k.split("-", 1)[1] in only]
        if "c" in flags:
            todo += [(lab + k[1:], v) for k, v in checks]
        if "l" in flags:
            todo += [(lab + "-" + k.split("-", 1)[1], v) for k, v in ladder]
        for k, v in todo:
            assert v.count(BASE_W) >= 1, k
            cmd = v.replace(BASE_W, "weights=net/net.bnnw")
            if opts:
                cmd = cmd.replace("ro_swap=1 blog=1", "ro_swap=1 blog=1 " + opts)
            if first and not k.endswith(("sh", "k-none", "k-world")) and "-lad-" not in k:
                cmd = re.sub(r"first=\d+", "first=" + first[0], cmd)
            pre = wait + (LEAK if "leak_probe" in cmd else "")
            out.append({"label": k, "cmd": pre + cmd, "timeout": 345, "spec": spec})
    return out


def main(argv):
    if len(argv) >= 5 and argv[1] == "--cmd":
        job = [j for j in build(argv[2], [argv[3]]) if j["label"] == argv[4]]
        assert len(job) == 1, argv[4]
        print(job[0]["cmd"])
        return 0
    compact = "--compact" in argv
    argv = [x for x in argv if x != "--compact"]
    if len(argv) < 4:
        print("njobs.py [--compact] RUN OUT.json LABEL=ARTIFACT[@sFIRST][@c][@l][@o<opts>][@d<deck,deck>] ...  (w13 Gold deck jobs and, with @c, shuffle and leak checks and, with @l, the stake ladder, playing net.bnnw of artifact ARTIFACT of run RUN inside w13; @o adds options with + for spaces; --compact jobs rebuild their command from this file at run time)")
        print("njobs.py --cmd RUN SPEC LABEL  (prints the command of one job)")
        return 2
    run, out = argv[1], build(argv[1], argv[3:])
    for j in out:
        spec = j.pop("spec")
        if compact:
            q = '"$PREV"' if run == "$PREV" else run
            j["cmd"] = "python3 tools/botsim/ci/njobs.py --cmd " + q + " '" + spec + "' " + j["label"] + " > /tmp/job.sh && bash /tmp/job.sh"
    labels = [j["label"] for j in out]
    assert len(labels) == len(set(labels)), "duplicate labels"
    json.dump(out, open(argv[2], "w"), indent=1)
    print(len(out), "jobs:", " ".join(labels))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
