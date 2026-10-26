# Job contract and metrics format

A job is a folder with an executable called `run`, for example `jobs/fake/run`. `hz.py run <name>` starts it on every box through `jobrun.py`, which sets the environment below, records the job's pid and turns a systemd stop into a stop file. The dashboard only knows what the job writes to its metrics file, so a trainer that follows this page gets the whole dashboard for free.

## What the job gets

The working directory is the repo copy on the box (`/opt/botsim/repo`), so `luajit tools/botsim/bench.lua` works as is.

| variable | meaning |
| --- | --- |
| `BOTSIM_RUN` | run id, like `r20261025-140257` |
| `BOTSIM_BOX` | this box's name |
| `BOTSIM_ROLE` | `head` (serves the dashboard, collects results on Stop) or `node` |
| `BOTSIM_WORKERS` | how many worker processes to start, defaults to the core count |
| `BOTSIM_DEADLINE` | unix time when this box deletes itself |
| `BOTSIM_RUN_DIR` | `/opt/botsim/run`, everything in it is pulled back |
| `BOTSIM_METRICS` | `$BOTSIM_RUN_DIR/metrics.jsonl`, append metrics here |
| `BOTSIM_CHECKPOINTS` | `$BOTSIM_RUN_DIR/checkpoints`, put saved nets here |
| `BOTSIM_STOP_FILE` | when this file exists, save and exit |
| `BOTSIM_PEERS` | path to `run.json`: every box with name, ip, role, cores |
| `BOTSIM_JOB_DIR` | the job folder |

Anything passed with `hz.py run <job> --env KEY=VALUE` is there too.

## Stopping

The job must check `BOTSIM_STOP_FILE` at least every few seconds. When it appears: write the latest checkpoint, append a `state` line with `"state": "saved"`, and exit 0. The file shows up on an emergency Stop from the dashboard, a few minutes before the deadline (the watchdog asks early so there is time to save), or on `systemctl stop botsim-job`. After 150 seconds `jobrun.py` kills the job anyway.

## Metrics file (contract v2)

One JSON object per line, appended, never rewritten. Write whole lines (build the line, then one `write` of the line plus `\n`); the reader ignores a half written last line. Every line has:

- `t`: unix time in seconds (float)
- `type`: one of the types below
- `box`: optional, the box name (the reader knows which box a file came from)

Unknown types and fields are ignored, so adding more is safe. Every box writes its own file; the head box mirrors the other boxes' files over HTTP and aggregates everything, so the browser only ever gets small aggregates (plus the one recorded game being watched).

What drives what on the dashboard:

| line | panels |
| --- | --- |
| `progress` | games/s, decisions/s, sims per decision per box, time left, box list |
| `game` | every filtered panel: tiles, win rate, ante reached, death causes, deck x stake, final jokers, economy |
| `gen` | training curves (losses, learning rate), generation tile |
| `eval` | strength vs references, best generation, the "new best" phone alert |
| `record` | Watch a game |
| `state`, `log`, `checkpoint` | status pill, events list, demo badge |
| `bench` | latest benchmark |

### `progress`

Every 5 to 10 seconds per box.

```json
{"t":1792900010.2,"type":"progress","games":12840,"decisions":1180000,"sims":472000000,"workers":16,"gen":3,"work_done":12840,"work_total":500000,"load1":15.7}
```

- `games`: games finished on this box since the job started (cumulative, never resets)
- `decisions`, `sims`: cumulative too, optional. They give decisions/s and sims per decision.
- `workers`, `load1`, `gen`: optional
- `work_done`, `work_total`: optional, in any unit the job likes (games, positions, steps). Time left is `(work_total - work_done) / rate`, with the rate measured over the last 10 minutes of `work_done`. Without them the dashboard says the time left is unknown; it never guesses.

### `game`

One line per finished self-play game. About 250 bytes, so a million games is about 250 MB on the box; the dashboard reads it once and keeps only per generation x deck x stake buckets.

```json
{"t":1792900011.5,"type":"game","gen":3,"deck":"b_red","stake":2,"seed":"7KX2PQ9A","won":0,"ante":4,"round":11,"money":17,
 "death":"bl_wall","jokers":["j_joker","j_baron"],"mpa":[6,11,15,17],"hands":24,"discards":13,"dec":61,"sims":400,"dur":3.2}
```

| field | meaning |
| --- | --- |
| `gen` | generation of the net that played it |
| `deck`, `stake` | game keys (`b_red` ... `b_erratic`), stake 1 (White) to 8 (Gold) |
| `chal` | challenge key (`c_omelette_1`, ...), omit for a normal run |
| `seed` | the run seed |
| `won` | 1 or 0 |
| `ante` | ante reached when the run ended. A won run counts as `win_ante + 1` (9 for a normal run), same as `final_ante` in `.bspr` records |
| `round` | round reached |
| `money` | money at the end |
| `death` | the blind that ended a lost run: `bl_small`, `bl_big` or the boss key (`bl_wall`, `bl_final_vessel`, ...). Omit when won |
| `jokers` | joker keys held at the end |
| `mpa` | money after each ante's shop, index 0 = ante 1 (drives the economy chart) |
| `hands`, `discards` | hands played and discards used over the run |
| `dec` | decisions the search made |
| `sims` | average simulations per decision |
| `dur` | wall seconds the game took |

Everything but `gen`, `deck`, `stake`, `won` and `ante` is optional; panels without data say so.

### `games` (v1, still read)

Results since the previous `games` line, per deck and stake: `{"type":"games","gen":3,"deck":"b_red","stake":1,"games":40,"wins":11}`. They feed the win rate and the heatmap only (no ante, death or jokers). Write either `game` lines or `games` lines, not both, or the games count twice.

### `gen`

When a generation finishes training.

```json
{"t":1792900300.0,"type":"gen","gen":4,"loss":0.93,"loss_policy":0.71,"loss_value":0.16,"loss_ante":0.06,"lr":0.00028,"samples":1840000,"buffer":1000000,"train_s":74.2,"steps":2000,"epochs":0.47,"val_policy":0.74,"val_value":0.03,"val_ante":0.07,"val_win_pred":0.004,"val_win_true":0.003,"val_brier":0.003,"val_ante_mae":0.41,"val_ante_bias":-0.05,"val_records":4096}
```

Every number is kept, the chart plots `loss_policy`, `loss_value`, `loss_ante` (or `loss` alone) and `lr`; `samples`, `buffer`, `train_s` show in the tooltip. `val_*` are the same losses on held-out runs after training (dashed lines), `val0_*` before training, `val_win_pred` and `val_win_true` the mean predicted and real win rate on those records, `val_ante_mae` the ante head's error in antes, `epochs` how many passes over the window the steps made.

### `eval`

Generation against references on a fixed seed set. One line per player and per (deck, stake) cell the set covers, so the deck and stake filters apply to this panel too. A line without `deck` or `stake` counts for every deck or stake filter.

```json
{"t":1792900400.0,"type":"eval","set":"fixed-960","who":"gen","gen":4,"deck":"b_red","stake":1,"n":8,"wins":3,"ante":6.4,"ante_sq":340}
{"t":1792900400.0,"type":"eval","set":"fixed-960","who":"rules","deck":"b_red","stake":1,"n":8,"wins":1,"ante":3.9}
{"t":1792900400.0,"type":"eval","set":"fixed-960","who":"seer","deck":"b_red","stake":1,"n":8,"wins":7,"ante":8.8}
```

- `who`: `gen` (needs `gen`), `rules` (the old rules bot), `seer`, or any other reference name. References are drawn as flat lines; evaluate them once per set.
- `n`, `wins`: games and wins on that cell; `ante`: average ante reached (won = 9).
- `promoted: true` on any line of a generation marks it as the new best (the trainer's own gate). Without any `promoted` flag the dashboard takes the generation with the highest win rate.
- The dashboard computes 95% Wilson intervals from `n` and `wins`, compares the latest generation with the previous best and each reference, and sends the "new best" alert.
- The newest `set` is shown. Keep the same set for the whole run so generations stay comparable.

### `record`

A full game with every decision, for Watch a game. Big (a won run is 30 to 60 KB), so record a sample: about one game in 1000, or one per box per minute. The dashboard keeps only an index and reads the line from disk when someone opens it.

```json
{"t":1792900500.0,"type":"record","id":"box0-12841","gen":4,"deck":"b_red","stake":1,"seed":"7KX2PQ9A","won":0,"ante":4,"death":"bl_wall",
 "moves":[
  {"phase":"play","ante":2,"blind":"bl_big","need":1200,"score":450,"money":11,"hands":3,"discards":2,"deck":38,
   "hand":["AH","KH","TD","9H","4H","2H","2S","7C"],"jokers":["j_joker"],"cons":["c_pluto"],
   "act":"Play Flush","cards":[0,1,3,4,5],"v":0.31,"ante_hat":4.6,"sims":400,
   "top":[{"a":"Play Flush","cards":[0,1,3,4,5],"visits":0.62,"prior":0.41,"q":0.33},{"a":"Discard 3","cards":[2,6,7],"visits":0.21,"prior":0.30}]}
 ]}
```

Per move: what the bot saw (`ante`, `blind`, `need` = chips to beat, `score` so far, `money`, `hands` and `discards` left, `deck` = cards left, `hand`, `jokers`, `cons`), what it did (`act` as readable text, `cards` = indexes into `hand` it played or discarded), and the search (`v` = win probability estimate, `ante_hat` = expected final ante, `sims`, `top` = the best candidates with `visits` share, `prior` from the net and optional `q`). `phase` is `play`, `shop`, `blind` or anything else. Cards are rank plus suit: `2`..`9`, `T`, `J`, `Q`, `K`, `A` and `S`, `H`, `D`, `C`.

### `checkpoint`

After a checkpoint is written. `path` is relative to `BOTSIM_RUN_DIR`.

```json
{"t":1792900300.0,"type":"checkpoint","gen":3,"path":"checkpoints/gen_0003.lua"}
```

### `bench`

A benchmark result, shown as "Latest benchmark". `name` names the suite; every other number is listed as is (a key containing `winrate` is shown as a percentage).

```json
{"t":1792900400.0,"type":"bench","name":"dev200","gen":3,"winrate":0.21,"avg_ante":5.4,"decisions_per_s":2900}
```

### `state`

Job state changes: `running`, `saved` (stopped on request after saving), `done` (finished its work), `failed`. `jobrun.py` adds `starting` (with `job`, the job folder name), `failed` with an exit code, `killed` if the job ignored the stop file, and an `exit` line on a clean exit. `"demo": true` (or the job being `fake`) shows the DEMO badge on the page and tags every phone alert, so made-up numbers are never mistaken for a real run.

```json
{"t":1792900000.0,"type":"state","state":"running","msg":"self-play gen 0"}
```

### `log`

Free text worth keeping: `{"t":...,"type":"log","level":"error","msg":"..."}`. Shown in the events list.

## The train job

`jobs/train/run` follows this contract and writes every line above. It reads its settings from `--env` (`TRAIN_GENS`, `TRAIN_GAMES`, `TRAIN_SIMS`, `TRAIN_STEPS`, `TRAIN_WINDOW`, `TRAIN_EVAL_PER` and the rest, listed with their defaults in `README.md`). Worth knowing when reading its data:

- `game.gen` is the generation of the net that played the game. Teacher games for generation 0 write no `game` lines.
- `eval` uses the set name `d15-s12-120` by default (15 decks x stakes 1 and 2 x 4 seeds; `fixed-48` is the old 4 deck set). `ante_sq` is the sum of squared final antes, so the dashboard can draw an ante interval. The greedy reference is `who: "rules"`, Seer is `who: "seer"` only when its hook is configured. `promoted` is set when a generation beats the best so far on average ante, then wins (`TRAIN_BEST_BY=wins` swaps them). Without `promoted` lines the dashboard picks the best by ante too.
- `gen.samples` is steps x batch size, `gen.buffer` the number of decisions in the replay window.
- `progress.work_done` and `work_total` are games, written by the head only.
- `bench` has `name: "selfplay"` and one line per generation: the eval win rate, average ante and the head's decisions per second.

The head and nodes also talk through `/<secret>/api/xfer` on the node dashboard: `GET ?ls=<dir>`, `GET ?get=<path>`, `POST ?name=<path>` (the body is the file) and `POST ?name=<path>&rm=1`. It is limited to `/opt/botsim/xfer`, path characters `A-Za-z0-9_.-` and `/`, 512 MB per file.

## Dashboard API

All under `/<secret>/`. Filters are query parameters, the same ones the page keeps in its URL hash:

| param | meaning |
| --- | --- |
| `g=3-12` | generation range, either end optional (`g=10-`) |
| `d=b_red,b_blue` | decks |
| `s=1,2` | stakes |
| `c=any` / `none` / `<challenge key>` | challenge runs |
| `r=won` / `lost` | result |
| `a=2-8` | ante reached (9 = won) |
| `w=3600` | time window in seconds |
| `sp=stake` / `deck` / `chal` / `none` | split of the win rate chart |

- `api/state`: run, boxes, money, deadline, totals (also used by `hz.py status` and `watch`).
- `api/view?<filters>&v=<version>&fk=<filter key>&ev=<event seq>`: state plus all panel aggregates. When `v` and `fk` match what the server has, `panels` is `null` (nothing new); `events` only lists events after `ev`.
- `api/records?<filters>`: newest 200 recorded games matching the filters, plus the total.
- `api/record?id=<id>`: one full recorded game.
- `api/node?raw=1&since=<offset>`: raw bytes of a box's metrics file from an offset (the head uses it to mirror nodes).
