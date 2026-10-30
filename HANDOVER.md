# Handover 2026-10-28 (night)

Read this first, then tools/botsim/autopilot/DESIGN.md. Newest state: the section "Night 2026-10-30, session 3" and its "Next" list further down; the State list right below is from 2026-10-28.

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

## Gabriel's decision (2026-10-29 evening): bigger net, trained on Hetzner
- Net size: E=64, H=256 (about 1.2M weights, check the real count; current E=32 H=128 is 323k). `--cfg E=64,H=256` in train.py.
- Train it on Hetzner, not CI: CPU torch on a CCX63 (48 dedicated cores, about 1.64 EUR/h) instead of the 4-core runner. Paid but inside the 30 EUR approval (16.50 spent, 13.50 left, round cap 5). Plan at most 96 dedicated cores.
- Remove the 2M record window first so all 20000 teacher games are used.
- There is no Hetzner job for imitation yet (the `train` job is self-play/fair rounds). Add one (or a `train` mode that only runs train.py on the teacher records in the results repo plus the eval), wire the autopilot imitation step to it with a profile switch, test it with the cloud fakes, then run it. Torch threads: set torch.set_num_threads to the box's cores; check samples/s against CI's 6835.
- Measure: mean ante on the 150 b_red white BENCH seeds (sims=0) and Lua seconds per decision vs the current net. Bar stays 5.5.
- Fair Seer calls the net in expert only where the sampled worlds disagree, so a 3-4x slower net costs little there; confirm with s/game on the BENCH white cell.

### Result (2026-10-29 21:32): E=64 H=256 on Hetzner, mean ante 5.30 of 5.5
- Job `cloud/jobs/imitate` + `imitation.paid` in the full profile (ccx63, 3 h, 5 EUR cap). Round r20261029-192717, 3.28 EUR, box gone. Autopilot stopped after it (a retry would repeat the same seed and settings).
- 2116107 records from 20000 games (window off), 1005813 weights, 60000 steps = 7.3 epochs, 4155 samples/s on 48 threads (CI small net: 6835), 63 min training.
- BENCH b_red white sims=0: mean ante 5.30, 19 wins of 150 (old net 5.05, 12 wins). Lua 0.45 ms per move, 0.057 s per game. Leak 323 passed, shuffle 8/8 identical.
- Val at the end: policy 1.139 (train 1.075), value 0.715 (train 0.165): the value head overfits badly, policy a little. More data or fewer epochs before more steps.
- Not measured yet: old net Lua ms/move on the same seeds, Fair Seer expert s/game with the new net.
- Bug found on the way: making results_key 0640 for the job broke root's backup push (ssh refuses group-readable keys). Fixed: root keeps 0600, the job gets /etc/botsim/results_key.job.

### Early deaths found (2026-10-29 21:45): the net discards everything first
- Trace (tools/botsim/train/trace_net.lua, CI run 40951115121) of the 20 games the 5.30 net lost in ante 1-2: in 55 of 60 rounds it spends every discard before playing, and 17 of those discards threw away a straight, flush, full house or three of a kind worth 150+. The teacher reached ante 6-8 on the 4 of those seeds it was checked on (the other 16 were lost: each fair.lua call overwrote the same out file).
- Cause: fair teacher records use per-world votes as the policy target (T.encode with fo.scores). Each world knows its own draws, so a discard that is lucky in one world wins that world's vote; the teacher's real move (best average over worlds) gets only its own votes.
- Fix: train.py --chosen W blends the target toward the teacher's actual move (records store it at index 0). Full profile imitation uses chosen 1.0. lazy_check verifies it on real records (CI run 40951683646 all passed). No new teacher games needed.
- Round r20261029-204808 (same data, E=64 H=256, chosen 1.0) started 21:48. Check its imitation line in runs/<run>/metrics.jsonl: mean ante vs 5.30, and rerun the trace on the new weights if it is not over 5.5.
- Autopilot paid tracker still says 16.50 spent of the 30 EUR approval, but rounds r20261029-192050 (failed start, about 1.64), r20261029-192717 (3.28) and r20261029-204808 were not added (stop before finish, failed start). Real spend under the approval is about 21.4 before this round. Fix the counting (finish on stop and on failed start) before relying on it.

### Chosen-move target did not help (2026-10-29 22:55): 5.16, hypothesis wrong
- Round r20261029-204808 (chosen 1.0, otherwise identical): mean ante 5.16, 16 wins, 22 deaths in ante 1-2 (votes run: 5.30, 19 wins, 20 deaths). 13 of the early-death seeds are the same in both runs. The difference between the runs is within noise (about 0.19 ante standard error per 150 games), but the early deaths did not go away, so the votes were not the cause.
- Full profile is back on the votes target (chosen removed); the --chosen flag stays for later tests.
- Autopilot stopped. Paid spend under the 30 EUR approval is about 24.7 (the autopilot tracker still says 16.50, see above). About 5 EUR left: one more round at most.
- Next, free on CI: check whether the teacher itself discards first. Fair Seer judges each candidate in sampled worlds that know their own draws, so the teacher's own choice may overvalue discards too, and the net copies it but without the teacher's skill at picking which discard. Trace Fair Seer lite on the 20 death seeds (fair.lua writes one `out=` per call, so give each seed its own file this time) and count rounds that discard before playing, next to the net's 55 of 60.
- If the teacher also discards first: the data is the cause. Options: a hand-strength rule in the record filter (drop or down-weight discard labels when a play clears the blind or scores far above the average needed per hand), or score_prior at sims=0, or more search (sims 32 gave about +0.15 in the A/B).

### Night 2026-10-30, session 1: quick_clear takes the net past 5.5 (on main, d6ba411)
All numbers: 150 b_red white BENCH seeds, sims=0, mean ante / wins / deaths in ante 1-2.
- The teacher discards first too. tools/botsim/train/round_stats.lua (who=net or who=fair) logs each round's D/P sequence and counts discards made while the best visible play already clears the blind. Fair Seer lite: 5.89, 34 wins, 12 early deaths, all discards before the first play in 8.8% of rounds, 2.6% of its discards made with a clearing play. 5.30 net: 20.2% and 18.3%. On the first blind (same state for both) the teacher also plays DDDDPPPP on seeds 13, 18, 138, 148 and clears; the net does the same and fails. So the order is not the bug, the choice of cards is, plus discarding when a play clears (run 40966777065).
- Votes are not the cause: tools/botsim/train/vote_stats.py on 60000 records, the chosen move holds 0.91-0.95 of the votes (median 1.0), discard records carry 0.955 discard mass (run 40973096857).
- train.py `--all-discards N`: play records are trained against every discard of the hand (records hold only about 8 random ones). records.py checks the expanded discards' features against the stored ones (15867 actions, 0 differ). Small net (E=32 H=128, window 0, 20000 steps) on CI: baseline 5.23/20/14; all-discards 4.39/12/39 (it almost stops discarding: the training sees every discard but only about 24 plays, so at inference all 218 plays inflate the play mass). 1875 samples/s vs 4650.
- MCTS options (assets/bot/nn/mcts.lua, all off by default, passed through eval.lua, round_stats.lua, fair_shuffle.lua):
  - `type_mass=T`: in play, discard when the discard share of the probability is above T (1 means 0.5), then the best action of that type. `tm_plays=N` counts only the top N plays by estimate, as in the records. All-discards net: 4.42 (T=0.5), 5.23/16 (T=0.5, N=16), 5.25 (T=0.35, N=16). Hurts nets trained without all-discards (5.16, 5.23).
  - `score_prior` 0.3/0.6 at sims=0: the net stops discarding, 2.8-4.6. Do not use at sims=0.
  - `quick_clear=1`: at the root in play, if the best visible play scored on F.sanitize(state) (canonical seed, hidden cards replaced, the same sanitizing Fair Seer uses) clears the blind, play it. Baseline small net 5.23/20/14 -> 5.55/21/9 (paired diff +0.32, z 2.9); 5.30 net 5.30/19/20 -> 5.47/22/19; all-discards+tm16 5.23 -> 5.36 (run 40973914155). Discards with a clearing play drop from about 500 to 10-21. Shuffle check with quick_clear 8/8 identical, leak quick 156/156, Seer 196/196, nn 46/46 (run 40974295586), autopilot unit 43 OK (run 40974229079; the real-sshd 12.4 s timing test failed once, passed on rerun).
  - all-discards + `--chosen 0.5`, evaluated with type_mass 0.5, tm_plays 16, quick_clear: 5.61/26/10, best measured, but vs baseline+quick_clear the paired diff is +0.06 (z 0.4): noise. Without the decision options it is 4.19-4.63 (run 40973032350, 40980722921). The `--chosen 1.0` variant: 5.19/14 (tm16), 5.29/15 (tm16 + quick_clear), 4.83/18 (quick_clear alone) (run 40981304611). Training-side changes are inside run-to-run noise; keep the votes recipe.
- Profile key `imitation.eval_args` reaches the gate's eval and shuffle check on CI (steps.py) and Hetzner (IMIT_EVAL_ARGS in jobs/imitate/run); `all_discards` reaches train.py the same way (IMIT_ALL_DISC). Full profile: eval_args quick_clear=1, training recipe unchanged.
- Speed (backlog item 5): Lua 0.11 ms/move small net, 0.15 big net (eval timings on CI runners). Fair Seer expert on 12 BENCH white seeds, three concurrent pinned processes: no net 0.071 s/decision, small net 0.083, big net 0.051, so the net's cost is inside CI noise (run 40976105962).
- sims=32 (search on the real state reads the hidden deck, reference only): 5.30 net 5.39/24, with quick_clear 5.43/25; small net 5.59/24, with quick_clear 5.44/23; 0.15-0.23 s/game (run 40980977068). Same band as the fair quick_clear net at sims=0.
- Phase C (speed-c, backlog item 6) was already decided on 2026-10-28: games identical but no measurable gain, not merged. Nothing to do.
- Paid: expert_ok switched off (a pass would otherwise start expert rounds unattended), redo imitation, round r20261030-003310 started 01:33 (ccx63, E=64 H=256, votes, 60000 steps, gate eval quick_clear=1). Ledger before it 40.85 EUR. Result: 5.47, 22 wins, gate failed (3.28 EUR). The same tick started an identical retry (r20261030-015130); stopped at 02:55, box deleted (1.64 EUR). Ledger 45.78, 29.64 of the 40 EUR approval used. Autopilot stopped at imitation attempt 2, expert_ok off. Decision for Gabriel in the night report.

### Night 2026-10-30, session 2: pace rule passes 5.5, teacher data was on no deck (on main, fa21e59)
- `pace=P` (MCTS option, with quick_clear): at the root in play, with discards left, when the best visible play (scored on F.sanitize, as quick_clear) times the hands left is at least P times the chips still needed, play it instead of discarding. `pace_net=1` plays the net's best play instead of the best visible one (worse). Wired through eval.lua, round_stats.lua, fair_shuffle.lua. Full profile gate: `eval_args quick_clear=1 pace=1.25`.
- Measured with the 5.30 big net (E=64 H=256) and the small CI net (E=32 H=128), sims=0, mean ante / wins / early deaths; tools/botsim/train/bench_sum.py prints these and the paired diff:
  - Gate seeds BENCH 1-150 b_red white: big 5.47 (quick_clear) -> **5.56 / 24 / 14** (pace 1.25).
  - Held-out BENCH 151-1150 b_red white: plain 5.12 / quick_clear 5.36 / pace 1.25 **5.55** (+0.19, z 3.0); small 4.83 / 5.15 / 5.38 (+0.23, z 4.1). Pace 1.0-1.75 all help, 0.75 hurts (-0.2), 3-4 do nothing.
  - All 15 decks x stakes 1 and 4, 60 seeds each (1800 games): pace 1.25 +0.14 (z 4.2) big, +0.20 (z 5.9) small.
  - CI runs 40989163326, 40989381323, 40989873769.
- The Hetzner round r20261030-003310 (3.28 EUR) produced a net byte-identical to r20261029-192717: train.py is deterministic, so a repeat with the same data and recipe buys nothing.
- **Teacher data bug**: profile teacher `decks: "all"` went straight to teacher.lua, which played the literal deck "all": the engine gives it no back (3 discards, no deck one-hot). All 20000 teacher games are on that no-deck setup; the net never saw b_red (4 discards) in training. On the no-deck setup (CI run 40989622637, BENCH 1-150 white) the teacher gets 5.19 / 27 / 23 and the big net 5.03 plain, 5.25 quick_clear, 5.32 pace: the net matches the teacher there, while on b_red the teacher is 5.89 vs 5.30-5.56. Fixed: `decks=all` in teacher.lua now rotates the 15 real decks by seed (one game per seed and stake, so seed and game counts are unchanged).
- Teacher speed now: about 6.6 s per Fair Seer lite game on a CI core (BENCH no-deck), 30 games per 4-core job in about a minute.
- Backlog item 7 built: `autopilot.py extend teacher --games N [--ci] [--hold]` (target = games + N, next seeds continue, imitation and best reset). CI teacher jobs run 4 teacher.lua slices in parallel; finish_teacher stores every slice as runs/ci-<run>/teacher/wNNN.bspr.gz.NNN in the results repo, the same layout as Hetzner rounds, so CI and Hetzner imitation read them the same way. `flag imitation_hold on` makes a paid imitation round wait. CI imitation now passes the profile's window, cfg and chosen. Unit 46 OK (run 40990316211), slices plus train.py read checked (run 40990288249), nn 46/46, leak 156/156, shuffle with pace 8/8 (run 40989817945).
- Slow teacher games: b_anaglyph sometimes takes 25+ minutes in Fair Seer lite (TEACH14098 stake 1: 1576 s, won at ante 9; TEACH14263 stake 2: over 20 minutes, its job cancelled at 04:07). Not an infinite tag loop (Double Tag cannot copy Double Tag in econ.lua); probably the search over stacked tags. teacher.lua's `time_limit` only works in the cheating play mode. Fix later: a per-game time cap in fair mode that ends the game cleanly, or find why anaglyph decisions explode. Until then a batch can hang on one job; cancelling the run keeps every finished job's games (the autopilot treats a cancelled run like a finished one).
- CI imitation experiment (run 40997737212 from branch exp-vw, tools/botsim/results/s2/imit_exp.py is the dispatcher, small net E=32 H=128, window 0): new real-deck data = the first 14160 CI games (runs ci-40990898399, ci-40992262389, ci-40995732156), mixed = those plus the 20000 old no-deck games. sims=0 with quick_clear+pace 1.25; held-out = BENCH 151-1150 b_red white:
  - old data only (small523, 20000 steps): held-out 5.38, gate 5.55 (qc only), all decks 4.96.
  - new only, 20000 steps: held-out 5.30, gate 5.30, all decks 4.96. About the same as the old data with fewer games, so the deck mismatch is not what holds b_red back.
  - mixed, 20000 steps: held-out 5.40, gate 5.52, all decks 4.92. Value overfit gone (val 0.373 vs train 0.362).
  - mixed, 20000 steps, `--value-weight 0.25`: held-out **5.52** (vs mixed +0.12, z 2.3), gate **5.64 / 19 / 11**, plain 5.34 on the gate, all decks 4.95. Equal to the big net on old data (5.55 held-out).
  - all 41160 games (run 41002689972, from main), 20000 steps, weight 0.25: held-out **5.54 / 128 / 66** (equal to the big net), gate 5.43 / 16 / 10, plain held-out 5.03, all decks 5.02 (best), val policy 1.221 vs train 1.242.
  - all 41160 games, 40000 steps, weight 0.25: held-out 5.46 / 133 / 99, gate **5.76 / 27 / 12**, all decks **5.08 / 157** (+0.19 over the big net, z 5.0), val policy 1.154 vs train 1.164. Nets kept as artifacts s2exp-imit-all-all20kvw / -all40kvw of run 41002689972 (30 days).
  - mixed, 40000 steps, weight 1: held-out 5.35, gate 5.60 / 20 / 10, all decks 5.01 (+0.09, z 2.3 over 20000 steps); val policy 1.208 vs 1.259.
  - sims=32 on these nets (unfair reference): 5.39 and 5.59 on the gate, still no better than sims=0 with pace.
- New profile key `imitation.value_weight` (train.py `--value-weight`, IMIT_VALUE_W on Hetzner); the full profile uses 0.25.
- Started 03:17: `extend teacher --games 20000 --ci --hold` on the live autopilot (seeds TEACH10001 on, all 15 decks rotating, stakes 1 and 2). imitation_hold is on, so when the games are in the autopilot waits at imitation instead of starting a paid round.

- Teacher extension finished 05:05: 41160 games (20000 old no-deck + 21160 real-deck from CI runs ci-40990898399, ci-40992262389, ci-40995732156, ci-40997707969, ci-40999965686). Three straggler batches cancelled by hand (anaglyph).
- Tried and failed tonight: score_prior 0.05-0.2 at sims=0 (3.15 at every weight), pace_net, pace 0.75 and 3-4, sims=32 (worse than sims=0 with pace, value head), real-deck data alone (no gain over the same amount of no-deck data).

#### Where things stand (05:30)
- Autopilot `autopilot`: step imitation, status waiting on `imitation_hold`, expert_ok off. Teacher 41160 games. The next imitation round (paid, ccx63, E=64 H=256, 60000 steps, window 0, value_weight 0.25, gate quick_clear=1 pace=1.25) starts only after `flag imitation_hold off`.
- Ledger 45.78 EUR; 29.64 of the 40 EUR approval used (the tracker says 27.99). One round is about 3.28 EUR.
- The existing big net already passes the gate with pace (5.56 gate, 5.55 held-out) but the autopilot has no way to adopt it without a round.

#### Next
1. Morning decision (Gabriel): release the paid imitation round (`gh workflow run botsim-autopilot.yml -R JupiterianSoul/botlatro-sim --ref main -f command=flag -f args="imitation_hold off"`), or train the small net on CI for free (see the full-data CI run above), or adopt the existing big net. Release only after the night runner's money guard has ended (09:00): it deletes any box once the ledger reaches 46.14 EUR.
2. Gate noise: 150 seeds give about 0.15 ante standard error; the same nets are 5.43-5.64 on the gate and 5.52-5.55 on 1000 held-out seeds. `imitation.eval_seeds` 1000 costs 20 seconds at sims=0. Gabriel decides (the bar was defined on 150 seeds).
3. Anaglyph slowness in the fair teacher (see above): find the exploding decision or add a clean per-game cap in fair mode.
4. Value head: weight 0.25 helped; also try 0.1 and dropout, and check sims>0 again once the value head generalizes (search still loses to sims=0 + pace).
5. More real-deck teacher data is cheap now (21160 games in under two hours of free CI): `extend teacher --games N --ci --hold` again when the new round says data helps.

### Night 2026-10-30, session 3: the big net trains on free CI, anaglyph fixed, stake ladder (on main, 448a7f3)
All imitation numbers: sims=0 with quick_clear=1 pace=1.25, mean ante / wins / deaths in ante 1-2. Gate = BENCH 1-150 b_red white, held-out = BENCH 151-1150 b_red white, decks = 15 decks x stakes 1 and 4 x 60 seeds.
- **E=64 H=256 trains on a free 4-core CI runner at about 4950 samples/s, faster than the paid ccx63 (4155 on 48 threads).** 20000 steps take about 20 minutes. So the paid Hetzner imitation round buys nothing over CI.
- CI imitation run 41005619660 (tools/botsim/results/s3/imit_exp3.py, all 41160 teacher games, window 0, artifacts `s3exp-imit-<label>` with net.bnnw, kept 30 days):
  - big E=64 H=256, 20000 steps, value weight 0.25: gate **5.70 / 21 / 9**, held-out **5.58 / 140 / 85**, decks 5.08, plain gate 5.08.
  - big, 60000 steps (the full profile's recipe, what the held paid round would train): gate **5.77 / 27 / 12**, held-out **5.69 / 150 / 78**, decks **5.18 / 187**, plain held-out 5.25. Best net so far (+0.14 held-out over the 5.30 net, +0.10 over 20000 steps). Val policy 1.075 vs train 1.082: no overfit. Artifact `s3exp-imit-big60kvw` (net.bnnw), run 41005619660, kept 30 days.
  - small E=32 H=128, value weight 0.1: 20000 steps held-out 5.48 (vs 5.54 with 0.25, paired -0.06, z -1.2); 40000 steps held-out **5.63 / 142 / 69** (vs 5.46 with 0.25, +0.17, z 3.0), gate 5.81 / 24 / 8, decks 5.09. Mixed: value weight 0.1 vs 0.25 is inside run-to-run noise.
- **Anaglyph slowness fixed.** Cause (tools/botsim/seer/fair_trace.lua, run 41005752280): b_anaglyph hands out a Double Tag after every boss, Double Tags cannot copy each other, so the teacher carries 5-8 of them by ante 6-8. Skipping a blind for a Juggle Tag then gives 8 Juggle Tags, +24 hand size, and PL.scan enumerates every 1-5 card subset of a 32-card hand (about 240000 instead of 218). Single decisions took 773, 597, 316 s. Fix (assets/bot/seer/play.lua): hands above `PL.MAX_SCAN_HAND` 16 scan the subsets of 12 picked cards (forced card, the 5 best of the commonest suit, then by rank count and chips). Hands of 16 or fewer are unchanged (the C scan covers up to 16, fuzz compares up to 14). TEACH14263 1835 s -> 8.0 s (still a win), TEACH14098 1576 s -> 12.8 s. Seer tests 200/200 (new big hand test), fair tests 323/323, normal teacher output byte-identical (run 41009226288).
- Safety net: teacher.lua `game_cap` (default 600 CPU s, fair mode) drops a game that runs longer and logs `capped` (run 41006095803: capped path works, 6 normal games byte-identical with and without).
- **Stake ladder** (run 41008324709, 41007734739, 41008364235; b_red, BENCH seeds; net = the 5.30 big net with quick_clear + pace, 1000 games per stake; teacher = Fair Seer lite, 200 games, 300 at gold):

  | stake | net ante / win % | teacher ante / win % |
  | --- | --- | --- |
  | 1 white | 5.53 / 12.9 | (5.89 / 22.7 on 150) |
  | 2 red | 5.07 / 8.7 | 4.89 / 13.0 |
  | 3 green | 4.20 / 1.1 | 4.24 / 3.5 |
  | 4 black | 4.12 / 1.1 | 4.13 / 3.0 |
  | 5 blue | 3.87 / 0.6 | 3.88 / 1.0 |
  | 6 purple | 3.62 / 0 | 3.54 / 0 |
  | 7 orange | 3.34 / 0 | 3.37 / 0 |
  | 8 gold | 3.07 / 0 | 3.10 / 0 (std budget 3.19 / 0 of 160, 13.9 s/game) |

  The 60000-step CI big net (run 41012123471): 5.70 / 15.1, 5.15 / 9.8, 4.22 / 1.6, 4.12 / 0.8, 3.88 / 0.9, then 3.63, 3.38, 3.08 with 0 wins: better imitation only helps at stakes 1-2.
  The net equals its teacher at every stake. Wins collapse at green stake (faster blind scaling) and are zero from purple up, for the teacher too. Imitating Fair Seer cannot reach Gold Stake wins; the next lever is a stronger player at high stakes (the expert step: search plus the net, trained on its own games), not more imitation.
- Paid: none. The ledger was 45.78 EUR and the night runner's guard deletes any box at 46.14, so no round could run.
- The autopilot's paid tracker gap (failed starts not added) is cosmetic: budget_problem uses max(tracker, ledger - ledger_base).

#### Next (after session 3)
1. Morning decision: run imitation on CI instead of Hetzner. `imitation_hold` only holds the paid path; removing `imitation.paid` from the full profile makes the autopilot train the same E=64 H=256 recipe on free CI (about an hour for 60000 steps). The results above say it is at least as good as the paid round.
2. Gold Stake plan: measure what the expert step (Fair Seer with the net as proposer, or MCTS with the net at sims > 0 on sanitized states) does at stakes 3-8 before spending on it; the teacher itself wins 0% from stake 6.
3. Gate noise (unchanged): 150 seeds give about 0.15 ante standard error; the held-out 1000 numbers above are the ones to trust.

### Night 2026-10-30, session 4: fair search helps in the economy, hurts in play (on main)
- eval.lua `fair=1`: every decision searches a fair world instead of the real state (F.world(F.sanitize(s), "FW<seed>_<move>"), hidden cards reshuffled by a key the real seed does not decide), no tree reuse. At sims=0 it gives exactly the plain result (5.30 big net, gate, quick_clear + pace: 5.56 / 24 / 14, same as before), so the features read nothing hidden.
- 5.30 big net, sims=32 fair=1 quick_clear=1 pace=1.25, b_red BENCH 1-200 per stake, paired against the sims=0 ladder on the same seeds (run 41012661948, ladder run 41008324709):

  | stake | sims=0 ante / wins / early | fair sims=32 | paired diff |
  | --- | --- | --- | --- |
  | 1 | 5.47 / 28 / 20 | 5.28 / 30 / 25 | -0.20 (z -1.2) |
  | 2 | 5.04 / 18 / 25 | 4.68 / 12 / 36 | -0.35 (z -2.3) |
  | 3 | 4.22 / 1 / 27 | 3.87 / 2 / 44 | -0.35 (z -3.2) |
  | 4 | 4.18 / 2 / 27 | 3.79 / 1 / 41 | -0.39 (z -3.7) |
  | 5 | 3.94 / 3 / 36 | 3.75 / 2 / 43 | -0.19 (z -1.8) |
  | 6 | 3.63 / 0 / 45 | 3.38 / 0 / 53 | -0.25 (z -3.1) |
  | 7 | 3.35 / 0 / 45 | 3.31 / 0 / 51 | -0.04 (z -0.5) |
  | 8 | 3.10 / 0 / 55 | 2.97 / 0 / 61 | -0.13 (z -1.8) |

  0.19-0.45 s/game. Search on one sampled world with this value head loses everywhere and adds early deaths: the expert step needs a better value head or several worlds per decision before it can beat the net alone.
- Same check with the 60000-step CI net (value weight 0.25, all data; run 41013089029, paired with its sims=0 ladder run 41012123471, 200 seeds): sims=0 with fair=1 equals plain (5.77 / 27 / 12). Fair sims=32: stake 1 5.48 / 37 / 24 vs 5.66 / 33 / 16 (-0.18, z -1.2), stake 2 4.86 / 24 / 42 vs 5.06 / 20 / 28 (-0.20), stake 3 3.96 / 4 / 44 vs 4.22 / 3 / 26 (-0.26, z -2.3), stake 4 -0.32 (z -3.0), stake 6 -0.17, stake 8 -0.14 (z -2.0). sims=8 is worse than 32 (stake 1 -0.43, stake 3 -0.34). The better value head does not change the picture: search buys a few extra wins at stakes 1-3 and pays with many more early deaths.
- **Where search hurts and where it helps** (eval.lua `search_ph`, comma list of phases where the search runs, sims=0 elsewhere; 60000-step net, fair=1 sims=32, run 41013291103): search only in `play`: stake 1 5.24 / 28 / 28 (-0.42, z -2.8), stake 3 3.88 / 1 / 46 (-0.34). Search only in `shop,pack,blind_select`: stake 1 **5.99 / 44 / 14** (+0.33, z 3.6), stake 3 **4.33 / 5 / 24** (+0.11, z 2.2), 0.12-0.30 s/game. The value head guides economy decisions well and play decisions badly; the early deaths come from searching hands and discards.
- **Econ-only fair search ladder** (60000-step net, `sims=32 fair=1 search_ph=shop,pack,blind_select quick_clear=1 pace=1.25`, run 41013395254, paired with ladder run 41012123471): gate 1-150 **6.10 / 37 / 10** (+0.33, z 3.2); stake 1 seeds 1-1000 **5.93 / 188 / 67** vs 5.70 / 151 / 76 (+0.24, z 5.4); stake 2 +0.10 (z 1.3), 4 +0.12 (z 2.0), 5 +0.10 (z 1.9), 6 +0.04, 7 +0.03, 8 +0.01, still 0 wins from stake 6 up (200 seeds each). 0.08-0.32 s/game.
- Tuning (run 41014064682, 60000-step net, economy-only fair search): stake 1 seeds 1-400 sims=16 5.96 / 77 / 23 (-0.11 vs sims=32, z -1.7), sims=64 6.05 / 90 / 27 (-0.01 vs 32, 0.56 s/game): keep sims=32. All 15 decks, 60 seeds each, paired with the same net at sims=0: stake 1 **6.22 / 198 / 51** vs 6.02 / 179 / 63 (+0.20, z 5.1), stake 4 **4.46 / 14 / 104** vs 4.35 / 8 / 112 (+0.11, z 4.3).
- Shuffle check (fair_shuffle.lua now takes `fair` and `search_ph` for who=net; run 41013734764, 5.30 net, sims=32, quick_clear + pace, b_red white): economy-only fair search 16/16 identical, fair search everywhere 16/16, control fair=0 (search on the real deck) FAILED 7 of 8 as it should.

#### Next (after session 4)
1. Add `sims=32 fair=1 search_ph=shop,pack,blind_select` to the gate's eval_args if Gabriel agrees (it is the best fair player measured at white: 5.93 on 1000 seeds; the shuffle check passes).
2. Train the net on games of this player (expert step, free on CI): its economy choices beat the net's own. Teacher data could come from it at about 0.3 s/game instead of 6.6 s for Fair Seer lite.
3. Play decisions: the value head steers hands and discards badly. Several worlds per decision or a better value head before searching in play again.
4. Gold Stake is still at 0 wins from stake 6 up for every player measured.

### Night 2026-10-30, session 5 (short, started 07:28; on main)
- Backlog 1-6 were already done by sessions 1-4 (goal 5.5 reached in session 1, score_prior and ms per move measured in session 2, phase C closed on 2026-10-28). The ledger is at 45.78 EUR, under the 46.14 stop, so no paid round could run.
- Which economy phase the search helps in, with the 5.30 net (fair_search.py `split`, run 41014391956, sims=32 fair=1 quick_clear + pace, b_red white BENCH 1-400, paired with the same net at sims=0): sims=0 5.58 / 54 wins / 34 early, 0.06 s/game; shop+pack+blind 5.64 / 55 / 30 (+0.07, z 0.9), shop only 5.62 / 55 / 28 (+0.04), pack only 5.63 / 57 / 34 (+0.05, z 1.2), blind select only 5.57 / 53 / 34 (-0.01). With this net's value head the economy search gains little; the +0.24 of session 4 came from the 60000-step CI net (value weight 0.25). So the value head quality decides it, and blind select search adds nothing.
- Next is unchanged from session 4's list. Stale remote branches from earlier sessions (ci-bench-fairspeed1-4, ci-bench-fixes1-2, ci-ap-nodash, ci-ap-teacher, ci-ap-base) were left alone: check them before deleting.

### Plan: 20000 more teacher games on free CI (backlog item 7, built in session 2, see above)
- State today: teacher.games 20000, next 10001 (seeds TEACH0001-10000, stakes 1 and 2), artifacts are the two hz runs. The CI teacher path already exists (steps.teacher_jobs: 40 jobs x 60 seeds per batch, finish_teacher appends `{run, tag}` artifacts, imitation_jobs downloads both kinds).
- Build: an autopilot command `extend teacher --games N --ci` that keeps st.teacher (games, next, artifacts), stores a target `st.teacher.target = games + N` and `st.teacher.ci = true`, goes back to step teacher and clears the imitation gate and best. teacher_jobs/finish_teacher read the target from state when set; steps.paid_step returns False for teacher when `st.teacher.ci`.
- The Hetzner imitate job only fetches hz runs from the results repo (IMIT_RUNS). Make CI teacher batches push their teach.bspr to the results repo as runs/ci-<run>/teacher/w*.bspr.gz.NNN (same split as the boxes), so CI and Hetzner imitation both read everything from the store.
- Test: tiny profile on a ci-ap branch (2 seeds per job, 2 jobs), check the new records land next to the old ones and imitation sees both.

## Earlier plan (kept for reference): make the imitation net reach mean ante 5.5 (free, CI only)
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
