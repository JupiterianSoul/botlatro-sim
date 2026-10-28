# Handover 2026-10-28 (afternoon, 13:20)

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

## Since the morning
- A/B on BENCH 1-30 x 5 decks white (150 games each): base 36 wins 129.9 s/game; fast_top=8 39 wins 66.4 s (rerun: same 39 wins, 91.1 s, CI timing noise is about 35%); quick_clear 35 wins, no gain; top 5 32 wins; top 4 28 wins. fast_top=8 is the lite default, quick_clear off.
- Net proposes only where the worlds disagree (net-guided test: 9 of 18 decisions searched, net move chosen once).
- Full profile expert/ladder env: TRAIN_PLAYER=fair, TRAIN_GAMES=300. Docs updated (seer/DESIGN.md, autopilot/DESIGN.md).
- Preview copies read RNG through a lookup (state.lua copy_preview, ST.PREVIEW_PROXY) on branch `preview-proxy`; test_preview passes (no differing previews, no RNG leaks), Seer 193/193, leak 323/323. Games and same-runner timing in run 40682408530.
- Paid tiny-teach round r20261028-114401 started 11:44 (0.0125 EUR).
- Full autopilot re-initialised, fair_bench dispatched 11:49 (721e43). Gabriel approved 30 EUR, round cap 4. expert_ok on, fair_speed_ok off until preview-proxy is merged.
- Paid tiny-teach passed: round done, gate passed, boxes gone, 0.0125 EUR (ledger 9.5755).
- preview-proxy merged into main (3e2a023): BENCH 1-30 x 5 decks white, all 150 games identical to run 40678407782 (39 wins). Same-runner A/B 65.0 to 59.5 s/game in one job, the other job's runner slowed mid-job (63.0 to 92.4, every phase slower). Merged code CI: Seer 193/193, leak 323/323, cloud tests passed. fair_speed_ok switched on 13:18 (run 40685903845).

## Next
1. Watch the autopilot log in botlatro-results (autopilot/log.md). fair_bench 721e43 was running at 13:20; fair_speed_ok and expert_ok are on, so fair_speed (CI) and then teacher rounds (Hetzner, 30 EUR approved, round cap 4) follow on their own. If fair_speed fails only on CI timing noise (wins fine, s/game near 60), look for more speedups that keep games identical, e.g. skip copying shop and pack arrays in copy_preview, verified with test_preview and identical games on CI.
2. sim tests have 3 failures on main (also before the merge, run 40685760882): test_rng pseudoshuffle KQ3N1P2M, test_rng tag and voucher sequence 88888888, test_econ FFI random port vs math.random (1700 of 20000). The tests run the real game functions on the pinned LuaJIT 2.1.1791988261, whose math.random disagrees with the FFI port in rng.lua; the sim uses the port and matches the hardcoded real-game deck QFCIQ6C1. Find out which one matches LOVE 11.5 (its bundled LuaJIT), then fix the port or the pinned LuaJIT. The Golden sim test step pipes through tail and never fails; make it fail on FAIL lines.
