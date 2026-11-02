import os, re, sys, shutil
root = sys.argv[1]
for d in sorted(os.listdir(root)):
    m = re.match(r"bench-([a-z0-9]+)-([a-z]+)-(\d+)$", d)
    if not m:
        continue
    dst = os.path.join(root, "g", m.group(1) + "-" + m.group(2))
    os.makedirs(dst, exist_ok=True)
    tgt = os.path.join(dst, m.group(3))
    if not os.path.exists(tgt):
        shutil.copytree(os.path.join(root, d), tgt)
