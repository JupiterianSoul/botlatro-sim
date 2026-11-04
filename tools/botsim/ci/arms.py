import re
import sys


def main(argv):
    if len(argv) < 3:
        print("arms.py TEMPLATE LABEL=OPTS[@1][@c] ...  (@1 adds stake 1 jobs, @c adds shuffle and leak checks, @sN starts deck jobs at seed N; LABEL base keeps the w3 jobs as they are)")
        return 2
    src = open(argv[1]).read().splitlines()
    lines = [l.split("|", 1) for l in src if "|" in l]
    out = [l for l in lines if l[0] == "tests"]
    for spec in argv[2:]:
        lab, rest = spec.split("=", 1)
        flags = rest.split("@")[1:]
        opts = rest.split("@")[0]
        first = [f[1:] for f in flags if f.startswith("s")]
        for k, v in lines:
            if k == "tests":
                continue
            new = v.replace("ro_swap=1 blog=1", ("ro_swap=1 blog=1 " + opts).strip())
            if first and re.match(r"d\d+-", k):
                new = re.sub(r"first=\d+", "first=" + first[0], new)
            if lab == "base":
                if k.startswith("b3-") or (k.startswith("b31-") and "1" in flags) or (k[:2] in ("bs", "bk") and "c" in flags):
                    out.append([k, v])
                continue
            if re.match(r"d\d+-", k):
                out.append([lab + "-" + k.split("-", 1)[1], new])
            elif k.startswith("b3-"):
                out.append([lab + k[2:], new])
            elif k.startswith("b31-") and "1" in flags:
                out.append([lab + "1" + k[3:], new])
            elif k in ("bsh", "bk-none", "bk-world") and "c" in flags:
                out.append([lab + k[1:], new])
    seen = set()
    for k, v in out:
        if k in seen:
            raise SystemExit("duplicate label " + k)
        seen.add(k)
        print(k + "|" + v)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
