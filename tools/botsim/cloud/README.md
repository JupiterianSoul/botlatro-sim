# botsim cloud runner

Rents Hetzner boxes by the hour for botsim training, runs a job on them, shows it on a dashboard you can open on the phone, and deletes everything when the run is over. Python 3 standard library only, no pip installs.

A "job" is any folder with an executable `run` (see `METRICS.md` for the contract). `jobs/train/` is the real Bot-latro training loop (see "The train job" below). `jobs/fake/` is a stand-in that runs the real `bench.lua` for its speed and makes up everything else (generations that improve, games on every deck and stake, deaths, jokers, evaluations against the rules bot and Seer, recorded games), so the whole loop and every dashboard panel can be tried before the trainer exists. Its data is marked DEMO on the page and in phone alerts.

## Money rules

- Hard cap: 100 EUR total, VAT included, over the life of the project. The 25 EUR prepaid credit is part of that 100, not on top of it.
- Every paid run needs Gabriel's OK in chat, with the planned cost and what has been spent so far (`hz.py plan` prints both).
- Hetzner bills every started hour, so a box costs `started hours x gross hourly price`. The price used is the server plus its IPv4 address, read live from the API (`/server_types` and `/pricing`, gross = VAT included).
- `spend.json` is the ledger, `SPEND.md` is the readable copy. `hz.py` updates both on every create and delete. If the Hetzner invoice ever differs, add an entry under `adjustments` in `spend.json` and run `hz.py spend`.
- The ledger is shared between machines (this PC, the GitHub autopilot). `hz.py` merges the local `spend.json` with `ledger/spend.json` in the private repo JupiterianSoul/botlatro-results (cloned over ssh with `~/.config/botsim/results_deploy_key` and the pinned `~/.config/botsim/github_known_hosts` into `~/.config/botsim/shared-results`) and pushes the merged file after every change. Merge rule: servers by id, a deletion beats "still running", between two deletions the real one beats an estimate, else the later one wins; adjustments by id. A push that fails is kept pending and retried at the next call, it never stops a run. `up`, `smoke` and `bench` refuse when the shared ledger cannot be read. `BOTSIM_SHARED_LEDGER=off` turns the shared copy off (tests only).
- `up` refuses when spent so far plus the planned run would go over 100 EUR, when the run costs more than its own `--spend-cap`, or when the boxes don't fit the account core limits (17 shared and 144 dedicated vCPUs since the raise on 27 Oct, enough for `ccx63:3`).

## How a box cleans up after itself

Every box gets a deadline at `up`: `--hours` after creation, pulled 3 minutes before the next hour boundary so it never starts an extra billed hour. Cloud-init installs a systemd timer (`botsim-watchdog.timer`, every 30 s) before anything else, so it is armed even if the deploy never happens.

- A few minutes before the deadline it drops a stop file so the job saves its checkpoint, and the head collects the other boxes' results.
- At the deadline the box deletes itself through the API. It asks the metadata service for its own server id and deletes only that id.
- `hz.py watch` is a second, local watchdog: it deletes any box 5 minutes past its deadline, stops everything if the next started hour would pass the cap, pulls results every 10 minutes, and runs pull + down by itself once the run has stopped.
- `hz.py down` deletes every server labeled `botsim=1`, waits until the API lists none, and is safe to run any number of times.

The token risk: Hetzner API tokens are per project, not per server, so the token the box uses to delete itself could delete or create anything in the "Bot-Latro" project. To keep that small:

- the project holds nothing but these boxes,
- the token sits in `/etc/botsim/token`, root only (0600), and the cloud-init copy in `/var/lib/cloud` is root only too,
- the job and the dashboard run as the unprivileged `botsim` user, and an iptables rule stops every non-root process from reaching the metadata service (where the user data, token included, can be read),
- the code that uses it (`boxctl.py`) only ever deletes its own server, or the run's other boxes on Stop.

Someone with root on a box could still use the token on the whole project until it is revoked. If a box ever looks compromised, delete the token in the Hetzner console (Security, API tokens) and make a new one. Rotating it after a batch of runs costs nothing.

## Setup (already done)

- `~/.config/botsim/hetzner_token`, read and write token for the Bot-Latro project. Never printed, never committed.
- SSH key `botsim-hetzner` on the account, private key at `~/.ssh/botsim_hetzner`.

## Commands

Run from the repo root. Everything that creates, starts or deletes takes `--dry-run`.

```
python3 tools/botsim/cloud/hz.py doctor [--types cpx22,ccx13]
python3 tools/botsim/cloud/hz.py smoke  [--type cx23] [--yes]
python3 tools/botsim/cloud/hz.py bench  --types cpx22,ccx13 [--yes]
python3 tools/botsim/cloud/hz.py plan   [--types cpx62,ccx33] [--hours 1] [--spend-cap EUR] [--json]
python3 tools/botsim/cloud/hz.py up     [same options] [--yes] [--adopt | --replace] [--dry-run]
python3 tools/botsim/cloud/hz.py deploy [--job DIR] [--for-job NAME] [--force] [--trust-new-host-keys] [--dry-run]
python3 tools/botsim/cloud/hz.py run <job> [--env KEY=VALUE] [--workers N] [--force] [--delete-when-done] [--json] [--dry-run]
python3 tools/botsim/cloud/hz.py status [--json]
python3 tools/botsim/cloud/hz.py pull [--down] [--dry-run]
python3 tools/botsim/cloud/hz.py down [--dry-run]
python3 tools/botsim/cloud/hz.py list [--json]
python3 tools/botsim/cloud/hz.py spend [--json]
python3 tools/botsim/cloud/hz.py watch [--pull-every 10] [--dry-run]
python3 tools/botsim/cloud/hz.py alerts-test [--dry-run]
```

- `doctor` is free and creates nothing. It checks the token, that the `botsim-hetzner` key on the account is the local `~/.ssh/botsim_hetzner`, that ssh, rsync and ssh-keygen exist, that the plan fits the limits and the money cap and that the types are actually in stock (Hetzner marks sold out types per location; CX23 was sold out everywhere on 25 Oct), that no stray or unknown server exists, that the ledger agrees with the API, that job scripts are executable in git, that the golden sim test is in the tree and that the pinned LuaJIT source is cached. `up`, `smoke` and `bench` run it first and refuse on any problem.
- `smoke` is the end-to-end check on one cheap box: doctor, up, deploy, the fake job for 3 minutes, waits for games on the dashboard, pull, down, and checks nothing is left. `bench` does doctor, up, deploy, runs `bench_mcts.lua` and `bench.lua 40` on every box in parallel, writes `tools/botsim/results/bench-<run>.md` (CPU model, vCPUs and output per box) and deletes the boxes. Both default to `--hours 0.9` and both can simply be run again after any failure or Ctrl-C: they pick up the same boxes and skip what is done.
- `--types` is a comma list of `type[:count]`, like `cpx62,ccx33` or `ccx63:3`. The first box is the head: it serves the dashboard and collects results on Stop.
- `--hours` can be a fraction, but billing rounds up, so `--hours 0.9` costs the same as `--hours 0.1` and gives cloud-init time to finish.
- `up` asks you to type `yes` unless `--yes` is given. It prints the dashboard link and saves it to `~/.config/botsim/dashboard_url`. Run state (ips, secret, pinned host keys, what is deployed) lives in `~/.config/botsim/current_run.json`, outside the repo, rewritten atomically after every step.
- `deploy` waits for ssh and cloud-init, rsyncs `assets/bot/`, `assets/functions/` (the sim tests read game functions from it) and `tools/botsim/` (not `results/`) to `/opt/botsim/repo`, builds the pinned LuaJIT on the box and runs the sim tests (including the golden deck in `test_econ.lua`). A box that fails them is not marked deployed, and `run` refuses to start a job until every box is.
- `results-setup` (free, once) makes the private repo `JupiterianSoul/botlatro-results`, a deploy key for it in `~/.config/botsim/results_deploy_key` (write access to that repo and nothing else) and pins GitHub's ssh host keys in `~/.config/botsim/github_known_hosts`. After that, every `up` gives the key to the head box only (root's copy stays 0600; the `imitate` job reads teacher records with its own copy, `/etc/botsim/results_key.job`, owned by the `botsim` user), and the head pushes its `/opt/botsim/run` (with what it collected from the other boxes) to `runs/<run>/` every 10 minutes, as soon as the job ends (done, stopped or crashed), and once more when the run stops. `job.pid`, `STOP*` files and files over 50 MB are left out. So a lost PC or a missed `pull` never loses a run. `doctor` says whether it is set up.
- `pull` copies each box's `/opt/botsim/run` to `tools/botsim/results/<run>/<box>/`. Boxes that are already gone come from what the head collected.

`run` reads the real job state on every box first. A box whose job is already running is never skipped silently: without `--force` it prints `NOT STARTED` with that job's start time and settings, leaves it alone and the command exits 3. After every start it reads back, on the box, the job's start time (box clock, must be after a timestamp taken just before the restart) and `/etc/botsim/job.env` (must equal what was sent), prints both, and exits 2 if either is wrong or the job is not active. The last line is a summary per box; with `--json` one JSON object follows it: `{"started": [], "refused": [], "failed": [], "readback": {box: {"start": epoch, "env": {}}}}`. Exit codes: 0 all started, 2 something failed, 3 something refused.

`--delete-when-done` adds `BOTSIM_DELETE_WHEN_DONE=1`: as soon as the head's job exits for any reason (done, failed, killed) the head runs the normal stop path (collect, backup push, delete every box). `jobrun.py` writes `run/JOB_START` and `run/JOB_EXIT`; the watchdog only acts on an exit that belongs to the current start, never while `run` is restarting the job, and a node's own exit never triggers it. The fake job takes `FAKE_MINUTES=N` to finish by itself.

## When something goes wrong

The rule: a box that is already paid for is never thrown away by a failure. Hetzner bills every started hour, so deleting a box after a failed step and making a new one pays the hour twice. Every box still deletes itself at its deadline, so a kept box never costs more than the hour already started.

- **Ctrl-C or a kill in the middle of anything.** The command finishes the API call or step it is in, saves the state and prints what it kept and the exact command to resume (the same command again). A second Ctrl-C stops at once; the state is written before every create, so even a server created by a request in flight is found again by its name.
- **`up` finds botsim boxes already running.** If they belong to the current run, match `--types` and have at least 10 minutes left (`--min-left`), it adopts them and only creates what is missing. Otherwise it explains and lets you choose: `--adopt` uses them as they are, `--replace` deletes them first. Servers from another run or unknown to the ledger make `doctor` refuse; `hz.py down` is the way to clear them.
- **A create fails halfway** (type sold out in every location, limit hit). The boxes already made are kept and listed with their paid-until time; rerunning the same command creates the rest.
- **ssh does not come up.** Every try prints the real ssh error (refused, timed out, host key, auth). It gives up after 5 minutes of boot, 90 seconds of auth refusals or 60 seconds of a wrong host key, says which, keeps the boxes and prints the retry command. Auth: run `doctor`. Host key: see below; `deploy --trust-new-host-keys` is the escape hatch.
- **cloud-init, the LuaJIT build or the sim tests fail.** deploy prints the tail of the relevant log, keeps the box and refuses to run a job there. Fix the cause, then run `deploy` again (finished boxes are skipped).
- **To give up**, `hz.py down` deletes everything and says how many paid minutes it throws away.

### SSH host keys

Each box gets its host key from us: `up` generates a fresh ed25519 key per box, passes it in the cloud-init user data (`ssh_keys`), and pins its public half in a known_hosts file of that run only (`~/.config/botsim/runs/<run>/known_hosts`), keyed by the box name (`HostKeyAlias`), not by its IP. ssh then runs with `StrictHostKeyChecking=yes`. So a reused IP can never clash with an old key, and the first connection is already verified, no trust on first use. The Hetzner API cannot return a server's host key or its console output, which is why the key goes in rather than being read out. The private key lives only in the user data (root-only on the box, like the token) and is never written to disk locally.

### LuaJIT

Ubuntu's `luajit` package shuffles some seeds differently from the real game, so boxes don't use it. Steam Balatro ships LuaJIT 2.0.5 and LOVE 11.5 for Android ships 2.1.1700008891; neither fuses the multiply-add in `math.randomseed`. gcc does when it targets a CPU with FMA (Ubuntu 26.04 defaults to x86-64-v3), which changes about 1 seed in 12, so every build here uses `XCFLAGS=-ffp-contract=off`. `deploy` copies the source of LuaJIT commit `2a8e017ef1ec` (version 2.1.1791988261, the one on Gabriel's laptop) from a local cache (`~/.config/botsim/cache`, fetched once from GitHub by `doctor` and checked against its sha256) and builds it on the box into `/usr/local/bin` (about 10 s on 4 laptop cores). The build is plain x86_64, no `-march`, so it runs the same on the Intel and AMD boxes.

## The train job

`hz.py run seerbench --env "SEER_BENCH=<bench.lua args>; <more args>"` runs Seer benchmarks on the head box with every core (`--jobs` defaults to the core count, results and logs land in `run/seer/`, so pull and the backup carry them). Commands separated by `;` run one after the other; a Stop keeps the partial results. Plain `deploy` is enough, it needs no torch.

`hz.py run train --env KEY=VALUE ...` starts an AlphaZero style loop on every box. It needs CPU torch on the head, so deploy with `hz.py deploy --for-job train` first. `run` refuses on boxes that lack it, and a plain `deploy` (also `smoke` and `bench`) installs nothing extra.

How a round goes:

1. **Generation 0.** With no starting weights, every box plays greedy teacher games (`selfplay_pool.sh -t 1`) until the head has `TRAIN_TEACHER_GAMES` of them, then the head trains generation 0 on those records. With `TRAIN_WEIGHTS=<path in the repo or URL>` the head takes that `.bnnw` as generation 0 instead, so a later round continues from the last checkpoint.
2. **Self-play.** Every box, the head included, runs one self-play lane per core. Each lane plays short rounds on its own (`selfplay_pool.sh -w 1`, `TRAIN_RUNS_PER_FILE` games) with the newest weights it has, cycling through `TRAIN_STAKES`, so a long game only holds up its own lane instead of the whole box. Lanes run under `SCHED_IDLE` (`chrt -i 0`, on top of `nice 19`), so anything else on the box always gets the CPU first. Each round writes `game` lines and now and then one `record` line. The `.bspr` records of a round are tagged with the generation of the net that played them.
3. **Records to the head.** A node packs each round into a tar in `/opt/botsim/xfer/out`. The head polls every node's dashboard (`GET /<secret>/api/xfer?ls=out`, then `get=`, then `POST ...&rm=1`) and unpacks the records into `/opt/botsim/work/batches/<tag>/`. Same secret path and port as the rest of the node API, no ssh between boxes. The records stay in `work/`, not in the run dir, so the 10 minute backup only carries metrics and checkpoints.
4. **Training on the head.** When `TRAIN_GAMES` games played by generation N have arrived, the head runs `train.py` on CPU torch with `--init` the previous weights. It reads the newest `TRAIN_WINDOW` generations of records, capped at `TRAIN_WINDOW_MB` newest first so the 4 GB of a cpx22 are enough, and writes `gen_NNNN.bnnw`. One run in 20 (`TRAIN_VAL_EVERY`) is held out: `train.py` reports policy, value and ante loss on those runs before and after training, plus value calibration (mean predicted win against the real win rate, Brier score, ante error), so the training chart shows over- or underfitting. While it trains, the phase reads `training generation N, step k/K`. The nodes keep playing meanwhile, and late batches from the old generation still land in the window. Its self-play lanes keep going with the old generation on whatever CPU training leaves free (the same for evaluation), like the nodes, and late batches from the old generation still land in the window.
5. **Weights to the nodes.** The head pushes the new weights to every node (`POST .../api/xfer?name=in/gen_NNNN.bnnw`, retried every 2 s until it works). A node switches at the start of its next round.
6. **Evaluation.** Every generation plays a fixed seed set (`tools/botsim/train/evalset.lua`): by default all 15 decks at the trained stakes with `TRAIN_EVAL_PER` = 8 seeds per cell, 240 games named `d15-s12-240` for stakes 1 and 2, at `TRAIN_EVAL_SIMS` with the same search settings as self-play (value mix, score prior, skip penalty). `TRAIN_EVAL_DECKS=b_red,b_blue,b_yellow,b_black TRAIN_EVAL_STAKES=1,3 TRAIN_EVAL_PER=6` gives back the old `fixed-48`. The greedy reference runs once at the start and is written as `who: "rules"`. A generation is marked `promoted` when it beats the best so far on average ante, then wins (`TRAIN_BEST_BY=ante`, the default while wins are rare; `wins` ranks wins first). `TRAIN_FROM=latest` (default) keeps training and self-play on the newest generation; `TRAIN_FROM=best` evaluates each new generation before anyone plays it and, when it is not promoted, keeps self-play and the next training on the best one. The run ends with `checkpoints/best.bnnw`.
7. **Stop.** The stop file is checked every second, also while training or evaluating (the child is killed). The head keeps `latest.bnnw` and a `gen_NNNN.bnnw` for every generation in `checkpoints/` (1.3 MB each), writes `state saved` and exits 0. After `TRAIN_GENS` generations it writes `state done` and tells the nodes to finish.

Lines written: `progress` (with `work_done` and `work_total` in games on the head), `game` (deck, stake, seed, won, ante, round, money, death blind, jokers, money per ante, hands, discards, decisions, average sims, seconds), `record` (one sampled game, at most every 90 s per box), `gen`, `eval`, `checkpoint`, `bench` (name `selfplay`, per generation), `state` and `log`. Teacher games write no `game` lines.

Settings, all through `--env`. The defaults aim at a first round of 30 to 40 minutes on one or two cpx22; that is a guess, nothing has run on a real box.

| variable | default | meaning |
| --- | --- | --- |
| `TRAIN_GENS` | 12 | generations to train after generation 0 |
| `TRAIN_GAMES` | 300 | self-play games per generation, all boxes together |
| `TRAIN_SIMS` | 64 | search simulations per decision |
| `TRAIN_FAST_SIMS`, `TRAIN_FULL_FRAC` | 16, 0.25 | playout cap randomization (`TRAIN_FULL_FRAC=1` turns it off); the policy then trains only on records with at least `SIMS/2` simulations |
| `TRAIN_STEPS`, `TRAIN_BATCH` | 600, 256 | training steps per generation and batch size |
| `TRAIN_LR`, `TRAIN_LR_TEACHER` | 0.0005, 0.001 | learning rates for generations 1+ and for generation 0 |
| `TRAIN_WINDOW` | 3 | generations of records in the replay window (the teacher set counts as one) |
| `TRAIN_WINDOW_MB` | 150 | cap on the records read per training run, about 100k decisions |
| `TRAIN_TEACHER_GAMES`, `TRAIN_TEACHER_STEPS` | 300, 1200 | generation 0 |
| `TRAIN_WEIGHTS` | none | starting `.bnnw`, a path in the repo or an http(s) URL |
| `TRAIN_STAKES` | `1,2` | stakes the self-play cycles through |
| `TRAIN_RUNS_PER_FILE` | 5 | games per worker per round |
| `TRAIN_EVAL_PER`, `TRAIN_EVAL_SIMS` | 8, 32 | seeds per cell of the fixed set, simulations when evaluating |
| `TRAIN_EVAL_DECKS`, `TRAIN_EVAL_STAKES` | all, `TRAIN_STAKES` | decks (`all` or a comma list) and stakes of the eval set |
| `TRAIN_BEST_BY`, `TRAIN_FROM` | ante, latest | how the best generation is picked; train from the latest or the best |
| `TRAIN_EPOCHS` | 0 | when set, steps become `epochs x records / batch`, between 100 and `TRAIN_STEPS` |
| `TRAIN_WARMUP` | 0 | linear learning rate warm-up steps before the cosine decay |
| `TRAIN_VAL_EVERY` | 20 | hold out one run in this many for the held-out losses |
| `TRAIN_THREADS` | workers | torch threads |
| `TRAIN_PY` | auto | python with torch: `/opt/botsim/venv`, else `tools/botsim/train/.venv` |
| `TRAIN_RECORD_GAP` | 90 | seconds between recorded games per box |
| `TRAIN_VALUE_MIX` | 0.8 | weight of the predicted ante, normalised as `(ante - 1) / win_ante`, in the search leaf value (rest is win probability); negative gives the old `alpha` 0.5 formula |
| `TRAIN_SCORE_PRIOR`, `TRAIN_SCORE_TOP` | 0.3, 6 | play phase: share of the prior taken from an immediate score softmax, and how many best plays (by the cheap estimate) get an exact sim score at the root and are always kept as candidates; 0 turns it off |
| `TRAIN_SKIP_PEN`, `TRAIN_SKIP_ANTE` | 0.2, 1 | blind skip prior multiplied by the penalty up to this ante; 1 turns it off |
| `TRAIN_START_ANTE`, `TRAIN_START_FRAC`, `TRAIN_START_WHO` | off, 0.5, greedy | curriculum: that share of self-play games is first played by the greedy rules (`net`: the current net at 16 sims) until ante N (or a range like `3-4`) without recording; only the rest is recorded. Runs that die before are dropped |
| `TRAIN_SEER_MIX` | 0 | fraction of every training batch drawn from the Seer pool (0.3 = 30%); 0 turns the pool off for generations 1+ |
| `TRAIN_SEER_GAMES` | 0 | Seer pool games per generation, all boxes together; each box plays its share, one game per lane at a time, alongside self-play |
| `TRAIN_SEER_SMOOTH` | 0.05 | label smoothing on Seer's one-hot move, spread over the record's listed actions |
| `TRAIN_SEER_POOL_MB` | 400 | cap on pool files read per training run, newest first |
| `TRAIN_SEER_PRETRAIN`, `TRAIN_SEER_PRETRAIN_GAMES` | 0, 0 | with `TRAIN_WEIGHTS`: train that many steps on the pool only before generation 0, after the pool holds that many games |
| `TRAIN_SEER_POOL` | none | directory or glob of `.bspr` Seer records copied into the pool at start (then no waiting for pretrain games) |
| `TRAIN_SEER_POOL_CMD`, `TRAIN_SEER_POOL_ARGS` | `teacher_pool.sh`, `--mode=solve --max_lines=4` | the pool game command (same environment as the teacher command, plus `SEER_ARGS`) and the `teacher.lua` options it gets |

Seer hooks (Seer lives in `assets/bot/seer/`, this job does not touch it):

- `TRAIN_SEER_TEACHER_CMD`: a shell command used instead of the greedy teacher for generation 0 records. It runs once per round with `OUT_DIR`, `GAMES`, `SEED`, `WORKERS` and `STAKE` set and must leave `.bspr` v2 files in `OUT_DIR` (the writer is `REC.encode_choice`, see DESIGN.md).
- `TRAIN_SEER=1` with `TRAIN_SEER_EVAL_CMD`: a command that plays the fixed set and prints one JSON line per cell, `{"deck":"b_red","stake":1,"n":6,"wins":2,"ante_sum":31}`, the same lines `eval.lua` prints (`EVAL_PER` is in its environment). They are written as `who: "seer"`. With the flag set and no command the job logs an error and carries on.

What deploy installs for it: `apt-get install python3-venv python3-pip`, then `/opt/botsim/venv` with `torch==2.14.1` from `https://download.pytorch.org/whl/cpu` and numpy, no pip cache. The cp312 wheel is 196 MB to download and the venv comes to roughly 0.9 GB on disk (a local py3.14 venv measured 870 MB; a cpx22 has 80 GB). Measured on cpx22 on 2026-10-25: 33 to 35 s per box. It only happens for `deploy --for-job train`, and only on boxes without a working venv (the probe imports torch and numpy). Deploy never copies a local `.venv` or `train/out` to the boxes.

Memory: a cpx22 has 4 GB. `train.py` needs about 1.2 GB for 100k decisions (measured 330 MB for 5k, torch included), a self-play worker around 50 MB.

## Dashboard

`dashboard.py` serves `dashboard.html` and a small JSON API at `http://<head ip>:<random port>/<secret>/`. The secret is 32 random characters; there is no HTTPS, so the link is the only protection. Anything without the secret gets a 404. It's built for the phone first (360 px wide) and spreads into two columns on a laptop. No external scripts or fonts, charts are plain SVG.

The head box reads every box's metrics file (its own from disk, the others mirrored over HTTP every 5 seconds) and folds the games into buckets per generation, deck, stake, challenge, result, ante and 5 minute slot. Every filter and panel is computed from those buckets, so it stays quick with millions of games: the page polls every 4 seconds, gets "nothing new" when nothing changed, and only redraws the panels whose numbers moved.

Filters (the Filters button) apply to every panel: generation range, decks, stakes, won or lost, ante reached, challenge or standard runs, and a time window. They live in the URL after `#`, so a link opens the same view, and the last view is remembered on each device.

Panels:

- tiles: games, win rate with its 95% interval, average ante, generation and best one, games/s, decisions/s with sims per decision, money, measured time left, when the boxes delete themselves, recorded games
- strength vs references: average ante (default) or win rate of each generation on the fixed seed set with its 95% interval, switchable above the chart, against the rules bot and Seer, the best generation ringed, and a plain sentence saying whether the latest one is clearly better than the previous best (intervals apart) or not. This is the "is it really getting better" chart.
- win rate by generation or by time, split by stake, deck, challenge or not split
- training curves: policy, value and ante losses, learning rate
- ante reached: where runs end
- death causes: which blind ends lost runs, and the share per stake
- win % by deck and stake, latest generation or everything filtered, with game counts in each cell
- final jokers: share of won and lost runs holding each joker at the end
- economy: average money after each ante, won vs lost
- throughput per box: games/s, decisions/s, sims per decision
- boxes with CPU load and job state, money against the cap with what's left to pay until the deadline, latest benchmark, events (job states, errors, alerts sent)

Watch a game lists the recorded games matching the filters. Open one and step through it (buttons, slider, arrow keys, autoplay at 0.5x to 4x): the blind and score, ante, money, hands and discards left, the hand with the played cards raised, jokers, consumables, the action taken, the value estimate and the search's top candidates with visit share and prior.

The only control is Emergency stop.

Without any box running, look at a pulled run:

```
python3 tools/botsim/cloud/dashboard.py --local tools/botsim/results/<run>
```

It also prints JSON for scripts: `--dump` (state) or `--dump-view "d=b_red&s=1"` (all panels for a filter).

## Phone alerts

The head box posts to [ntfy](https://ntfy.sh) when the run starts, when a generation becomes the new best on the fixed seeds, when the run finishes, when Stop is pressed, 10 minutes before the boxes delete themselves, and when total spend reaches 80% and 95% of the 100 EUR cap. Each alert is sent once (a dashboard restart doesn't repeat them), and a failed send is retried.

Setting it up once:

1. Run `python3 tools/botsim/cloud/hz.py alerts-test`. The first time it makes a secret random topic and saves it to `~/.config/botsim/ntfy_topic` (0600, outside the repo), then sends a test message.
2. Install the ntfy app (Play Store or F-Droid), tap +, type the topic it printed, keep the server `ntfy.sh`, subscribe. Run `alerts-test` again and the test message should pop up.

Every `hz.py up` after that hands the topic to the head box the same way as the dashboard secret. Anyone who knows the topic can read the alerts, so keep it out of chats and commits; to change it, delete the file and run `alerts-test` again (then subscribe to the new one).

## Files

| file | what |
| --- | --- |
| `hz.py` | the CLI you run locally |
| `common.py` | API client, billing math, ledger and metrics helpers |
| `boxctl.py` | runs as root on each box: watchdog tick, stop routine, self delete |
| `safety.py` | Ctrl-C handling, host key pinning, ssh error classes and bounded waits |
| `jobrun.py` | starts a job with its environment, handles the stop file and the pid |
| `dashboard.py`, `dashboard.html` | the dashboard, box mode and `--local` mode |
| `alerts.py` | ntfy topic file and alert rules |
| `jobs/fake/` | fake job: real bench speed, made-up training data for every panel |
| `jobs/train/` | the real training loop (`run`) and what it needs on a box (`needs.json`) |
| `METRICS.md` | job contract and metrics format |
| `spend.json`, `SPEND.md` | the spending ledger |
| `test/fake_hetzner.py` | local stand-in for the API, built from the recorded real responses |
| `test/fixtures/hetzner_real.json` | real read-only API responses (sanitized), the contract the fake and the code are checked against |
| `test/fakebin/` | fake `ssh` and `rsync` that log their arguments and fail on demand |
| `test/run_cloud_tests.py`, `test/safe_tests.py` | the test suite, never touches the real API |

## Tests

```
nice -n 19 taskset -c 0-3 python3 tools/botsim/cloud/test/run_cloud_tests.py
```

It starts fake APIs on localhost and goes through plan, the cap refusals, up (dry run, cancelled, real against the stub, a half failed create that keeps its box), adoption, list, deploy and run, down twice, then plays two boxes on 127.0.0.2 and 127.0.0.3 with the real dashboard and fake job, Stop, the stop routine and both watchdogs. The second half checks the safety net: field by field contract between the recorded real API, the fake and the code; doctor on a clean account, a sold out type, a wrong ssh key, an unknown and a stray server; a SIGINT at every step of up, deploy and run followed by a resume, plus real signals in the middle of a create (once and twice); `--adopt`, `--replace` and `--min-left`; ssh retries with real error messages, auth and host key give-ups, cloud-init and golden test failures that keep the boxes; pull with one and two boxes; `bench` and `smoke` end to end, interrupted and resumed. It also starts an unprivileged `sshd` on a high port to check the pinned host key for real: login works, a different key on the same address is refused as a host key error in about a second, a new run with its own known_hosts connects. It also checks the v2 dashboard on the live pair: every panel has data, the head mirrors the node, recorded games open, the watch list follows filters, and phone alerts reach a fake ntfy server (started, new best, Stop pressed, finished, each once). On the pulled results it compares the aggregates with the raw game lines for several filters, and runs the alert rules on made-up snapshots. It also checks the hardening: run refuses busy boxes (exit 3), readback mismatches and stale start times fail (exit 2), the shared ledger merge rules against a local bare git repo (no network), up and smoke refusing when it cannot be read, a pending push retried, delete when done on head and node, and `FAKE_MINUTES`. Everything it starts is killed at the end.

To look at the page with lots of data, make six hours of fake history in a few seconds and open it in local mode:

```
mkdir -p /tmp/demo/box0
BOTSIM_RUN_DIR=/tmp/demo/box0 BOTSIM_BOX=box0 BOTSIM_FAKE_BENCH=0 BOTSIM_FAKE_HISTORY=360 BOTSIM_FAKE_MINUTES=0.1 BOTSIM_WORKERS=4 python3 tools/botsim/cloud/jobs/fake/run
python3 tools/botsim/cloud/dashboard.py --local /tmp/demo
```

## Where the train job stopped

Built and tested on two fake boxes (the loop, the node API, deploy dry runs). Not done: Seer records and Seer evaluation (hooks only), a gate that trains from the best generation instead of the newest, splitting games by core count (every box just plays continuously), and everything that needs a real box (below).

First paid round, check in this order. `hz.py deploy --for-job train` finishes and prints the torch version and how long it took (put the number in this file). `doctor` is clean. After `run train` the dashboard shows teacher progress, then a `gen` 0 line and eval lines within minutes. Then compare games per second per box with the settings (if a generation takes much longer than 3 minutes, lower `TRAIN_GAMES` or `TRAIN_SIMS`), look at memory on the head during training (`free -m`), and check that the eval win rate and average ante move over the first generations. A flat curve at ante 1 to 2 means the data is wrong, not that it needs more time.

## Not tested yet

The host key in cloud-init, the LuaJIT build and the golden test have not run on a real Hetzner box yet; `hz.py smoke` is what proves them. The rest of the loop (create, cloud-init, deploy, fake job, dashboard, pull, delete) passed on a real CX23 on 25 Oct. Dashboard v2 and the phone alerts have only run against simulated boxes and a fake ntfy server; on the first real run, check that `alerts-test` reaches the phone and the "started" alert arrives from the box.
