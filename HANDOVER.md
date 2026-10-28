# Handover 2026-10-28 (evening, 15:50)

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

## Session 2026-10-28 afternoon (done, on main)
- Sim test failures fixed: GitHub runners moved to Ubuntu 26.04, whose gcc targets x86-64-v3 and fuses d*pi+e in math.randomseed (FMA), changing 1700 of 20000 seeds. The rng.lua port was right: Steam Balatro ships LuaJIT 2.0.5 (lua51.dll has no FMA), Android LOVE 11.5 ships 2.1.1700008891 (separate fmul/fadd). LuaJIT is now built with XCFLAGS=-ffp-contract=off in both workflows and hz.py. Sim 500/500, Seer 193/193, leak 323/323, BENCH 150 games identical. Games never changed (the sim uses the port).
- Golden sim test step runs tools/botsim/test/ci.sh and fails on FAIL lines; bench Run step has pipefail.
- Preview restore: inside PL.scan, previews after the first restore card arrays only for hand cards (ST.copy_preview_again, ST.PREVIEW_AGAIN). Games identical, new test_preview check compares every restored state with a full copy. Only 2-4% faster: preview time is play_eval, not copying. Shop and pack arrays are empty during play, so skipping them gains nothing.
- fair_speed failed twice (99.3, 91.8 s/game, wins identical 39/150): the 60 s bar came from one-game profiles, the gate runs 4 games per runner where the baseline itself is about 82 s. Gabriel chose a relative bar: `max_ratio` 1.5 x fair_bench white mean (profiles.json full). Autopilot resumed 15:48, fair_speed attempt 4 (721e43-4) dispatched.
- Known: the `unit` job's Cloud tests fail 3 tests (head sees games from both boxes, bench result present, train gen 0) since 26 Oct, before these changes. Gabriel OK'd pushing past it; fix it next.

## Later 2026-10-28 (17:30)
- fair_speed passed 16:25. Teacher runs on Hetzner: ccx43 (16 dedicated cores, 0.53 EUR/h), because the 17 shared cores are partly taken by Gabriel's gb-main-desktop and gb-main-android servers (never touch them). Rounds of 600 seeds (about 1200 games, about 2 h). Round 1: 240 games in 25 min, 0.53 EUR. Ledger 10.64 EUR at 17:05.
- Training app (~/.local/bin/botlatro-training now points at this repo) opens the autopilot's live round via botlatro-results when this PC has no run.
- Gabriel will ask Hetzner for a higher shared core limit; when granted, switch teacher back to cpx62 (half the price per core).

## Next
1. Watch autopilot/log.md in botlatro-results: fair_speed 721e43-4, then teacher (CI fan-out, 20000 games), imitation, expert (Hetzner, 30 EUR approved, round cap 4).
2. Fix the 3 old Cloud test failures in the botsim-autopilot `unit` job (push a ci-ap-* branch to run it; run 40716974826 shows them).
3. Teacher speed plan, approved by Gabriel 2026-10-28: about 80 s per Fair Seer lite game now, target 10-20 s. Profile: play.scan 95%, PL.solve 70% (beam of up to 6 nodes, about 50 kids per level, each kid scanned over all 218 combos, preview about 3.8 us, mostly play_eval). Do the phases in order, one at a time, each verified on CI before merge; report measured s/game after each.
   A. Identical games: reuse a kid's scan when it enters the next beam level; per-scan caching of combo-independent work in play_eval (find_joker calls, resolve_blueprints, update_dynamic parts). Check: sim tests, test_preview, Seer, leak, BENCH 1-30 x 5 decks identical to run 40712152628 (39 wins). Expected 65-70 s.
   B. Top 8 in solve: score only the top 8 five-card plays by nominal score in PL.solve/node_best (like PL.FAST_TOP in rollouts, 2x there with 39 vs 36 wins). Check: wins not worse on the 150 BENCH games (two-proportion check as in the fair_speed gate). Expected 35-45 s.
   C. Memoize previews: same hand in the same situation reached again inside a solve reuses its scan. Key must cover everything scoring reads (jokers and their counters, money, hands/discards left, blind, levels, RNG proxy state). Check: identical BENCH games plus a test comparing memoized and fresh scans. Expected about 20 s.
   D. Hot path in C, teacher only: profile again after C, then port only what is still hot (likely EV.evaluate, card scoring, play_eval joker effects, the preview copy) to a C library loaded through LuaJIT FFI, used on CI and Hetzner only, falling back to Lua when missing. The Lua sim stays the reference and stays in the game. Port in small pieces, each fuzzed against Lua on millions of random states (tools/botsim/fuzz.lua) with identical results. Build it in the CI workflows and hz.py LUAJIT_SETUP. Check: fuzz identical, all tests, BENCH identical. Expected 10-20 s.
   Later, inside step 3: the net's value head replaces the fast-policy rollouts (AlphaZero style), switched on gradually and measured each round. That is the route to a few seconds per game.
   Merge to main only after CI passes; the autopilot picks the new code up on its next round.
