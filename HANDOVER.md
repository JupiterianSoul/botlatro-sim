# Handover 2026-10-28 (night)

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

## Teacher speed, evening 2026-10-28 (on main)
- Phase A (1108a41): solve reuses a kid's scan when it enters the beam; repeat previews in a scan reuse find_joker results, update_dynamic values and blueprint links (E.PREVIEW_CACHE, PL.REUSE_SCAN, both on). BENCH 1-30 x 5 decks: all 150 games identical to run 40712152628 (39 wins). Sim, Seer, leak pass. Gain small: pinned pairs -10% and +4% (CI noise), solve 63.5 to 52.1 ms/call.
- Phase B (049696f): fair lite ranks solve kids by a fast scan of only the top 8 five-card plays (`kid_top` in the lite solve budget, `solve_kid_top` in the lite seer budget, both 8; plain Seer keeps 0). The first try only covered fair.lua's own solve; most kids come from S:decide_play (beam 6, 3 plays, 6 discards). Run 40742385845: 38 of 150 wins vs 39 (z 0.13, not worse, 91 games changed), sim/Seer/leak pass. Pinned pairs (old and new at the same time on cores 0 and 1): 82.8 to 63.7 and 91.5 to 81.6 s/game under the profiler (-23%, -11%). Bench 54.5 s/game (phase A run 63.3, reference 71.0).
- Timing method: sequential A/B on one runner is useless (the second run is always slower). Use concurrent `taskset -c 0` / `taskset -c 1` pairs, see the pairB lines in git history of tools/botsim/ci_bench.txt (commit "ci bench: phase B with Seer solve kids").
- fair_prof.lua now splits scan time and preview counts by solve/other and full/fast. Profile after B (6 games, 39.4 s/game): rollout fast scans 50.7% (461k scans, 0.26 ms), solve full scans 21.8% (32k, 1.62 ms, about 370 previews each), solve fast scans 15.8%, solve.step 0.3%, clone 2%.
- Phase C measured before building (run 40747799883, `fair_prof.lua repeats=1`, exact key over every state field and the RNG): a scan memo per decision would skip 19% of previews (rollout fast scans 22.4%, solve fast 22.7%, solve full 13.9%); per solve only 11% of fast scans and 0% of full scans repeat. Net after key cost maybe 10-15%, so C is not the route to 20 s. Gabriel chose: build C, then D.
- Phase C built on branch `speed-c` (not merged): PL.memo per fair decision (lite budget `memo = true`), key = ST.hash(s), an exact 64-bit hash of every state field and the RNG (step and hcache left out). test_preview checks memo hits equal fresh scans, clones hit, a changed state hashes differently. CI run 40749297411 (branch ci-bench-speed-c): merge only if the 150 BENCH games are identical to phase B's run 40742385845 (38 wins) and sim/Seer/leak pass; s/game from the pairC lines (memo=0 vs on, pinned). Then delete ci-bench-speed-c.
- Phase C result (run 40749297411): all 150 games identical to phase B (38 wins), sim 508/508, Seer 193/193, leak 323/323. Previews down 13% (rollout fast scans 22%), but pinned pairs memo off vs on 50.4 to 47.5 and 66.2 to 71.7 s/game: no measurable gain, the hash of about 1500 fields per scan costs what the hits save (rollout scan 0.24 ms/call vs 0.26). Not merged; `speed-c` kept. Only worth it with a much cheaper key (hash incrementally, or key rollout states by parent key + action).
- Then phase D in its own session.
- Stuck alert fixed (4e37a57): it fired on 600-seed teacher rounds because the phase text never changes; it now also resets when the game count moves. Takes effect from the next deployed round.

## Phase D, night 2026-10-28 (on main)
- PL.scan runs in C: tools/botsim/c/scan.c (evaluate, RNG port, play_eval with every scoring joker, DNA, Midas, Vampire, bosses), tools/botsim/cscan.lua marshals the state once per scan and swaps PL.scan when tools/botsim/c/libbotsim.so exists. Loaded from jitopt, so every runner gets it; BOTSIM_CLIB=0 turns it off. The game never has the .so and keeps the Lua scan.
- Built by `make -B -C tools/botsim/c` in botsim-bench.yml and botsim-work.yml, and on Hetzner boxes in GOLDEN_CHECK (hz.py), which also runs a 200-state fuzz before the tests; rsync excludes a local .so. test/ci.sh runs the same 200-state fuzz when the lib exists.
- Fuzz (tools/botsim/fuzz_scan.lua, CI run 40756637354): 1.12M random states (120k with `dna=1`), 4.5M scans, 644M previews, 0 differ. Round 1 (run 40753790064) found 393 differing scans, all DNA (Erosion missed the copied card, two DNA copies shared a slot); fixed.
- BENCH 1-30 x 5 decks white: all 150 games identical to phase B run 40742385845 (38 wins), 9.7 s/game vs 54.5. Pinned pairs C off vs on: 32.7 to 10.0 and 51.6 to 14.6 s/game (3.3x, 3.5x). Sim 504/504, Seer 193/193, leak 323/323 with C loaded.
- Profile after D (6 games): play.scan 60% but 0.06 ms per scan (was 0.26, now mostly marshalling and the Lua side), state.clone 10%, seer.rollout fast_action 39%. Next speed step if needed: move the rollout's fast_action loop (scan + discard choice) or the marshal into C, or the net value head instead of rollouts.
- Local cloud tests: only the 2 known old failures (head sees games, bench result present).

## Session 2026-10-28 late night (on main, 06caebc)
- The 3 old Cloud test failures had one cause: the autopilot `unit` job had no luajit on the Ubuntu 26 runner image. It now builds the pinned LuaJIT like the other workflows. Unit job green (run 40775720185): 37 autopilot tests, every Cloud test.
- Two-box checks poll up to 90 s instead of one read after sleep(16); failed cloud checks print the job logs.
- Imitation was killed twice (exit 143) right after fetching the teacher data: train.py decoded every record into dense numpy arrays (about 1.6 GB of raw records, last round 275 MB gz). Records are now lazy (records.read_lazy, decoded per batch); Cloud test checks lazy equals eager batches.
- Autopilot resumed 21:58, imitation attempt 3 dispatched (run 40776242810). Approval: 30 EUR, round cap 5 EUR, 6.64 EUR spent by the autopilot; ledger 22.79 EUR of 100.
- Imitation attempt 3 (run 40776242810): training worked (2M records = window cap, 20000 runs, 20000 steps, val policy 0.94, win_pred 0.188 vs true 0.181). Gate failed twice over:
  - Shuffle check 0 of 8 identical, but it is a harness bug: fair_shuffle.lua who=net calls MC.advance_forced on the scrambled view copy, so the net answers in the shop ("open:jokers:1") while the real state is still in round_eval; the step fails and the game ends "stuck". Fix: advance_forced the real state before building the view. Whether MCTS on a scrambled view then matches (search steps the view's hidden future) is unknown; a fair net check may need sims=0 or determinized search.
  - Net eval: 150 b_red white games, mean ante 2.03 (305/150), 1 win, vs min_ante 5.5. Far below the teacher. Needs a real look (action mapping between teacher records and the net, MCTS sims=32 vs policy only, eval vs teacher on the same seeds).
- Attempt 4 (721e43-8) will fail the same way and the autopilot stops itself; nothing paid runs.
- Next: check autopilot/log.md. If imitation failed again, read the run log (train.txt in out/). If it passed, expert runs on Hetzner by itself; report each round.

## Morning 2026-10-29 (on main, 1577254)
- Overnight nothing ran: imitation stopped 22:34 (shuffle check, 2 in a row), and I blocked on a question to Gabriel. Never ask at bedtime.
- Why the imitation net was weak (mean ante 2.0): fair teacher records kept the chosen move plus the top 23 by nominal score. Discards score 0, so other discards never appeared as negatives and the net learned "discards are good". Fix: seer/teacher.lua defaults K=32 neg=16 (16 ranked, 16 random others, per-game LCG so records stay deterministic; games unchanged). A/B on the same 600 b_red white teacher games, 4000 steps, 30 BENCH seeds: old 1.37 mean ante (0 wins), new 4.87 (sims 0) / 5.03 (sims 32), 1-2 wins (runs 40838080953, 40839504118).
- fair_shuffle.lua who=net: forced cash-out now advances the real state (was only the scrambled copy, so every game ended "stuck").
- Net eval and the shuffle check now use the policy alone (`sims=0`): MCTS on the real state reads the hidden deck, so a searched net is not fair. The train job's own eval (TRAIN_EVAL_SIMS) still searches the real state; it only ranks rounds, the counted numbers come from the CI checks.
- eval.lua writes `end` (why the game stopped) and `moves` per game line.
- `autopilot.py redo STEP` goes back to an earlier step (teacher clears its artifacts, steps up to imitation clear best). Ran `redo teacher` 08:15; teacher round r20261029-081506 started on Hetzner (same 20000 seeds, new records). Spent 6.64 of 30 EUR before it.
- Tests on 1577254: autopilot 38 OK, Cloud tests all ok, Seer 196/196, sim 504/504, scan fuzz 0 differ.

## Afternoon 2026-10-29 (on main, 8d6a551)
- Teacher redo done 10:30: 20000 games with the new records, two rounds 6.57 + 3.28 EUR. Round 1 ran 76 min and was billed 2 started hours on both boxes, over the 5 EUR round cap: find out why it ran twice as long as last night's 9000-seed round (37 min) and why the round cap did not stop it. Spent 16.50 of 30 EUR.
- Imitation on the new records, net alone (sims=0), 150 b_red white BENCH seeds: 20000 steps mean ante 4.95, 12 wins; 60000 steps 5.05, 12 wins. Teacher (Fair Seer lite) on the same seeds: 5.62, 25 wins. Gate 5.50.
- Gabriel chose: keep the 5.50 bar, improve imitation first, no spend. Retry 721e43-11 (same settings) was running at 18:38; expect a fail and a stop.
- `redo` now resets the gate counts of every later step (it used to leave imitation at 2 fails).

## Next session: make the imitation net reach mean ante 5.5 (free, CI only)
Try in this order, each measured on the same 150 b_red white BENCH seeds with sims=0, one change at a time:
1. Data window: train.py keeps only the last 2,000,000 records (`--window`), and the 20000 teacher games have more (summary said records 2000000 = the cap). Raise the window so every record is used.
2. Model size: E=32 H=128 (323k weights). Try H=256 and E=64 via `--cfg`; check CPU torch time per step and the Lua inference speed (eval s/game), since the net also runs inside Fair Seer in expert.
3. Steps vs epochs: 20000 to 60000 steps gained only 0.1 ante; watch val policy loss for overfitting before adding more.
4. More teacher games on free CI (teacher step fan-out, 60 seeds per job, 40 jobs) on new seeds, merged with the current 20000.
5. Fair inference help that is still "net alone": MC score_prior (mix nominal score into play priors) at sims=0.
Add a progress line to the imitation job output (train.py step lines are only in train.txt, uploaded at the end), so a running job can be checked live.

## Next
0. Gabriel chose (2026-10-28 night): next session = autopilot rounds on the faster code plus the 3 old Cloud test failures (item 2). No more speed work for now.
1. Watch autopilot/log.md in botlatro-results: fair_speed 721e43-4, then teacher (CI fan-out, 20000 games), imitation, expert (Hetzner, 30 EUR approved, round cap 4).
2. Fix the 3 old Cloud test failures in the botsim-autopilot `unit` job (push a ci-ap-* branch to run it; run 40716974826 shows them).
3. Teacher speed plan, approved by Gabriel 2026-10-28: about 80 s per Fair Seer lite game now, target 10-20 s. Profile: play.scan 95%, PL.solve 70% (beam of up to 6 nodes, about 50 kids per level, each kid scanned over all 218 combos, preview about 3.8 us, mostly play_eval). Do the phases in order, one at a time, each verified on CI before merge; report measured s/game after each.
   A. Identical games: reuse a kid's scan when it enters the next beam level; per-scan caching of combo-independent work in play_eval (find_joker calls, resolve_blueprints, update_dynamic parts). Check: sim tests, test_preview, Seer, leak, BENCH 1-30 x 5 decks identical to run 40712152628 (39 wins). Expected 65-70 s.
   B. Top 8 in solve: score only the top 8 five-card plays by nominal score in PL.solve/node_best (like PL.FAST_TOP in rollouts, 2x there with 39 vs 36 wins). Check: wins not worse on the 150 BENCH games (two-proportion check as in the fair_speed gate). Expected 35-45 s.
   C (next, rethink with the profile above: rollout fast scans are now half the time, so a scan memo should cover PL.best_play in rollouts as well as solve). Memoize previews: same hand in the same situation reached again inside a solve reuses its scan. Key must cover everything scoring reads (jokers and their counters, money, hands/discards left, blind, levels, RNG proxy state). Check: identical BENCH games plus a test comparing memoized and fresh scans. Expected about 20 s.
   D. DONE (see Phase D above). Hot path in C, teacher only: profile again after C, then port only what is still hot (likely EV.evaluate, card scoring, play_eval joker effects, the preview copy) to a C library loaded through LuaJIT FFI, used on CI and Hetzner only, falling back to Lua when missing. The Lua sim stays the reference and stays in the game. Port in small pieces, each fuzzed against Lua on millions of random states (tools/botsim/fuzz.lua) with identical results. Build it in the CI workflows and hz.py LUAJIT_SETUP. Check: fuzz identical, all tests, BENCH identical. Expected 10-20 s.
   Later, inside step 3: the net's value head replaces the fast-policy rollouts (AlphaZero style), switched on gradually and measured each round. That is the route to a few seconds per game.
   Merge to main only after CI passes; the autopilot picks the new code up on its next round.
