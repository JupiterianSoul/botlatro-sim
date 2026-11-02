# CI bench helpers

Paired arms against w3 on BENCH 39001-39300 at stake 8 and 39501-39700 at stake 1, Red, Blue and Black.

Build a job list and push it:

    python3 tools/botsim/ci/arms.py tools/botsim/ci/w3_bench.txt 'o=ro_ordro=1@1@c' 'z=ro_base=0' > tools/botsim/ci_bench.txt
    git checkout origin/ci-bench-t1 -- tools/botsim/r5val.bnnw tools/botsim/seer/leak_probe.lua

`@1` adds the stake 1 jobs, `@c` the shuffle and leak checks. Push as `ci-bench-<name>`.

The w3 base games are the b3 and b31 jobs of run 41430136626, so arms on these seeds need no new base:

    tools/botsim/ci/dl.sh 41430136626 /tmp/base
    tools/botsim/ci/dl.sh RUN /tmp/new
    tools/botsim/ci/cmp.sh /tmp/base /tmp/new o

`cmp.sh BASE NEW ARM [BASEARM]` prints every deck and the pooled line per stake. The tests job now exits non-zero when a suite fails; older job lists did not, so read `output.txt` for those.

Real wins, paired, as a sign test over the games only one side won (pairs of BASE:NEW directories):

    python3 -I tools/botsim/ci/wins.py /tmp/base/g/b3-red:/tmp/new/g/z-red /tmp/base/g/b3-blue:/tmp/new/g/z-blue

Clear rate per ante, both arms on their common seeds (comma separated directories):

    python3 -I tools/botsim/ci/clear.py /tmp/base/g/b3-red,/tmp/base/g/b3-blue /tmp/new/g/z-red,/tmp/new/g/z-blue
