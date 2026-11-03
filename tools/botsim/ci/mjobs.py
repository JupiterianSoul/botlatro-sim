import json
import sys

OLD_RUN, OLD_NET = "41618195576", "n12-n12a"


def main(argv):
    if len(argv) < 5:
        print("mjobs.py TEMPLATE.json RUN OUT.json PREFIX=NET[@nofe][@c] ...  (jobs ma-* of the template, the net from artifact NET of run RUN; @nofe drops fe_ext=1, @c adds shuffle and leak checks)")
        return 2
    tpl = json.load(open(argv[1]))
    run, out = argv[2], []
    for spec in argv[4:]:
        pre, rest = spec.split("=", 1)
        net, *flags = rest.split("@")
        for j in tpl:
            lab = j["label"]
            if lab.startswith("ma-"):
                new = pre + lab[2:]
            elif lab in ("mash", "mak-none", "mak-world") and "c" in flags:
                new = pre + lab[2:]
            else:
                continue
            cmd = j["cmd"].replace(OLD_RUN, run).replace("-n " + OLD_NET + " ", "-n " + net + " ")
            if "nofe" in flags:
                cmd = cmd.replace(" fe_ext=1 ", " ")
            out.append(dict(j, label=new, cmd=cmd))
    labels = [j["label"] for j in out]
    assert len(labels) == len(set(labels)), "duplicate labels"
    json.dump(out, open(argv[3], "w"), indent=1)
    print(len(out), "jobs:", " ".join(labels))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
