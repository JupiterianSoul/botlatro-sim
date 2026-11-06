import argparse
import json
import os
import sys

REPO = " -R JupiterianSoul/botlatro-sim"
R5VAL = "41234932764"


def piece(tag, label, data, args, steps, limit, prev_tag):
    get = "".join("gh run download " + r + REPO + " -p 'bench-dat-*' -D gen/" + r + "; " for r in data)
    get += "gh run download " + R5VAL + REPO + " -n r5val-net -D ft; "
    prep = ("PYTHONPATH=tools/botsim/train python3 tools/botsim/train/trim.py $(find gen -name 'x*.bspr'); "
            "for d in gen/*; do PYTHONPATH=tools/botsim/train python3 tools/botsim/train/relabel.py $d; done; "
            "find gen -name 'x*.bspr' -size +0c | wc -l; ")
    res = ""
    if prev_tag:
        res = ("gh run download $PREV" + REPO + " -n " + prev_tag + "-" + label + " -D prev || exit 1; "
               "ls -la prev/ckpt.pt || exit 1; ")
    train = ("python3 tools/botsim/train/train.py --data $(find gen -name 'x*.bspr' -size +0c | sort) --init ft/net.bnnw "
             + args + " --steps " + str(steps) + " --time-limit " + str(limit) + " --ckpt $OUT/ckpt.pt"
             + (" --resume prev/ckpt.pt" if prev_tag else "") + " --out $OUT/net.bnnw > $OUT/train.txt 2>&1; "
             "grep -E 'resumed|time limit|checkpoint|^records' $OUT/train.txt; tail -2 $OUT/train.txt; "
             "test -s $OUT/net.bnnw && test -s $OUT/ckpt.pt")
    return {"label": label, "cmd": get + prep + res + train, "torch": True, "timeout": 350}


def main(argv):
    ap = argparse.ArgumentParser(description="chain file: training pieces under the job limit, each resuming the last checkpoint, then the measurement jobs of njobs.py with RUN=$PREV")
    ap.add_argument("out")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--data", required=True, help="data run ids, comma separated")
    ap.add_argument("--net", action="append", required=True, help="LABEL=TRAIN ARGS")
    ap.add_argument("--steps", type=int, required=True)
    ap.add_argument("--pieces", type=int, default=1)
    ap.add_argument("--limit", type=int, default=17000)
    ap.add_argument("--measure", default="", help="njobs.py spec list file, one LABEL=NET@... per line, ARTIFACT given as the net label")
    a = ap.parse_args(argv[1:])
    data = [r for r in a.data.split(",") if r]
    nets = [n.split("=", 1) for n in a.net]
    chain = []
    for k in range(a.pieces):
        tag = "%s-p%d" % (a.tag, k + 1)
        prev = "%s-p%d" % (a.tag, k) if k else ""
        chain.append({"tag": tag, "jobs": [piece(tag, lab, data, args, a.steps, a.limit, prev) for lab, args in nets]})
    if a.measure:
        last = chain[-1]["tag"]
        specs = []
        for l in open(a.measure).read().splitlines():
            l = l.strip()
            if not l:
                continue
            lab, rest = l.split("=", 1)
            net, *flags = rest.split("@")
            specs.append(lab + "=" + last + "-" + net + ("@" + "@".join(flags) if flags else ""))
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import njobs
        tmp = a.out + ".m.json"
        if njobs.main(["njobs.py", "--compact", "$PREV", tmp] + specs):
            return 1
        chain.append({"tag": a.tag + "-m", "jobs": json.load(open(tmp))})
        os.remove(tmp)
    json.dump(chain, open(a.out, "w"), indent=1)
    for c in chain:
        print(c["tag"], len(c["jobs"]), "jobs", len(json.dumps(c["jobs"])), "chars")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
