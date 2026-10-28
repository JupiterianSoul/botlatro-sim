# Seer v1

Seer is the cheating brain from `docs/BOTLATRO_PLAN.md`, milestone 4. It runs on the exact sim (`assets/bot/sim/`), so it knows every future draw, shop, pack, tag and boss: they all follow from the seed and its own actions. It never touches the sim's internals beyond `E.step`, `ST.clone` and the shop cost helpers, so every line it plays is a plain list of SPEC actions that replays the same way in the sim and, because the sim matches the game, in the game.

## Files

| file | what |
| --- | --- |
| `assets/bot/seer/play.lua` | blind play: subset scan, fast rollout policy, exact blind solver |
| `assets/bot/seer/seer.lua` | decisions for every phase, rollouts, shop beam search, both modes, replay |
| `tools/botsim/seer/bench.lua` | seed-suite benchmark, writes markdown to `tools/botsim/results/` |
| `tools/botsim/seer/teacher.lua` | Seer games as `.bspr` self-play records for Fair's teacher start |
| `tools/botsim/seer/check_records.py` | reads `.bspr` files through `train/bnn/records.py` (works without numpy and torch) |
| `tools/botsim/seer/test/run.lua` | Seer tests |
| `assets/bot/seer/fair.lua` | fair Seer: determinized planning over sampled worlds (PIMC) |
| `tools/botsim/seer/fair.lua` | fair Seer runner, one JSON line per run |
| `tools/botsim/seer/test/fair_test.lua` | leak tests for fair Seer |

Pure Lua, no FFI needed, so the same code can run inside the game and on the phone later.

Run from the repo root:

```
nice -n 19 taskset -c 0-3 luajit tools/botsim/seer/test/run.lua          # all checks, about a minute
nice -n 19 taskset -c 0-3 luajit tools/botsim/seer/test/run.lua quick    # without the full solve
nice -n 19 taskset -c 0-3 luajit tools/botsim/seer/bench.lua --seeds 200 --decks all --stakes all --jobs 4 --out tools/botsim/results/seer_dev.md
nice -n 19 taskset -c 0-3 luajit tools/botsim/seer/bench.lua --seeds 8 --mode solve --max_lines 6 --jobs 4
nice -n 19 taskset -c 0-3 luajit tools/botsim/seer/teacher.lua --seeds=50 --decks=b_red,b_blue --stakes=1 --out=tools/botsim/train/out/seer.bspr
python3 -I tools/botsim/seer/check_records.py tools/botsim/train/out/seer.bspr
```

Bench options: `--seeds N` (seeds `SEER0001..N` for every deck and stake), `--decks b_red,b_blue|all`, `--stakes 1,2|all`, `--mode play|solve`, `--max_lines N` and `--time_limit S` for solve, `--jobs J` (J worker processes, each runs every J-th job), `--set key=value,...` to override Seer settings, `--prefix`, `--label`, `--out`.

## How it plays

### Blinds (`play.lua`)

`PL.scan` previews every legal play subset (up to 5 cards, the Cerulean Bell card always included) with `E.preview_into`. Previews copy the whole state, RNG included, so a preview is the real score of that play.

`PL.solve` is the exact blind solver used for real moves. It is a beam search over play and discard sequences on cloned states:

- From each node it tries the top clearing plays (stepped for real, so The Hook and anything else the preview misses is caught), the top 3 non-clearing plays, and up to 6 discards. A discard candidate is "keep the cards of one of the best plays, throw up to 5 of the others, lowest first"; the draw that follows is whatever the deck order says.
- Children are ranked by chips so far plus their best immediate play, deduplicated by (chips, hands, discards, hand), and the best 6 are kept.
- Goal order: clear the blind, then fewest hands (each hand left is a dollar and keeps the hand count for jokers), then fewest discards, then margin. It stops early when one hand clears.
- No clear found: it plays the line with the highest chips, which is where the run dies.

`PL.fast_action` is the cheap policy for rollouts: best play from 5-card subsets only (all subsets when fewer than 5 cards, a Half or Square Joker, The Eye, The Mouth or The Psychic make smaller plays matter), and the old greedy discard rule.

### Rollouts and value (`seer.lua`)

Every choice outside the blind is scored by a rollout: clone the state, play on with the fast policy (select every blind, use held planets in the shop, leave the shop, skip packs) until `H` boss blinds are cleared or the run ends. Since the sim is exact, a rollout is a real future, not a sample; it is only as good as the fast policy that plays it.

Value of a rollout end state, measured from the decision state:

```
10 * (blinds cleared + blinds skipped)
+ 2 * mean over cleared blinds of log(best single hand)
+ 0.04 * min(money, 60)
+ 1000 if won, - 40 if dead
```

The middle term is the build's strength. It is absolute (not a ratio against the blind) so it keeps growing past the overkill point; an earlier version clipped a ratio at 20x and could not tell a good joker from a useless one on early blinds.

### Shops and packs

Beam search over shop actions, every node scored by a rollout from it:

- moves: buy a joker or playing card, buy and use a consumable that needs no target, redeem, open a pack, reroll, use a held consumable that needs no target, swap (sell joker k then buy shop joker i, one move, only when the slots are full), and at the root one-joker reorders when Blueprint or Brainstorm is owned.
- an opened pack is resolved right there: each pick (with candidate target sets for tarots and spectrals: highest cards, lowest cards, highest plus lowest, a few single cards, off-suit cards for suit tarots) or skip is rolled out and the best taken, until the pack closes.
- beam width 3, depth 3, states deduplicated by a key of money, jokers, consumables, shop rows, reroll cost, deck size and hand levels. Stopping (leave) is always an option because every node is ranked by its own rollout.
- horizon 2 bosses. When the best line dies inside the horizon or its weakest blind is cleared with less than 1.5x (log margin 0.4), the beam's nodes are re-scored with horizon 3 ("deeper where the run is tight").

Free sells were tried first and were bad: a myopic rollout happily sold Zany Joker for its $3 because Three of a Kind never came up in the next two antes, then left the slot empty. Swap keeps sells tied to a buy.

Blind select compares select, skip (when allowed) and boss reroll (when the voucher and money allow) by rollout, re-scored with the longer horizon when tight. Packs opened outside a shop (tags) use the same pack resolver. At the start of a blind, held consumables that need targets are tried with the candidate target sets and used when a rollout says so.

### Plans

A decision returns a plan (the solver's whole blind, or the shop line ending in leave). Seer replays it action by action while `s.step` matches, so a blind is solved once, not once per hand. Plans are exact because the sim is deterministic.

### Solve first

`seer:solve(setup, {max_lines, time_limit}, progress)`:

1. Plays full lines with a small portfolio of settings (default; horizon 3; more weight on money; more weight on strength and a wider beam; horizon 1). Each line records checkpoints at shop and blind decisions with the runner-up options and their value gap.
2. With lines left, it branches: it takes the open alternative with the smallest gap, weighted toward one ante before the line died, replays the prefix plus the alternative, and lets Seer continue from there.
3. Stops at the first win, at `max_lines`, or at `time_limit`.
4. The best line is replayed from `E.new_run(setup)`. A win is only reported when the replay wins: "Win found, guaranteed, final ante 8". Otherwise "No win found, best line ante Y". That is never a proof that the seed cannot be won; it only means this search did not find a win.

`progress` gets `{lines, best_ante, won, time}` after every line.

### Play while thinking

`seer:choose(s)` returns the next action for any state, `seer:play(setup, on_action)` plays a whole run. Same decisions as a solve's first line.

## What Seer reads

Seer reads the whole state, including deck order and RNG, because it is the cheater. What matters is that it only acts through `E.step` on the real state, with actions a player can make: the tests check that every action is a SPEC action with only SPEC fields, that the sim accepts it, that plays keep the Cerulean Bell card, that `choose` never changes the real state or its RNG, and that the line replays to the same final snapshot. Nothing in Seer depends on `pairs()` order over string keys, `math.random` or the clock, so a seed gives the same line in every process.

## Benchmark

Seeds `SEER0001..N` for every deck and stake (dev suite: N = 200). Only small slices were run on the laptop (4 worker processes, `nice -n 19 taskset -c 0-3`); the full suite is for the cloud. CPU seconds are per run, per process, with 4 processes sharing the 4 cores.

Play while thinking, 4 seeds per cell, 48 runs, about 8 minutes wall (`tools/botsim/results/seer_v1_slice_play.md`):

| deck | stake 1 wins | stake 4 wins | avg final ante (1 / 4) | cpu s per run (1 / 4) |
| --- | --- | --- | --- | --- |
| Red | 1/4 | 1/4 | 6.25 / 6.00 | 26 / 23 |
| Blue | 3/4 | 1/4 | 7.75 / 6.75 | 55 / 45 |
| Yellow | 2/4 | 1/4 | 7.25 / 5.75 | 58 / 48 |
| Green | 1/4 | 0/4 | 7.00 / 5.50 | 47 / 29 |
| Black | 1/4 | 0/4 | 6.00 / 4.25 | 39 / 21 |
| Plasma | 2/4 | 0/4 | 7.25 / 5.75 | 50 / 34 |
| all | 10/24 (42%) | 3/24 (13%) | | 40 average |

Overall 13/48 (27%), average death ante 5.66. Treat these as rough: 4 seeds per cell is very noisy.

Red, stake 1, seeds 1 to 8, while tuning (play mode):

| version | wins | avg final ante | cpu s per run |
| --- | --- | --- | --- |
| first version, horizon 1, strength as clipped ratio | 0/8 | 6.25 | 46 |
| absolute strength, tight re-score instead of re-search | 2/8 | 6.25 | 21 |
| horizon 2 (3 when tight) | 4/8 | 6.88 | 35 |
| same, strength weight 4 | 2/8 | 6.62 | 33 |
| horizon 2 + swap instead of free sells (current) | 5/8 | 7.12 | 39 |

Solve first, Red stake 1, seeds 1 to 4, `--max_lines 6`: 3/4 wins (play mode: 1/4). Seeds 3 and 4 were turned into wins by the portfolio (lines 4 and 3), seed 1 stayed at ante 6 after 6 lines. 108 CPU seconds per seed on average, 143 s for the seed without a win.

## Teacher records

`teacher.lua` plays Seer runs and writes `.bspr` version 2 records through Fair's `REC.encode_choice`, the same format self-play writes (see "Writing records from another brain" in `tools/botsim/train/DESIGN.md`):

- one record per decision of every type Fair lists: blind select, skip, boss reroll, shop, packs, consumables and play/discard. Features and actions are Fair's (`features.state`, fair view, `features.list_actions`), Seer's move is found with `features.find_action`.
- up to K = 24 actions per record: Seer's move first, then play rows by highest estimate and the remaining rows in listing order. Visits are one-hot on Seer's move, priors uniform, `n_sims` = 800 so `--policy-min-sims` keeps them.
- the run header carries the real outcome (`won`, `final_ante`), the value target. Do not use `--stop_ante` for training data: a cut run is written as a loss at that ante.
- skipped, and counted in the summary line: forced steps (one legal action, like cash out) and any Seer move Fair cannot express (`unmatched_<phase>`). On TEACH0001 (Red, stake 1, a win) that was 129 records, 29 forced, 0 unmatched.

Solve mode (`--mode=solve --max_lines=N --time_limit=S`, optional `--wins_only=1`): Seer solves the whole run first, then the winning (or best) line is replayed from a fresh state and every step is encoded the same way, so the records follow the line that actually won. A step that does not replay counts as `replay_break`. This is the Seer pool the train job mixes into every batch (`TRAIN_SEER_MIX`, see the cloud README).

Checked: the Lua reader (`records.lua`) decodes the records in the tests, and `train/bnn/records.py` reads a teacher file through `check_records.py`.

## Fair Seer (determinized planning)

Fair Seer plays without reading anything a player cannot see. At every decision it builds N sampled worlds that agree with every visible fact, lets Seer plan in each one, and plays the action with the best average result over all worlds. Then it looks again at the real state and repeats.

### What is hidden and how it is resampled

`F.sanitize(real)` is the only function that touches the real state, and it starts with a clone. It throws away or canonicalizes everything hidden:

- the seed, `hashed_seed`, the hash cache and every RNG stream (`rng`, `rng_ids`, `n_rk` cleared). This covers every future draw roll, shop reroll, pack content, tag, boss, voucher, Lucky Card and Wheel roll.
- the unseen card pool: the deck plus face-down hand cards. The cards are sorted by id and put back into the same slots, so only the set is kept, not the order or which card sits face down.
- joker order while every joker is face down (Amber Acorn): sorted by joker id and uid.
- the next voucher while `features.voucher_hidden` says it is hidden: set to 0.

`F.world(base, key)` clones that view and gives it a fresh seed string (`W<sampler>_<step>_<ante>_<k>`), shuffles the unseen pool back into the slots with a hash of the key, shuffles hidden joker order, and draws a new hidden voucher with the engine's own `get_next_voucher`. Visible facts (hand, jokers, consumables, money, the shop on screen, hand levels, deck composition, discard pile) are copied as they are.

### One decision

1. `round_eval` is always cash out. Game over and win stop.
2. In each world a fresh Seer (`budget.seer` settings) runs `choose` and returns its whole plan (the shop line to leave, the blind solve, one blind select or pack pick).
3. Plans are grouped (by first action in a blind, by the whole line elsewhere) and the `max_cands` most proposed ones kept. If every world proposes the same thing, it is played without more search.
4. Otherwise each candidate is evaluated in every world: apply it (in a blind, the first action, then finish the blind with a small `PL.solve`), then a Seer rollout for `eval_h` bosses. Candidates are ranked by the share of worlds where the rollout wins, then by mean rollout value (which counts blinds cleared and so ante reached), then by how many worlds proposed it.
5. What is committed to the real state: one action in a blind, at blind select and in packs; in a shop the plan's actions up to and including the first one that reveals something (reroll, open, use, buy and use) or leave. Buys and sells of what is on screen change nothing hidden, so they are not re-planned one by one.

With `run_cap` (CPU seconds per run), a run that goes over the cap keeps playing with one world, which is still fair, so a slow seed cannot blow the CI budget.

### Budgets

| budget | worlds | Seer per world | eval horizon | candidates | blind finish solve |
| --- | --- | --- | --- | --- | --- |
| `lite` | 4 | horizon 1, beam 2, depth 2 | 1 boss | 3 | beam 3, plays 2, discards 3 |
| `std` | 8 | Seer defaults | 2 bosses | 4 | beam 4, plays 2, discards 4 |

`worlds=`, `eval_h=`, `max_cands=` and `seer=key:value,...` override a budget.

### World votes, net proposals and speed

- After a searched decision every world votes for the candidate that scored best in it (wins first, then rollout value). `fo.scores[i]` holds the votes for action `i` of the line; the fair teacher writes them as visit counts, so records are soft targets instead of one-hot. An unsearched decision gives all votes to the one plan.
- `net_propose` (teacher `weights=` and `net_sims=`): when the worlds disagree, the net's MCTS move on world 1 joins the candidates and is evaluated like the others. `net_picks` counts how often it wins. Asking the net on every decision made almost every decision a search, so it is only asked where there is already a choice.
- `fast_top` (lite: 8): in rollouts the fast policy ranks the five-card plays by hand base chips times mult plus card chips and previews only the top N. Measured on BENCH 1-30, 5 decks, white: 129.9 to 66.4 s per game, wins 36 to 39 of 150.
- `quick_clear` (off): play the best visible play when it clears the blind, without worlds. It saved nothing measurable (127.8 s, 35 wins) and stays off.
- The runners load `botsim.jitopt` (bigger LuaJIT trace limits): 1.84x faster with identical games.
- Preview copies (`ST.copy_preview`, on with `ST.PREVIEW_PROXY`) read the RNG through a lookup into the source state instead of copying it; writes stay in the scratch. BENCH 1-30, 5 decks, white: all 150 games identical to the plain copy (39 wins). Old vs new on the same runner (`fair_prof.lua proxy=0|1`, 6 games): 65.0 to 59.5 s per game in one job; the other job measured 63.0 to 92.4 s with every phase slower, including ones previews do not touch, so that runner slowed down mid-job.

### Why it cannot cheat

Every decision goes `real -> F.sanitize -> worlds -> Seer`. After `sanitize` the real state is never read again, and `sanitize` keeps nothing hidden: the RNG and seed are replaced by constants, the unseen pool is sorted. So two real states that differ only in hidden things give the same sanitized view, the same worlds for the same sampler seed, and the same decision. `tools/botsim/seer/test/fair_test.lua` checks exactly that on states from two runs (blind select, shop, play, packs when they come up, plus a synthetic state with face-down cards and face-down jokers): it builds a variant with another seed, other RNG values, a reordered deck, swapped face-down cards and swapped hidden joker order, and asserts the sanitized views are byte identical and that `decide` returns the same actions. It also checks that worlds keep the visible facts, that deciding does not change the real state or its RNG, and that a short fair run is legal and deterministic. It prints how often the cheating Seer changes its move on the same pairs, which shows the variants really matter.

The sampler never uses `math.random` or the clock (only `run_cap` reads the clock, and only to cut the world count).

### Running

```
luajit tools/botsim/seer/test/fair_test.lua            # leak tests (CI only)
luajit tools/botsim/seer/fair.lua budget=lite decks=b_red,b_blue stakes=1 seeds=10 jobs=4 out=fair.jsonl
luajit tools/botsim/seer/fair.lua summary=a.jsonl,b.jsonl
```

Options: `budget=lite|std`, `worlds`, `eval_h`, `max_cands`, `seer=horizon:2,beam:3`, `decks`, `stakes`, `seeds` (count), `first` (first seed number), `prefix` (default `FAIR`, seeds `FAIR0001..`), `sampler` (sampler seed), `run_cap`, `jobs` (worker processes, each writes `<out>.partK` as it goes), `part=k/n`, `out` (JSON lines: deck, stake, seed, won, ante, time, actions, decisions, searched, world_plans, capped, budget, worlds, s_per_decision).

### Cost

Measured on CI runners (2 cores), BENCH 1-30, 5 decks, white, `lite`: 182 s per game before the speed work, 130 s with jitopt, 66 to 91 s with `fast_top=8` (same games, different runners), 83 s with preview proxy on a run where the same games took 91 s before. CI timing noise between runners is about 35%, so compare on one runner. `tools/botsim/seer/fair_prof.lua` breaks the time down by phase and function.

### Not done yet

- Shop plans from one world are applied as a whole line in the other worlds during evaluation; a step that does not apply there (after a reroll shows other cards) just ends the line.
- Worlds sample uniformly from the hidden pool; nothing weights them by what the hidden voucher or boss order would more likely be.
- Seer's per-world plan is still a cheater inside its world (strategy fusion). Classic PIMC weakness: it can prefer lines that only work when you know the future, like discarding into a draw it assumes. Averaging over worlds damps that but does not remove it.

## Not done yet

- The fast policy that plays every rollout is greedy; better rollouts are the biggest lever left (a cheap version of the blind solver, planets and buys inside rollouts).
- Shop search is the cost: a full run is 15 to 60 CPU seconds. Rollout caching across a shop's nodes and a lighter preview copy in the sim would help most.
- Consumables that need targets bought from the shop are not considered (only used from packs or when already held). Selling consumables, The Fool's and Perkeo's tricks, Showman lines, and deliberate deck thinning are not searched.
- Joker order is only searched with Blueprint or Brainstorm.
- Endless (score high after the win) is not a goal yet; Seer stops at the win.
- Hand order by suit is not modelled in the sim, so Seer never relies on it.
