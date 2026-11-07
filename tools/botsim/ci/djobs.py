import json
import os
import re
import sys

from njobs import BASE_W, POLL

HERE = os.path.dirname(os.path.abspath(__file__))


def build(run, art, first, njobs, per, opts):
    tpl = open(os.path.join(HERE, "w13_data.txt")).read().strip().split("|", 1)[1]
    assert tpl.count(BASE_W) == 4
    out = []
    for i in range(njobs):
        cmd = tpl.replace(BASE_W, "weights=net/net.bnnw")
        cmd = re.sub(r"first=\d+", "first=%d" % (first + i * per), cmd)
        cmd = re.sub(r"seeds=\d+", "seeds=%d" % per, cmd)
        if opts:
            cmd = cmd.replace("ro_swap=1 blog=1", "ro_swap=1 blog=1 " + opts)
        out.append({"label": "dat-%d" % i, "cmd": POLL.format(w=60, r=run, n=art) + cmd, "timeout": 345})
    return out


def main(argv):
    if len(argv) >= 8 and argv[1] == "--cmd":
        job = build(argv[2], argv[3], int(argv[4]), int(argv[5]), int(argv[6]), " ".join(argv[8:]))[int(argv[7])]
        print(job["cmd"])
        return 0
    if len(argv) < 7:
        print("djobs.py RUN ARTIFACT FIRST NJOBS SEEDS_PER_JOB OUT.json [OPTS]  (w13 data jobs with records, all 15 decks at stakes 1, 3, 5, 8, playing net.bnnw of artifact ARTIFACT of run RUN; job i plays seeds FIRST+i*SEEDS_PER_JOB onward)")
        return 2
    run, art, first, njobs, per, path = argv[1], argv[2], int(argv[3]), int(argv[4]), int(argv[5]), argv[6]
    opts = " ".join(argv[7:])
    out = build(run, art, first, njobs, per, opts)
    for i, j in enumerate(out):
        j["cmd"] = "python3 tools/botsim/ci/djobs.py --cmd %s %s %d %d %d %d %s > /tmp/job.sh && bash /tmp/job.sh" % (run, art, first, njobs, per, i, opts)
    json.dump(out, open(path, "w"), indent=1)
    print(len(out), "jobs, seeds %d-%d, %d games" % (first, first + njobs * per - 1, njobs * per * 60))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
