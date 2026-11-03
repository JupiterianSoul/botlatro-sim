The working player is w8 = w7 with `ro_h2=3,4,5,6,7` (h37) since 2026-11-03 (y37 ladder and checks of run 41607666818 passed): templates w8_bench.txt and w8_ladder.txt. w8 base games: w8 and w81 of the ci-bench-s4a run (39001-39300 stake 8, 39501-39700 stake 1, labels w8-<deck>-N and w81-<deck>-N). h37 without the sale has h37 of run 41593334360 (39001-39300 stake 8), yf of run 41607666818 (40001-40700 stake 8) and yl of the same run (ladder). arms.py puts new options before `solver_sell=1`, so for arms that pair against those games use w6_bench.txt with `ro_h2=3,4,5,6,7` in the arm options instead. Measurement jobs for the retrained nets: `python3 tools/botsim/ci/mjobs.py tools/botsim/ci/m12_jobs.json RUN OUT.json mv=n12-n12v@nofe@c ma=n12-n12a` (RUN is the n12 training run). The working player is w7 = w6 plus `ro_h2=4,5,6,7` plus `solver_sell=1` since 2026-11-03. Templates: w7_bench.txt and w7_ladder.txt. No w7 base games yet. w6 plus `ro_h2=4,5,6,7` alone (no sale) has: h47 of run 41588046124 (39001-39300 stake 8), xf of run 41593334360 (40001-40700 stake 8) and xl of the same run (ladder); arms on those seeds without `solver_sell` pair against them. w6 notes follow. # CI bench helpers

The working player is w6 = w5 plus `solver_qc=0` since 2026-11-03 (every clearing play judged by the solver with the tie terms, no quick clear). Templates: w6_bench.txt and w6_ladder.txt. w6 base games already played: q0 of run 41559984414 (39001-39300 stake 8, Red, Blue, Black, `cmp.sh BASE NEW ARM q0`; no stake 1 jobs yet), qf of run 41578007787 (40001-40700 stake 8, 7 jobs of 100 per deck), ql of run 41580572254 (ladder, b_red 34001-34200, stakes 1 to 7). w5 notes follow. The working player is w5 = w3 plus `ro_base=0` plus `solver_tie=1` since 2026-11-02 (w4 was w3 plus `ro_base=0`). Templates: w5_bench.txt and w5_ladder.txt (w4_* and w3_* kept); the job labels still read b3 and b31 so arms.py works on all of them. w5 base games already played: zt and zt1 of run 41497497169 (39001-39300 stake 8, 39501-39700 stake 1, compare with `cmp.sh BASE NEW ARM zt`), ztl of run 41502521924 (ladder, b_red 34001-34200, stakes 1 to 7). w4 base games: z and z1 of run 41435808952, gz of run 41466670731 (40001-40700 stake 8), zl of run 41449744058 (ladder).

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
