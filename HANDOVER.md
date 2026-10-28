# Handover 2026-10-28

Read this first, then tools/botsim/autopilot/DESIGN.md.

## State
- Autopilot `autopilot` dir is stopped at fair_bench (16.7% white on b_red only vs a 25% bar set from a 5-deck mix). Fixed: the white cell now runs 5 decks x 30 seeds. Re-init `full` once the speed work below is merged.
- Hetzner limit raised (144 dedicated vCPUs). 3x CCX63 = 4.93 EUR/h, about 60% more per core than cpx62+ccx33; expert step stays on cpx62+ccx33 until Gabriel decides.
- `autopilot-test-paid` (tiny-teach, 0.02 EUR, approved) still waits for a manual tick: `gh workflow run botsim-autopilot.yml -R JupiterianSoul/botlatro-sim --ref main -f command=tick -f dir=autopilot-test-paid`.

## Done on main
- jitopt loaded by the Seer runners: 1.84x faster Fair Seer, identical games (CI profile run 40651938880, tools/botsim/seer/fair_prof.lua).
- Fair teacher: stop_ante works in fair mode; records carry world votes (per-world best candidate) as soft targets.
- Net-guided Fair Seer: teacher.lua `weights=` + `net_sims=`, the net adds its MCTS move as a candidate. train job `TRAIN_PLAYER=fair` (TRAIN_FAIR_BUDGET, TRAIN_FAIR_NET_SIMS, TRAIN_FAIR_DECKS, TRAIN_FAIR_ARGS) plays these games instead of self-play. Cloud test `train fair` passes on CI.
- Speed switches, off by default: `PL.FAST_TOP` (fair.lua `fast_top=8`: preview only the top N five-card plays by nominal score in rollouts) and `quick_clear` (`quick=1`: play the best visible play when it clears the blind).

## Next
1. Read A/B run 40653671454 (branch ci-bench-fairspeed2): base / top8 / quick / both on BENCH 1-30 x 5 decks white. Keep a switch only if wins are not worse; then make it the lite default (F.BUDGETS / teacher) and measure s/game against the 60 s gate.
2. Branch `net-contested`: one commit, the net proposes only when worlds disagree (net-guided test showed 16 of 18 decisions searched otherwise). Run seer tests on CI, then merge.
3. Profile `full`: expert paid env TRAIN_PLAYER=fair (+ games per gen sized for ~60 s games), set flags fair_speed_ok and expert_ok, re-init full, BOTSIM_AUTOPILOT is already on.
4. Docs: seer/DESIGN.md Fair Seer section (world votes, net proposals, switches) once the A/B numbers are in.
