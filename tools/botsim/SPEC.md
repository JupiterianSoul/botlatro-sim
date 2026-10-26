# botsim shared formats

The sim (`assets/bot/sim/`) and the real-game recorder (`tools/botsim/diff/`) both speak these formats, so an action log played in one can be replayed in the other and the snapshots compared line by line.

## Run setup

```json
{"seed": "ABCD1234", "deck": "b_red", "stake": 1, "challenge": null}
```

`seed` is the game's 8-character seed string. `deck` is a center key, `stake` 1 to 8, `challenge` a challenge id or null.

## Actions

Same types as `B.legal` in `assets/functions/bot_bridge.lua`, but cards are referenced by **1-based position in their area**, never by `sort_id`, so logs are portable.

| type | fields |
| --- | --- |
| `select`, `skip`, `reroll_boss` | blind select |
| `play`, `discard` | `cards`: positions in hand |
| `use` | `card`: position in consumables, `targets`: positions in hand (optional) |
| `sell` | `area`: `jokers` or `consumables`, `card`: position |
| `reorder_jokers` | `order`: permutation of joker positions |
| `buy`, `buy_and_use` | `card`: position in the shop jokers row |
| `redeem` | `card`: position in the voucher row |
| `open` | `card`: position in the booster row |
| `reroll`, `leave` | shop |
| `pick` | `card`: position in the pack, `targets`: positions in hand (optional) |
| `skip` | in a pack: skip the pack |
| `cash_out` | round end |
| `endless` | after a win |

Hand order follows the game: cards drawn into hand are kept sorted the way the game sorts them (by rank by default), so positions mean the same card in both.

An action log is JSON lines: the setup on line 1, then one action per line.

## Snapshot

One JSON object per line, written after every action (and one after the run starts, `step` 0).

```json
{
  "step": 12, "phase": "play",
  "ante": 2, "round": 4, "money": 9, "chips": 340,
  "hands_left": 3, "discards_left": 2, "hand_size": 8,
  "blind": {"key": "bl_hook", "target": 1500},
  "hand": ["AS", "KH:m_glass", "TD:e_foil", "7C:s_red"],
  "deck": ["2H", "9S", "..."],
  "discard_count": 5,
  "jokers": [{"key": "j_joker", "ed": null, "eternal": false, "perishable": false, "rental": false, "sell": 1, "ab": {}}],
  "consumables": ["c_mercury"],
  "shop": {"jokers": [{"key": "j_greedy_joker", "ed": null, "cost": 5}], "vouchers": [{"key": "v_grabber", "cost": 10}], "boosters": [{"key": "p_arcana_normal_1", "cost": 4}]},
  "reroll_cost": 5,
  "pack": ["c_fool", "c_star"],
  "levels": {"Pair": {"level": 2, "chips": 25, "mult": 3, "played": 4}},
  "vouchers": ["v_overstock_norm"],
  "tags": ["tag_economy"],
  "rng": {"cdt1": 0.4127830211393, "rarity1sho": 0.0918273645123}
}
```

- Card string: `<rank><suit>` then optional `:<enhancement>`, `:<edition>`, `:<seal>`, `:+<perma bonus chips>` in that order. Ranks `2`-`9`, `T`, `J`, `Q`, `K`, `A`; suits `S`, `H`, `D`, `C`. Enhancement and edition use center keys (`m_glass`, `e_foil`), seals `s_red`, `s_blue`, `s_gold`, `s_purple`. Playing cards in the shop or a pack use the same string.
- `deck` is the remaining draw pile **in draw order** (next card first). This is hidden information; the snapshot carries it on purpose.
- `ab` holds a joker's mutable numbers (the scaling and counter fields of `ability` and `ability.extra`, numbers only, keys sorted).
- `rng` is `G.GAME.pseudorandom` without `seed` and `hashed_seed`, each value with 13 decimals. Matching `rng` proves the sim made the same random calls in the same order.
- Fields a sim build does not produce yet are left out. The comparer reports them as "not covered", not as a difference.

## Comparer

`luajit tools/botsim/diff/compare.lua <real.jsonl> <sim.jsonl>` prints the first step where the two differ, the field path and both values, and a coverage summary. Numbers compare exactly except `chips`, which compares after the game's own rounding.

## What the real game recorder does (tools/botsim/diff)

Details the formats above leave open, as the recorder writes them. The sim should do the same.

- Setup line of a recorded log has one more field, `hands_order`: the names of `G.GAME.hands` in the order `pairs()` walked them in the recording process. LuaJIT 2.1 seeds its string hash per process, so that order changes from one process to the next, and the game uses it for To Do List, the Orbital Tag hand and The Ox tie-break (the most played hand when two are tied). The sim must take its hand order from this list wherever the game walks `G.GAME.hands`, and must never let a `pairs()` order over string keys decide anything.
- Every run is recorded with all content unlocked and discovered, so shop and pack pools are the full vanilla pools.
- `phase` is `B.phase()`: `blind_select`, `play`, `shop`, `pack`, `round_eval`, `game_over`, `win`. The last snapshot of a lost run has phase `game_over`.
- `blind` is only there while `G.GAME.facing_blind` is set (from selecting a blind until the round is cashed out). `target` is `G.GAME.blind.chips`.
- `shop` is only there while the shop exists (`G.shop`), which includes packs opened from the shop. A playing card in the shop jokers row has its card string as `key`.
- `pack` is only there in phase `pack`. A joker or consumable in a pack is its center key, followed by `:<edition>` when it has one (`j_joker:e_foil`).
- `consumables` entries are center keys (a playing card there would use its card string).
- `ab` keys: numeric fields of `ability` under their own name (`mult`, `x_mult`, `extra_value`, `perish_tally`, `hands_played_at_create`, `order` and so on), `extra` when `ability.extra` is a number, and `extra.<name>` for numeric fields of an `ability.extra` table. String fields (To Do List's `to_do_poker_hand`) are not in `ab`.
- `levels` has all twelve hands, visible or not. `vouchers` is sorted. `tags` keeps the order of `G.GAME.tags`.
- `deck` is `G.deck.cards` reversed: the game draws from the end of that array.
- Numbers: integers as integers, other numbers with the fewest digits that read back to the same double; `rng` values with exactly 13 decimals.
- When a replayed action is refused or the game hangs, the recorder writes `{"step": n, "error": "..."}` and stops that run; the comparer always counts an `error` line as a difference.
- Comparer coverage rule: a field missing on one side is "not covered" only when the other file never has that field path at all; inside `rng`, `levels` and `ab` any missing key is a difference.
- CI runs the sim inside LOVE 11.5 (`love tools/botsim/diff/lovesim <repo> <out dir> <logs...>`, which calls `tools/botsim/replay.lua` for every log) so it uses the game's own LuaJIT and `math.random`; Ubuntu's packaged LuaJIT gives different shuffles for some seeds. Then `compare.lua --dirs` on the real and sim folders. Recorded runs: `tools/botsim/diff/seeds.jsonl`, workflow `.github/workflows/botsim-diff.yml` (push to `ci-botsim`), artifact `botsim-real`.
