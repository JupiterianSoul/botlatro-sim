# Fair bot: network, search and training format

This is the network and search side of Fair (see `docs/BOTLATRO_PLAN.md`). The sim lives in `assets/bot/sim/`, the brain in `assets/bot/nn/`, training tools here.

## Files

| file | what |
| --- | --- |
| `assets/bot/nn/buf.lua` | number buffers: LuaJIT FFI `double[]`/`int32_t[]` when ffi exists, 0-indexed Lua tables otherwise (`BUF.set_ffi(false)` forces the plain path) |
| `assets/bot/nn/features.lua` | sim state to features (fair view), every legal action of a run (play, discard, blind, shop, pack, consumables) with its features |
| `assets/bot/nn/net.lua` | inference, no allocation per eval |
| `assets/bot/nn/weights.lua` | `.bnnw` weight format: load (LOVE `love.filesystem.read` or `io.open`), save, random init |
| `assets/bot/nn/mcts.lua` | ISMCTS with PUCT, node pool, determinization |
| `tools/botsim/train/selfplay.lua` | plays full runs with the search (every decision), writes `.bspr` records |
| `tools/botsim/train/teacher.lua` | plays runs with the greedy policy (`botsim.policy`, shop on) and writes teacher records through the same writer Seer uses; also the greedy reference for sanity numbers |
| `tools/botsim/train/selfplay_pool.sh` | multi-process driver: one self-play (or teacher) process per core, one rotating set of `.bspr` files per worker |
| `tools/botsim/train/eval.lua`, `evalset.lua` | plays the fixed evaluation set (8 deck x stake cells, fixed seeds) with the greedy policy or a net, one JSON line per cell; `part=i parts=k` splits the cells over processes |
| `tools/botsim/train/gamelog.lua` | JSON lines for `selfplay.lua games=<file>` (one per finished run) and `recs=<file> rec_runs=N` (the first N runs of a process with every move and its top candidates); `{seed}` in the path is replaced by the worker seed |
| `tools/botsim/train/records.lua` | record writer and reader (Lua) |
| `tools/botsim/train/bnn/` | Python: `model.py` (PyTorch mirror), `records.py`, `weights.py` |
| `tools/botsim/train/train.py` | trainer |
| `tools/botsim/train/parity.py`, `parity_lua.lua` | Lua vs PyTorch parity check |
| `tools/botsim/train/bench_nn.lua`, `bench_mcts.lua` | speed numbers (time based) |
| `tools/botsim/train/bench_speed.lua` | fixed-count speed bench with a checksum of the chosen moves, so before/after runs can be compared exactly (`part=parts`, `mcts`, `play`) |
| `tools/botsim/train/bench_quality.lua` | search quality: agreement of cheap searches (adaptive, widening, fewer sims) with an 800-sim reference |
| `tools/botsim/train/benchstates.lua` | the 200 mid-game bench states (greedy runs with 3 jokers) |
| `tools/botsim/train/test/run.lua` | Lua tests |

Run from the repo root:

```
nice -n 19 taskset -c 0-3 luajit tools/botsim/train/test/run.lua
nice -n 19 taskset -c 0-3 luajit tools/botsim/train/bench_nn.lua 1
nice -n 19 taskset -c 0-3 luajit tools/botsim/train/bench_mcts.lua 3 16 64 256 800
nice -n 19 taskset -c 2 luajit tools/botsim/train/bench_speed.lua [part=parts|mcts|play] [adaptive=1 conf=0.9] [E=24 H=96 VH=24] [prof=F]
nice -n 19 taskset -c 2 luajit tools/botsim/train/bench_quality.lua [weights=x.bnnw] [ref=800 sims=16,64,256 cfgs=base,pw,adapt,conf]
nice -n 19 taskset -c 0-3 luajit tools/botsim/train/selfplay.lua runs=100 sims=64 out=tools/botsim/train/out/a.bspr [weights=x.bnnw] [K=24 noise=0.25 temp_moves=8 alpha=0.5 secs=60] [adaptive=1 reuse=1 conf=0.9 conf_frac=0.25 fast_sims=16 full_frac=0.25] [full=1 max_shop=40 first=1]
nice -n 19 taskset -c 0-3 luajit tools/botsim/train/teacher.lua runs=400 eps=0.1 out=tools/botsim/train/out/teach/t1.bspr [shop=1 cut=0 K=24]
tools/botsim/train/selfplay_pool.sh -w 8 -o /data/gen1 -r 100 -k 50 -- weights=gen0.bnnw sims=64 adaptive=1
nice -n 19 taskset -c 0-3 tools/botsim/train/.venv/bin/python tools/botsim/train/train.py --data tools/botsim/train/out --out net.bnnw [--init old.bnnw] [--cfg E=32,H=128,VH=32] [--policy-min-sims 64]
nice -n 19 taskset -c 0-3 tools/botsim/train/.venv/bin/python tools/botsim/train/parity.py
```

The venv (`tools/botsim/train/.venv`, git ignored) holds CPU torch and numpy: `python3 -m venv tools/botsim/train/.venv && tools/botsim/train/.venv/bin/pip install torch numpy --index-url https://download.pytorch.org/whl/cpu`.

## Architecture

```
hand cards  (n x CF=39)  --Linear+ReLU--> E --+-- sum, max --+
jokers      (m x JF=166) --Linear+ReLU--> E --+-- sum, max --+--> concat with global (GF=333)
items       (k x IF=351) --Linear+ReLU--> E --+-- sum, max --+
                                                            |
                              trunk: Linear(GF+6E, H)+ReLU, Linear(H, H)+ReLU = q
value:  Linear(H, VH)+ReLU, Linear(VH, 2) -> [win logit, expected final ante / 8]
policy: per action type t: u_t = Linear_t(q)   (size 2E + FA)
        logit(a) = sum over selected hand cards i of u_t[:E] . e_i
                 + u_t[E:2E] . x_a        (x_a = embedding of the item or joker the action acts on, if any)
                 + u_t[2E:] . fa(a)
```

Default size: E=32, H=128, VH=32, 17 action types, **323,029 weights** (1.3 MB as float32). Most of the growth is the 17 policy heads (H x (2E+FA) each); the trunk and encoders are about 110k.

Items are everything that is not a hand card or a joker: shop cards (jokers, consumables, playing cards), shop vouchers, shop boosters, the open pack's cards, held consumables and held tags. One shared encoder with an area one-hot keeps it to one more set block.

Why this shape:

- **Deep sets for entities.** Hand cards and jokers are sets of varying size. A shared encoder plus sum and max pooling handles any count, and new entity types (consumables, shop items, pack cards) are one more encoder and two more pooled blocks.
- **Factorized action scoring.** Balatro's action space changes every step (218 play subsets plus 218 discard subsets with 8 cards, more with a bigger hand, and shop actions later). Scoring each action through an MLP would cost most of the eval. Here the logit is linear in the action's features with weights produced by the trunk (`u_t`), so per state the net computes `u_t` once and one dot product per hand card; each action then costs a sum of at most 5 numbers plus a sparse dot with ~6 nonzero action features. 436 actions cost about 10 us on top of the forward pass. The nonlinear part (which card combinations matter) comes from the action features: the poker hand the selection makes, a joker-free score estimate against the blind, scoring card count. Play and discard have separate `u_t`, so a card can be good to play and bad to discard.
- **Sparse-aware dense layers.** Weights are stored input-major (`[in][out]`) and inputs that are zero are skipped. Most inputs are one-hots (rank, suit, joker id, blind, boss, deck, stake, tags, vouchers), so the 320-wide global vector and the 166-wide joker vector cost only their ~86 and ~13 nonzero rows. The layer first gathers the nonzero rows, then adds 8 (then 4, then 1) rows per pass over the outputs, so each output is loaded and stored once per 8 rows. The additions happen in the same order as the plain loop, so results are bit identical.
- **Delta forward in the search.** Inside one search the global features barely change (deck, stake, levels, vouchers, tags stay put; chips, hands, pool counts move). The root stores `b + W_g^T g_root` for the first trunk layer (`net:set_base`), and leaves only add `(g - g_root)` rows for the entries that differ (`net:forward_delta`). Not bit identical to `forward` (different summation order, about 1e-15), tested to 1e-9; the bench checksums did not move. `forward` stays the reference used by parity.
- **Value with an auxiliary.** Early on almost no run wins, so the win head alone has no signal. The second head predicts the final ante (won runs count as `win_ante + 1`). The search uses `(1 - alpha) * p_win + alpha * ante_hat * 8 / (win_ante + 1)`, `alpha` = 0.5 by default; lower it once wins are common. With `mix=m` (selfplay/eval argument, `TRAIN_VALUE_MIX`, 0.8 in training runs since round 3) the leaf value is `(1 - m) * p_win + m * clamp((ante_hat * 8 - 1) / win_ante)` and a game over is worth `m * (ante - 1) / win_ante`, so dying in ante 1 is 0 and every ante reached counts. Round 2 showed the win head stuck near 0%, which left the old formula with almost no signal. The net and its outputs are unchanged, so the Lua/PyTorch parity test is unaffected.

### Speed (this laptop, one core, `nice -n 19 taskset -c 2`, LuaJIT 2.1)

`bench_speed.lua part=parts`, random E32/H128 weights, the 200 bench states (452 actions on average):

| | before (aafd883) | now |
| --- | --- | --- |
| `features.actions` (full 23-wide action features) | 100 us | 38 us |
| `features.actions_compact` (what the search uses) | | 25 us |
| forward (batch 1) | 26 us | 18 us |
| forward + policy over 436 actions | 41 us | 32 us |
| `features.state` | 1.2 us | 1.2 us |

The fast action listing precomputes per hand card its rank bit, a packed 3-bit-per-suit flush count (wild, smeared and stone handled once per card), chips, mult and high-card order; per subset it counts equal-rank pairs (the pair count fixes the hand shape and the scoring set for every rank hand), reads straights from a 8192-entry table keyed by the rank bitmask, and keeps the play and discard rows of the same subset in one pass. It writes compact rows (hand type, scoring count, estimate, clears, debuffed, flipped); `net:policy_compact` reads them directly and the full 23-wide row is only built for the root edges and for records. A test checks it against the old evaluator (`features.actions_ref`) on 600 adversarial hands (random ranks, suits, enhancements, debuffs, face-down, forced cards, Four Fingers, Shortcut, Smeared, Splash): every action feature is equal.

Net size (`bench_speed.lua E=.. H=..`, search decisions/s): E24/H96 is 1.17x faster than E32/H128 at 256 simulations and the same at 64, because the net is now about half of a simulation. That is not worth 41% fewer weights, so E32/H128 stays the default. Float32 weight arrays instead of double were measured: no gain (the 400 KB of weights fit in cache), so they stay double. E16/H64 is still an option for the phone.

## Features (fair view)

`features.lua` reads only what a player sees:

- Never reads the order of `s.deck` or any `s.rng` slot or `hashed_seed`. The remaining deck enters as composition counts (rank, suit, enhancement) of the **unseen pool**: the deck plus face-down hand cards. A test shuffles the deck, rewrites every RNG stream and swaps a face-down hand card with a deck card, and checks the features do not change.
- Face-down hand cards (`c_flip`, The House, Wheel, Mark, Fish) show only a "flipped" flag; face-down jokers (Amber Acorn) show only their slot. Action features ignore face-down cards when they evaluate the poker hand.
- Global (GF=333): phase (blind select, play, round eval, shop, game over, pack, win), ante, round, current blind and next boss (one-hot over 30), blind on deck, blind chips, chips scored, ratio, chips needed, hands, discards, last hand flag, hand size, slots, money, deck (16), stake (12, room for the overhaul stakes), all 12 hand levels (level, chips, mult, times played), unseen pool counts, flipped count, discard pile size, both skip tags, shop voucher, used vouchers, boss reroll, skips, interest cap, discount, inflation, probability multiplier (Oops), win ante, pending consumables, blind disabled, no interest, open pack kind and picks left, reroll cost, free rerolls, first shop buffoon flag, tags held, money above the bankrupt line, bias.
- The ante's voucher is hidden until the player has seen it (`features.voucher_hidden`): before the first shop of the run and in the round eval after a boss (the sim rolls the next voucher at the end of the boss round). Boss, skip tags and the next ante's blinds stay visible because the game shows them (blind select, run info).
- Card (CF=39): rank, suit, enhancement, edition, seal (one-hots), debuffed, flipped, forced (Cerulean Bell), permanent bonus chips, nominal chips, played this ante (The Pillar).
- Joker (JF=166): joker id one-hot (150), edition, debuffed, eternal, perishable rounds, rental, sell value, the joker's visible counters (`j_mult`, `j_x`, `j_ex`, `j_n`, hands since added), slot position, flipped.
- Item (IF=351): area (shop card, voucher, booster, pack card, held consumable, tag), id one-hots for jokers (150), consumables (52), vouchers (32), boosters (32) and tags (24), playing card rank, suit, enhancement, edition, seal (shop and pack playing cards), stickers, cost, affordable, sell value (held consumables), "usable without targets", number of targets the consumable takes, position, orbital tag hand, bias. At most `MAXI` = 40 items; past that an item still gets its actions but no embedding.
- Action (FA=35): cards selected (one-hot 1..5, also the target count of a consumable), poker hand of the selection (play only), scoring card count, `log(estimate) / log(chips needed)` where the estimate is hand chips plus card chips times hand mult without jokers, "estimate clears the blind", debuffed and face-down cards in the selection, bias, then for shop actions: cost (negative for sells), money after, interest lost or gained, target slot one-hot and shift for joker moves.

### Action types

| id | type | sim action | acts on | when |
| --- | --- | --- | --- | --- |
| 1, 2 | play, discard | `play`, `discard` | hand cards | play |
| 3 | select | `select` | | blind select |
| 4 | skip | `skip` (takes the tag) | | blind select, small and big only |
| 5 | reroll_boss | `reroll_boss` | | blind select, Director's Cut or Retcon and $10 |
| 6 | buy | `buy` | shop item | shop, affordable and a free slot |
| 7 | buy_use | `buy_and_use` | shop item | shop, consumables that need no targets |
| 8 | sell_joker | `sell` jokers | joker | play, shop, not eternal |
| 9 | sell_cons | `sell` consumables | held consumable | play, shop |
| 10 | use | `use` with targets | held consumable + hand cards | play (targets) and shop (no targets), whatever `E.can_use_cons` allows |
| 11 | redeem | `redeem` | shop voucher | shop |
| 12 | open | `open` | shop booster | shop |
| 13 | reroll | `reroll` | | shop |
| 14 | leave | `leave` | | shop |
| 15 | pick | `pick` with targets | pack card (+ hand cards for Arcana and Spectral) | pack |
| 16 | skip_pack | `skip` | | pack |
| 17 | move_joker | `reorder_jokers` | joker | shop: joker i moves to slot j, `(n-1)^2` distinct moves; in a blind only the moves where order matters (see below) |

Cash out is forced (one legal action), so it is applied automatically (`MC.advance_forced`) and never recorded. Consumables with targets list every hand subset of the allowed sizes (`min_highlighted..max_highlighted`, Aura exactly 1), checked with the sim's own `E.can_use_cons`. A test drives 60 runs (greedy play, random econ choices, extra money and consumables to reach every branch) and steps a copy of the state with every listed econ action: every one is legal and every type shows up. In a blind the play node only gets the joker moves that can change a score: each x-mult joker (34 vanilla keys in `XMULT_KEYS`) or polychrome joker to the far right, Blueprint next to each other joker, and any joker to the far left when Brainstorm is owned. That is at most about 3 per joker instead of `(n-1)^2`, and nothing at all when no such joker is owned. Search speed is unchanged (214.6 and 83.8 decisions/s at 64 and 256 sims on the play bench). Selling jokers and consumables in a blind was already listed (Luchador, Diet Cola, Invisible Joker and the rest).

Numbers go through `slog(x) = sign(x) * log(1 + |x|)` and fixed scales so they stay near [-3, 3].

### Still not in the features

- Joker stickers by stake are in (eternal, perishable, rental); `first_shop_buffoon` is a flag. Challenge rules and the curriculum's random rule changes are not features yet (global flags when the curriculum starts).
- Hidden joker internals the game shows on the card (Idol card, Mail-In rank, Ancient suit, Castle suit) are not features yet; the net only sees the joker id.
- Hand sort by suit, if the sim adds it.

## Search (`mcts.lua`)

- **Information set MCTS, one determinization per simulation.** Each simulation copies the root into a reused scratch state (`copy_into`), shuffles the unseen pool (deck plus face-down hand cards) with a private Park-Miller RNG, and replaces every RNG stream slot the state has registered and `hashed_seed` with private random numbers, so future shuffles, boss rolls, Lucky cards and the rest come from a sampled world, never the run's real seed. The slots are filled from a per-simulation Park-Miller stream seeded by one draw. Only the root's registered slots (`rng_ids`, a few hundred) are filled, not every key the sim ever registered (4,400 after a few runs): filling all of them was 40% of a simulation. A key the root has not registered is seeded from the private seed string below and the random `hashed_seed`, so it is just as private, and the search no longer shifts when another run registers new keys. The scratch state also gets one of 64 private seed strings (`ISMCTS1..64`) and their hash caches: a key the sim registers for the first time in the middle of a simulation (a new ante's boss, a new pack) used to fall back to the real seed's hash, which leaked the real future into the search and made search results depend on what earlier searches had registered. A test checks the search output does not change when the real seed, hash cache, `hashed_seed` and RNG slots change, on play, shop, pack and blind select roots. Hidden shop information needs nothing extra: shop slots, rerolls, pack contents, the next boss after a reroll and the next tags are all rolled from RNG streams at the moment they appear, so a sampled world rolls them from private numbers. The one rolled-ahead value is the ante's voucher: when it is hidden (see features) the determinization redraws it with the sim's own `get_next_voucher` from the private streams. A test checks the redraw happens and that determinizing a shop keeps every visible thing (shop items, jokers, consumables, tags, money, boss, voucher once seen). `math.random` is not used by the search (the sim reseeds it for every seeded call anyway).
- **Scratch deck tail.** `copy_into` copies `deck[1..n_deck]` and leaves older entries behind it, and the sim's end of round puts cards back with `table.insert(s.deck, 1, cid)`, which shifts everything up to `#deck`. In the reused scratch state that tail grew by about 40 entries per simulated round end and never shrank, so a self-play process got slower the longer it ran (72% of the time in that one line after a few minutes; 4.6 decisions/s at 256 sims after 150 runs). The search now clears the stale tail after each copy. Same results, 8x to 28x faster self-play. The real fix belongs in the sim (see TODOs).
- **Tree over observations.** An edge is an action (type, card positions, item or joker position, target slot). Its children are keyed by a hash of what the player sees after it (hand ids in order, face-down cards only as "face-down", chips, money, hands, discards, ante, round, phase; in full mode also the hand cards' rank, suit, enhancement, edition and seal, jokers, consumables, shop, vouchers, boosters, pack contents, tags, blind on deck, boss, reroll cost and hand levels, so a reroll or a pack opening gives different nodes per outcome), so different draws give different nodes, and the same draw seen twice shares a node. A node is a real information set.
- **PUCT** with the policy priors, `c_puct` = 1.5, first-play urgency = the node's own value. Root Dirichlet noise (`noise`, `dir_alpha` 0.3) for self-play.
- **Top-K edges.** At expansion all legal actions are scored, the K best by prior (default 24) become edges and their priors are renormalized. That keeps the node pool small and the records short.
- **Lazy expansion.** A new leaf only gets the forward pass (value). Actions and policy are computed when a simulation passes through it again. Most leaves are fresh draws that are never revisited, so this halves the cost per simulation.
- **Tree reuse.** `mc:commit(e)` before stepping the real state with edge `e`; the next `search` looks for the child of `e` whose key matches the new real state and keeps that subtree. The pools are compacted in place (nodes in id order, edge blocks in position order, child and sibling links remapped), the root gets its features and root action features rebuilt, and only `n_sims` minus the visits it already has are run. A test checks a reused subtree is copied exactly. In practice it rarely fires (1.2% of moves at 256 sims): almost every action draws cards, and the real draw is one of thousands, so the matching child seldom exists. Kept because it is cheap and exact, and it will matter for shop and blind decisions that draw nothing.
- **Adaptive simulations** (`adaptive = true`, on in self-play for moves played at temperature 0): a move with one legal action costs no simulation; the search stops as soon as the most visited root edge leads the second by more than the simulations left (it cannot be overtaken, so the chosen move is exactly the full search's move); optional `conf_prior` (e.g. 0.9) cuts the budget to `conf_frac` (0.25) when the clean top prior is that confident; optional `extend` gives close decisions up to `extend` x the budget (measured: no gain, off).
- **Progressive widening** (`pw_c`, `pw_a`, `pw_min` in `MC.new`, off by default): a node only considers its `max(pw_min, pw_c * (N+1)^pw_a)` best-prior edges; root edges are re-sorted after the noise. Measured: no quality gain and agreement with the unpruned search drops to 90 to 95%, so it stays off. PUCT already starves low-prior edges at these budgets.
- **Playout cap randomization** (`selfplay.lua fast_sims=16 full_frac=0.25`): a quarter of the temperature-0 moves get the full search with noise, the rest a fast search without noise. Every record stores the budget it got (`n_sims`, the confident-prior budget when that rule fired), and `train.py --policy-min-sims N` trains the policy only on records with at least N, while every record still trains the value heads.
- **Every decision in the search** (`MC.new(net, {full = true})`, the default): blind select, shop and pack nodes are expanded like play nodes, with the econ listing (`features.econ_actions`) appended to the play listing in play nodes (sells, consumables). Only cash out is applied automatically. `full = false` keeps the old fixed policy outside play (`MC.advance`: select every blind, cash out, leave the shop); the play-only benches use it so their numbers stay comparable. A root with a single legal action now never runs simulations, adaptive or not.
- Preallocated pools: node and edge arrays (FFI when available), sized for `2 * n_sims + 2` nodes and K edges per node, grown only when a bigger search is asked.
- Terminal values: won = 1, game over = `alpha * ante / (win_ante + 1)` (or `mix * (ante - 1) / win_ante`).
- **Score prior** (`score_prior=w score_top=n score_temp=4`): round 2 lost 34% of games in ante 1 round 1 playing high cards, the play priors were flat and 64 sims cannot cover the card combinations. In the play phase the prior becomes `(1 - w) * net + w * q`, `q` a softmax (temperature 4) over plays of `log(score + 1) / log(remaining + 1)` capped at 1.5. The score is the cheap per-action estimate at every node; at the root the `n` best plays by that estimate are scored exactly with `E.preview_into` (jokers included) and always kept among the K candidates. Plays that include a face-down card keep the estimate, so nothing hidden leaks.
- **Skip penalty** (`skip_pen=0.2 skip_ante=1`): the skip prior is multiplied by the penalty up to that ante and the priors renormalised. Search can still pick a skip when it is clearly better.
- **Curriculum** (`start_ante=3-4 start_frac=0.5 start_who=greedy|net start_sims=16`): a deterministic share of runs (hash of run index and seed) is played by `botsim.policy` (or the net at `start_sims`) up to the target ante with nothing recorded, then self-play records from there. The sim needs no state loading for this, so it is exact. Runs that die in the prefix are not written and not counted; the printed avg ante and game logs of curriculum runs start high, so read the eval set, not self-play stats, for strength.

### Full runs (2026-10-25)

Measured on this laptop with other jobs running (`nice -n 19 taskset -c 6`), so compare columns of the same table only. "base" is `b07862e` (play-only Fair), "now" this branch.

Play path, `bench_speed.lua part=mcts`, random E32/H128 weights, same 200 mid-game states, `full=0`:

| n_sims | base decisions/s | now, before the RNG slot change | now |
| --- | --- | --- | --- |
| 16 | 505 | | 573 |
| 64 | 167 | 149 | 219 |
| 256 | 50.7 | 46.8 | 78.7 |

The bigger net (item block, 2E+FA policy heads, 12 more action features) cost 8 to 12% per decision; filling only the registered RNG slots in the determinization more than paid for it. With `full=1` (shop and blind nodes inside the simulations) the same bench gives 523 / 219 / 87. In isolation (`forward` then `policy` on one 436-action state) the generic policy went from 19 to 27 us and the compact one the search uses from 6.3 to 9.4 us; play nodes only query the entity columns of `u_t` for types that act on an entity, so play and discard pay for E + FA columns, not 2E + FA.

Self-play over full runs, 50 runs, same seeds (`seed=11`):

| net | n_sims | config | decisions/s | decisions per run | mean final ante | wins |
| --- | --- | --- | --- | --- | --- | --- |
| random weights | 64 | adaptive | 307 | 7 | 1.00 | 0 |
| greedy-teacher net (below) | 64 | adaptive | 240 | 35 | 2.20 | 0 |
| greedy-teacher net | 64 | adaptive + `conf=0.9` + `fast_sims=16 full_frac=0.25` | 396 | 46 | 2.70 | 0 |
| greedy-teacher net | 256 | adaptive (40 runs) | 95 | 46 | 2.70 | 0 |

Sanity reference on the same 50 seeds: the greedy policy with its shop logic (`teacher.lua`, buys affordable jokers, opens Buffoon and Celestial packs) reaches ante 3.52 with no wins (1 win in 20 on another seed set); the greedy policy that always leaves the shop reaches 1.68. Fair with random weights dies in the first blind almost every time (1.00), as expected.

The greedy-teacher net: 400 teacher runs with `eps=0.1` (24k records, every decision type), `train.py` for 1500 steps on 4 threads (policy loss 0.57, about 10k samples/s). It is a stand-in to exercise the full pipeline, not a generation; it already plays shops, packs and consumables (in the 64-sim run above: 155 buys, 88 packs opened, 75 picks, 4 joker sells, 2 consumable sells, 2 rerolls, 1 joker move).

### Search speed before the full-run work (one core, random E32/H128 weights, `bench_speed.lua part=mcts`, same 200 mid-game states, noise 0.25)

| n_sims | decisions/s before (aafd883) | decisions/s now | sims/s before | sims/s now |
| --- | --- | --- | --- | --- |
| 16 | 854 | 1205 | 13.7k | 19.3k |
| 64 | 328 | 478 | 21.0k | 30.6k |
| 256 | 97 | 158 | 24.8k | 40.3k |
| 800 | 36 | 56 | 28.5k | 45.0k |

About 25 us per simulation at 256: the net is half of it (dense layers), then features, the sim step, copy and determinize. With adaptive simulations and random weights the average falls only to 15.9 / 63.1 / 249 / 772 sims (random priors are flat and the root noise flattens them more); with a net that has learnt something it falls much more (below).

Self-play (`selfplay.lua`, 150 runs, teacher net described below, runs reach ante 1.45 on average, about 17 decisions per run):

| n_sims | before (aafd883) | now | now, adaptive (default) | now, adaptive + `conf=0.9` + `fast_sims=n/4 full_frac=0.25` |
| --- | --- | --- | --- | --- |
| 64 | 71 decisions/s | 596 | 657 | 853 |
| 256 | 4.6 decisions/s | 128 | 154 | 191 |

The "before" column is mostly the scratch deck tail; it gets worse the longer a process runs.

### Search quality checks (`bench_quality.lua`)

Agreement of the chosen move (temperature 0, no noise, each state reseeded) with an unpruned 800-sim reference and with the unpruned search at the same budget, 200 mid-game states. Two nets: random weights, and a "teacher" net trained for 4000 steps on 107k records of the greedy policy (`botsim.policy`, one-hot on its move among 24 edges, value targets from the greedy runs' outcomes; plays ante 1.67 in self-play at 64 sims against 1.0 for random weights). The teacher net is a stand-in until a real generation exists: its prior is very sharp, so even 16 sims match the reference 99% of the time.

| net | config | budget | avg sims | agree with 800-sim ref | agree with unpruned, same budget |
| --- | --- | --- | --- | --- | --- |
| teacher | base | 16 / 64 / 256 | 16 / 64 / 256 | 99.0 / 99.0 / 98.0% | 100% |
| teacher | adaptive | 16 / 64 / 256 | 13.9 / 49.6 / 193.8 | 99.0 / 99.0 / 98.0% | 100% |
| teacher | adaptive + conf 0.9 | 16 / 64 / 256 | 12.3 / 44.9 / 174.9 | 99.0 / 99.0 / 98.0% | 100% |
| teacher | widening (pw 2, 0.5, min 4) | 16 / 64 / 256 | full | 98.5 / 98.5 / 98.5% | 99.5% |
| random | base | 16 / 64 / 256 | full | 74.0 / 75.5 / 81.5% | 100% |
| random | adaptive | 16 / 64 / 256 | 15.8 / 61.7 / 243.4 | 74.0 / 75.5 / 81.5% | 100% |
| random | widening | 16 / 64 / 256 | full | 75.0 / 76.5 / 79.5% | 94.5 / 93.0 / 90.0% |

Two reference runs with different seeds agree 99.0% (teacher) and 87.0% (random), and two same-budget unpruned runs 93 to 100%, so differences below that are noise. Adaptive search saves 13 to 32% of the simulations with a sharp prior and changes no decision; the confident-prior rule changed no decision here either. Rerun this with the first real generation before trusting `conf` for training targets.

## Training compute estimate

A full winning run is 8 antes x 3 blinds = 24 blinds. The greedy reference plays 3.74 play-phase decisions per blind, so a full run is about 90 play decisions (call it 100 with more discards). Laptop core-hours per 1M games of 100 decisions:

| n_sims | before, mid-game bench | now, mid-game bench | before, self-play | now, self-play adaptive | now, self-play adaptive + conf + cap |
| --- | --- | --- | --- | --- | --- |
| 64 | ~85 | ~58 | ~390 (and growing) | ~42 | ~33 |
| 256 | ~290 | ~176 | ~6,000 | ~180 | ~146 |
| 800 | ~780 | ~490 | | | |

The mid-game bench uses random weights and mid-game states; the self-play numbers use early-game states (rounds end often inside a simulation) and a net with a sharp prior, so adaptive search saves more there. Expect a real run between the two columns. Shop, pack and blind decisions (milestone 2) will add decisions per run and their own enumeration; budget about 2x until measured. Runs that die early are much cheaper, and early generations die early.

Network training is small next to that: the trainer does about 27k samples/s on 4 laptop threads at E32/H128, so one pass over 1M games (90M samples) is about 1 hour on 4 threads.

Money: core-hours x the box price per vCPU-hour. Hetzner dedicated vCPUs are hyperthreads, so assume roughly 0.6 to 0.8 of a laptop core each until a box is measured. At about 0.012 EUR per dedicated vCPU-hour (check the real CCX price in the cloud tool), 1M games at 64 sims is roughly 42 / 0.7 x 0.012 = about 0.7 EUR (1 EUR with the mid-game number), at 256 sims about 3 EUR. So the 100 EUR cap buys on the order of 100 million games at 64 sims and about 30 million at 256, before milestone 2 doubles the decisions.

## Weight format `.bnnw` (version 2, little endian)

Version 2 (this branch) adds the item encoder (`enc.item.w/b`, `IF` in the cfg), widens `trunk.0.w` to `GF + 6E` rows and the policy heads to `2E + FA` columns, and carries all 17 action types in `types`. Version 1 files are refused (`unsupported weight version`), and a net whose `types` do not match `features.TYPES` in order fails in `NET.new`.

```
"BNNW"  u32 version  u32 cfg_len  cfg (text "k=v;k=v", sorted keys: CF E FA GF H IF JF VH types)
u32 n_tensors
per tensor: u8 name_len, name, u8 ndim, u32 dims[ndim]
then every tensor's data as float32, in the same order
```

Linear weights are stored `[in][out]` (PyTorch's `weight.T`). Tensor order and shapes are fixed by `weights.shapes(cfg)` (Lua) and `bnn/weights.py:shapes` (Python). Loading checks every expected tensor is present with the right size.

## Self-play record format `.bspr` (version 2, little endian)

```
file:   "BSPR" u32 version(2) u32 GF u32 CF u32 JF u32 IF u32 FA u32 MAXSEL(5) u16 types_len, types (text "play,discard,...")
run:    "RUN2" u32 n_records u8 won u8 final_ante u8 deck_idx u8 stake u32 run_index, then n_records records
record: u8 n_cards u8 n_jokers u8 n_items u8 phase (features.PHASES) u16 n_actions u16 chosen
        f32 root_q f32 net_value u32 n_sims
        vec global, n_cards x vec card, n_jokers x vec joker, n_items x vec item
        n_actions x action
action: u8 type (index into types, from 1) u8 n_sel u8 sel[5] (hand positions from 0, 255 unused)
        u8 ent (item index for item types, joker index for sell_joker and move_joker, 255 none)
        u32 visits f32 prior vec fa
vec:    u16 nnz, u16 index[nnz], f32 value[nnz]     (sparse, the vectors are mostly zeros)
```

Version 2 adds items, the entity byte (it was padding), the phase and the types list, and widens the action count to u16 so a teacher can write every legal action. The Python reader maps the entity byte to an item or joker one-hot from the type name, so the record stays self-describing.

`deck_idx` is the 1-based index into the sorted deck keys (`features.DECK_KEYS`). `final_ante` counts a won run as `win_ante + 1`. Outcomes are known only at the end of a run, so a run's records are buffered and written as one block. The actions are the root's top-K edges, so the policy target is the visit distribution over those K and the trainer's softmax runs over the same K (the pruned actions had low prior; that bias is accepted for size). About 1.5 KB per decision; a full run is now 30 to 50 decisions with a weak net and will be 150+ with a good one (about 250 KB): keep a sliding window on the box, not every game.

### Seer pool mixing

Fair self-play almost never wins, so its value head sees almost no wins. The train job can keep a persistent pool of Seer games (solve mode, about 90% wins at white stake) and draw a fixed share of every batch from it (`train.py --mix-data <pool files> --mix 0.3 --mix-smooth 0.05`; with no `--data` the pool is the whole data set, which is the pool-only pretrain). Inputs are Fair's own features of the real state (`features.state` and `features.list_actions`, the fair view the self-play tests check: no deck order, RNG, seed or hidden voucher), so nothing Seer knows leaks into the inputs. The policy target is Seer's move (one-hot, smoothed over the listed actions), the value and ante targets are the real outcome of Seer's line. Seer moves Fair cannot express are dropped and counted (`unmatched_<phase>`); forced steps are dropped too. Pool games run on every box next to self-play (`TRAIN_SEER_GAMES` per generation) and are never removed by the replay window; the newest `TRAIN_SEER_POOL_MB` are read.

### Writing records from another brain (Seer, greedy, anything)

`records.lua` has one writer for any decision type that does not need the search:

```lua
local FE, REC = require("bot.nn.features"), require("botsim.train.records")
local F, AB = FE.new_state_buf(), FE.new_action_buf(1024)
fh:write(REC.file_header())                              -- once per file
-- at each decision (after MC.advance_forced(s), so cash out is never a decision):
FE.state(s, F)
local n = FE.list_actions(s, AB, F)                      -- every legal action, rows 0..n-1
local k = FE.find_action(AB, my_sim_action, s)           -- row of the move you chose (a sim action table), -1 if not listed
local picks = {{k = k, visits = 1, prior = 1}, {k = other, visits = 0}, ...}  -- any subset of rows, chosen one first
recs[#recs + 1] = REC.encode_choice(F, AB, picks, {chosen = 1, phase = FE.PHASES[s.phase], n_sims = 1, root_q = q})
-- at the end of the run:
fh:write(REC.encode_run(recs, won, final_ante, FE.DECK_IDX[deck], stake, run_index))
```

`visits` can be Seer's own search counts instead of a one-hot; the trainer normalizes them. `FE.to_step(AB, k, out, s)` turns a row back into a sim action. `teacher.lua` is a complete example (greedy policy, chosen move plus up to K-1 random other legal moves with 0 visits). `n_sims` is what `--policy-min-sims` filters on, so a teacher that should always train the policy can write a large number there.

Trainer losses: cross entropy against visit counts, binary cross entropy on `won`, MSE on `final_ante / 8` (weight `--ante-weight`, default 1), AdamW with cosine decay and grad clipping. `train.py` takes the dims and the type list from the record header and refuses to mix files with different ones.

## Self-play on many cores (`selfplay_pool.sh`)

```
tools/botsim/train/selfplay_pool.sh -w 8 -o /data/gen1 -r 100 -k 50 -c 0 -- weights=gen0.bnnw sims=64 adaptive=1 conf=0.9 fast_sims=16 full_frac=0.25
tools/botsim/train/selfplay_pool.sh -t 1 -w 8 -o /data/teach -r 200 -- eps=0.1      # greedy teacher records instead
```

One `selfplay.lua` (or `teacher.lua`) process per worker, `nice -n 19`, worker i pinned to cpu `c + i` (`-c -1` to not pin). Each process plays `-r` runs into `.w<i>_<n>.part` and renames it to `w<i>_<n>.bspr` when done, so the trainer never reads half a file. A worker keeps its newest `-k` files and deletes older ones (sliding window per worker; `train.py --data dir` reads whatever is there, oldest first by mtime). `-n 0` (default) runs until SIGINT or SIGTERM, which stops every worker and removes the partial files; a restart continues the file numbering. Seeds: worker i uses `seed=1000*s+i` and run indices `n*r+1...`, so every run has a distinct seed; with random weights each worker also gets its own random net, so pass `weights=` for real data. Each worker logs its summary lines to `w<i>.log`.

## Checks done

- Lua tests (`test/run.lua`, 40 checks): every listed econ action of every type is legal in the sim (60 driven runs, all 15 non-play types seen); on shop, pack and blind select roots: the search leaves the real state untouched (full snapshot), root visits sum to n_sims, the record roundtrips with items and entities, the chosen edge is a legal sim action, the search does not depend on the real seed, hash cache or RNG streams; shop features ignore deck order, RNG streams and the seed; determinization keeps everything visible in a shop; the voucher is hidden before the first shop and redrawn by the determinization; the teacher writer (`encode_choice`) roundtrips and `find_action` finds a row. From before: pure Lua float32 encoding matches FFI floats, weight roundtrip on both paths, FFI and plain nets agree to 1e-12, play and discard counts, fair view (deck order, RNG streams, face-down card identity), the search never touches the real state, visit counts sum to n_sims, determinization only permutes unseen cards, record roundtrip, forced card in every action, fast action listing equals the reference evaluator on 600 adversarial hands, subtree reuse copies the subtree exactly, the search does not depend on the real seed or RNG state, delta forward matches the full forward.
- Exactness of the speed work: `bench_speed.lua` prints a checksum of every chosen move and its visit count. The fast action listing, the blocked dense layers and the delta forward left it unchanged; the observation key and private-seed fixes changed it on purpose.
- Parity (`parity.py`): random PyTorch weights (scaled x3) exported to `.bnnw`, Lua evaluates the inputs stored in self-play records plus teacher records (`eps=0.3`, Director's Cut given so boss rerolls happen), which cover all 17 action types. Lua FFI and plain vs PyTorch float64: max abs diff 3.2e-14. Against PyTorch float32: max relative diff 8.2e-6 (float32 rounding).
- End to end: teacher records for every decision type, `train.py` for 1500 steps, the trained `.bnnw` loads back into full-run self-play and plays every decision type (numbers above).

## Open TODOs

1. Done on this branch: every decision of a run is in the features, the listing, the search and the records. Left: at most 40 items get an embedding, challenge and curriculum rule flags, the joker internals listed under features, and `endless` (a won run ends). Rerun `bench_quality.lua` style agreement checks on shop and pack states once there is a real generation.
2. Teacher start: `teacher.lua` writes greedy records for every decision type through `REC.encode_choice`, the same call Seer should use (see "Writing records from another brain"). Seer records replace it when they exist.
3. Sim-side speed, for whoever owns `assets/bot/sim/` (measured from the search, `luajit -jp` and `-jv`):
   - `end_round` and two other places put cards back with `table.insert(s.deck, 1, cid)` in a loop: quadratic, and not compiled (`stitch table.insert`). One shift by `n` then a copy is linear. `copy_into` should also clear `deck`, `hand` and `disc` past their counts so `#` is right for anyone using a scratch state.
   - `rng.seed_by_id` formats every random number through `string.format("%.13f")` and `tonumber` (allocates a string per call) and `math.randomseed` is stitched, not compiled; together a few % of a simulation.
   - `engine.lua:789` creates a closure per call (`NYI: FNEW`), which aborts the trace there.
   - RNG keys are registered lazily, so a new key in the middle of a simulation used the real seed; the search now hides that with private seeds, but registering all keys up front (or keying the hash cache per state copy) would make it impossible by construction.
4. The policy target with adaptive search: the early stop leaves the best move with fewer visits than a full search, so targets are a bit flatter. If that hurts, record only full searches for the policy (`--policy-min-sims`).
5. Done: `selfplay_pool.sh` (one process per core, one rotating set of `.bspr` per worker). Batching on the box is still not needed.
6. Quantization for the phone: float32 weight arrays gave no speed on the laptop; only worth it for memory.
7. Tune `c_puct`, `K`, `alpha`, noise, temperature moves, `conf`, `fast_sims`/`full_frac` once there is a trained net to measure win rate with. Rerun `bench_quality.lua` with each new generation.

## Learning per game (after round r20261025-191112)

- Generations are ranked by average ante on a 120 game set (15 decks, trained stakes, 4 seeds), with a 95% interval from `ante_sq`. Wins stay the tie break until they are common enough to rank on.
- `train.py` holds out one run in 20. Held-out losses before (`val0_*`) and after (`val_*`) training tell whether `TRAIN_STEPS` is too many for the window (train loss falls, held-out rises) or too few (both still falling). `TRAIN_EPOCHS` sizes the steps to the window instead of a fixed count.
- Value target: unchanged. The search already blends the win head with the ante head (`alpha` 0.5), so a run that dies at ante 5 is scored above one that dies at ante 2 even with no wins in the data. The calibration numbers (`val_win_pred` against `val_win_true`, `val_ante_mae`) show whether either head is worth trusting.
- Policy target with adaptive search (TODO 4): the job already trains the policy only on searches with at least `SIMS / 2` simulations (`--policy-min-sims`), so the fast searches only feed the value heads.
- Not done yet: the missing inputs (challenge rule flags, joker internals like The Idol's card, items past the first 40). Each needs a format bump with exact Lua and PyTorch parity, so they wait until the held-out numbers say the net is limited by its inputs rather than by data.
