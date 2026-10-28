# Bot-latro autopilot: design and contracts

One launch runs the training plan (docs/BOTLATRO_TRAINING_PLAN.md, steps 1 to 6) with no PC and no Claude session. A tick reads the state, polls the running job, applies the gate, starts the next job and writes the state back. Ticks are idempotent: running one twice in a row, or after a crash, never starts a second job or a second paid round.

Decided by Gabriel (26 Oct): repo secrets for Hetzner token, SSH key, results deploy key and ntfy topic; an hourly scheduler stub on main that only fires while the repo variable `BOTSIM_AUTOPILOT=on`; paid rounds run under a budget he approves in the picker (total plus per-round cap), the autopilot pauses and alerts when it is used up.

## Pieces

| path | what | owner |
| --- | --- | --- |
| `tools/botsim/autopilot/autopilot.py` | CLI and tick state machine | runner agent |
| `tools/botsim/autopilot/store.py` | state store: a checkout of the private results repo, or a local dir for tests | runner agent |
| `tools/botsim/autopilot/steps.py`, `gates.py`, `ci.py`, `paid.py` | steps, pure gate functions, CI dispatch/poll/download, Hetzner rounds through hz.py | runner agent |
| `tools/botsim/autopilot/profiles.json` | settings per profile: `tiny` (CI test, Hetzner step dry), `tiny-paid` (same, real cpx02 round with the fake job), `full` | runner agent |
| `tools/botsim/autopilot/results.py` | game lines to result rows, Wilson CI, RESULTS.md renderer | yaml agent |
| `tools/botsim/bench/seeds.json` | fixed benchmark seeds, same forever | yaml agent |
| `.github/workflows/botsim-autopilot.yml` | the tick (dispatch, workflow_call) and the unit tests (push to `ci-ap-*`) | yaml agent |
| `.github/workflows/botsim-work.yml` | CI work fan-out, one matrix job per `{label, cmd}`, chains a tick when done | yaml agent |
| `.github/workflows/botsim-autopilot-schedule.yml` | stub for main: hourly `workflow_call` of the botsim tick, `if: vars.BOTSIM_AUTOPILOT == 'on'` | yaml agent |
| `tools/botsim/cloud/hz.py`, `boxctl.py`, `jobrun.py` | run never skips silently, readback, shared ledger, delete when done | safety agent |
| `tools/botsim/seer/fair_shuffle.lua` | shuffled-view fairness check | safety agent |
| `tools/botsim/seer/teacher.lua` `mode=fair`, `tools/botsim/train/eval.lua` seeds | Fair Seer teacher records, net eval on the fixed seeds | yaml agent |

Python 3 standard library only (like hz.py). No code comments. Unit tests (stdlib unittest, in `tools/botsim/autopilot/test/`) run on GitHub Actions only, never on Gabriel's PC; locally only `python3 -m py_compile`, `luajit -bl`, luacheck.

## Store (private repo JupiterianSoul/botlatro-results)

Cloned on the runner with the deploy key (`~/.config/botsim/results_deploy_key`, pinned `~/.config/botsim/github_known_hosts`). Writes are commit + push with `git pull --rebase` retry (the head box pushes `runs/<run>/` to the same repo; paths never overlap). Folder `autopilot/` for the real run, `autopilot-test/` for tests (`--dir`).

```
ledger/spend.json              shared Hetzner ledger, union of every machine (hz.py owns it)
<dir>/state.json               the state below
<dir>/results.jsonl            one row per measured cell (format below)
<dir>/RESULTS.md               rendered table
<dir>/log.md                   one line per event, newest last
<dir>/hz/<run>.json            hz.py run state of a paid round (ips, pinned host keys, dashboard secret)
<dir>/checkpoints/<name>.bnnw  checkpoints the autopilot produced or promoted
<dir>/work/<tag>.json          summary of each CI work run: run id, artifacts, parsed numbers
```

## state.json

```json
{
  "version": 1, "profile": "full", "dir": "autopilot",
  "status": "running | waiting | stopped | done",
  "reason": "why waiting or stopped",
  "step": "fair_bench | fair_speed | teacher | imitation | expert | ladder",
  "attempt": 1,
  "job": null,
  "flags": {"fair_speed_ok": false, "expert_ok": false},
  "paid": {"approved_eur": 0, "round_cap_eur": 0, "spent_eur": 0, "approved_at": null},
  "gates": {"fair_bench": {"fails": 0, "last": {}}},
  "baseline": {}, "best": {"name": null, "path": null, "score": {}},
  "stake": 1, "stale_gens": 0, "rounds": [], "teacher": {"games": 0, "records": 0, "artifacts": []},
  "alerts_sent": {}, "lock": null, "updated": 0
}
```

`job` is `{"kind": "ci", "tag", "run_id", "dispatched", "jobs": [...]}` or `{"kind": "hetzner", "run", "deadline", "round_cost_eur", "started", "readback": {...}}`.

## CLI (autopilot.py)

```
autopilot.py init --profile tiny|tiny-paid|full [--dir autopilot] [--from-ci RUN_ID]   new state; refuses if one exists unless --reset
autopilot.py tick                    one tick (what the workflow runs)
autopilot.py status [--json]
autopilot.py flag NAME on|off        fair_speed_ok, expert_ok
autopilot.py approve --eur X --round-cap Y    after Gabriel's OK in the picker
autopilot.py stop [reason] | resume  stop also runs hz.py down when a round is live
autopilot.py results                 re-render RESULTS.md
```

Global options: `--dir`, `--store-local PATH` (tests), `--dry-run` (prints what it would dispatch or create). Exit 0 unless the tick itself crashed; gate failures are state, not exit codes.

## Tick

1. Load state; if `stopped` or `done`, print and exit. Take the lock (stale after 45 min).
2. A job is running: poll it.
   - CI: find the run by its run-name `botsim work <tag>`; not finished, exit; finished, download artifacts, parse, gate.
   - Hetzner: `hz.py status --json` and `runs/<run>/metrics.jsonl` in the store. Running and before the deadline, exit (write progress). Job ended (state `done`, `saved`, `stopped`, `failed`), boxes gone, or past the deadline: `hz.py down`, then `hz.py list --json` must be empty (retry 3 times, then alert and stop), copy the best checkpoint, gate. Past deadline + 10 min with boxes alive: down and alert.
3. Gate pass: write rows and the event, advance (`attempt` 1). Gate fail: `fails + 1`; at 2 fails in a row the autopilot stops (`hz.py down` if a round is live) and sends an urgent ntfy alert; at 1 it retries, and a paid step retries only after its free CI precheck passes again.
4. No job: start the step. Flag-gated step without its flag, or a paid step without approved budget: status `waiting`, alert once. Otherwise dispatch the CI work or start the round.
5. Render RESULTS.md, write state, push.

## Steps

| step | where | job | gate (full / tiny) |
| --- | --- | --- | --- |
| `fair_bench` | CI | leak test (`fair_test.lua`, slow), shuffled-view check, Fair Seer lite on the fixed seeds (white, red, gold cells from the profile) | 0 leak failures, every shuffled game identical, white wins >= 25% / >= 0 |
| `fair_speed` | CI, needs `fair_speed_ok` | same seeds as the white baseline, plus leak and shuffle checks | mean s/game <= 60 and wins not worse than baseline (one-sided two-proportion z, p < 0.05) |
| `teacher` | CI fan-out | `teacher.lua mode=fair` batches until `games` reached | games and records reached, leak test passed on this commit |
| `imitation` | CI (CPU torch) | `train.py` on the teacher artifacts, then net-alone eval on the fixed seeds, shuffle check of the net | white mean ante >= 5.5 / >= 1, shuffle identical |
| `expert` | Hetzner, needs `expert_ok` and budget | rounds of the `train` job with `TRAIN_PLAYER=fair` (net-guided Fair Seer games instead of self-play) from the current best | round best beats the previous best on its fixed eval, shuffle check of the new best passes on CI; stops after `stale_gens >= 4` |
| `ladder` | Hetzner | as `expert` with `TRAIN_STAKES` at the current rung | promote at the profile's win rate (white 60%), next stake; after Gold, full benchmark on every deck, then `done` |

Before every `up` (paid.py): free precheck passed for this checkpoint, `paid.approved_eur - paid.spent_eur >= round cost`, `round cost <= paid.round_cap_eur`, shared ledger total + round cost <= 100 EUR (hz.py refuses too), then `hz.py doctor`, `up --types T --hours H --spend-cap C --yes`, `deploy`, `run <job> --env ... --env BOTSIM_DELETE_WHEN_DONE=1 --env TRAIN_PATIENCE=4 --json`. Any failure after `up`: `hz.py down`, verify `list`, alert. The run state file goes to `<dir>/hz/<run>.json`.

## hz.py contract (safety agent)

- `run`: reads the job's real state on each box over ssh. A box whose job is active is never "skipped": without `--force` the command prints `NOT STARTED` with that box's start time and settings and exits 3. After a start or restart it reads back, on the box, the start time (box clock, must be after the restart command) and `/etc/botsim/job.env` (must equal what was sent) and prints both per box; mismatch exits 2. `--json` prints one JSON object last: `{"started": [box], "refused": [box], "failed": [box], "readback": {box: {"start": epoch, "env": {}}}}`.
- `status --json`, `list --json`: machine-readable versions.
- Shared ledger: `ledger()` unions the local `spend.json` with `ledger/spend.json` in the results repo; `write_ledger()` writes both (push retried; a failed push is kept pending and retried at the next call). `up` refuses when the shared ledger cannot be read. Union rule: servers by id; a deletion beats "still running"; between two deletions a non-estimated one wins, else the later one (errs high). Adjustments by id.
- Delete when done: with `BOTSIM_DELETE_WHEN_DONE=1` in the job env, the head runs the normal stop path (collect, backup push, delete the boxes) as soon as its job exits for any reason. Today only the patience stop does that.

## Shuffled-view check (fair_shuffle.lua)

`luajit tools/botsim/seer/fair_shuffle.lua who=fair|net|cheat budget=lite weights=... prefix=BENCH first=1 seeds=N decks=... stakes=... max_steps=M out=FILE.json`

Each game is played twice: normally, and with the bot shown a resampled hidden future at every decision (a world drawn from the visible state only, new key per decision) while its move is applied to the real state. A fair deterministic bot plays the identical action line both times. Output `{"who", "games", "identical", "diffs": [{"seed", "deck", "stake", "step", "phase"}]}`; exit 0 only if every game is identical. `who=cheat` is the control: the cheating Seer must differ on at least one game, or the check itself is broken.

## CI work (botsim-work.yml)

`gh workflow run botsim-work.yml --ref <ref> -f tag=<tag> -f jobs='<json>' -f chain=<ref or empty> -f dir=<dir>`; `jobs` is a list of `{"label", "cmd", "torch": bool, "timeout": minutes}`. run-name `botsim work <tag>`. Each matrix job gets the pinned LuaJIT, optional CPU torch (`tools/botsim/cloud/jobs/train/needs.json` versions), `$OUT`, `$CORES`, `GH_TOKEN` (actions read, to download earlier artifacts), uploads artifact `<tag>-<label>` (retention 30 days). A last job dispatches `botsim-autopilot.yml` with `command=tick` on `chain` when set, so CI steps advance without waiting for the hourly tick.

## Results rows (results.jsonl) and RESULTS.md

Game lines in (from `fair.lua`, `eval.lua seeds mode`, `teacher.lua`): `{"deck", "stake", "seed", "won", "ante", "time"}`. Row out, one per (checkpoint, who, deck, stake):

```json
{"t": 0, "step": "fair_bench", "checkpoint": "fair-seer-lite", "who": "fair_lite", "set": "BENCH", "deck": "b_red", "stake": 1,
 "n": 30, "wins": 12, "ante_sum": 180, "time_sum": 5400.0, "fair": true, "ci_run": 123}
```

`fair` is true only after the leak test (search bots) and the shuffle check passed for that checkpoint. RESULTS.md: status line (step, status, spent, approved budget, updated), then per checkpoint a table deck, stake, n, wins, win % with 95% Wilson interval, mean ante, s/game, an overall row per stake, then a decks x stakes board of the best fair checkpoint, then a "not counted" list for rows with `fair` false.

## Fixed seeds (tools/botsim/bench/seeds.json)

`{"version": 1, "prefix": "BENCH", "count": 240, "decks": [the 15 decks], "stakes": [1, 2, 3, 4, 5, 6, 7, 8]}`; seed i is `prefix .. %04d`, the same list for every deck and stake. Never edit; a new set gets a new prefix and version.

## Alerts

ntfy through `alerts.send`, topic from `~/.config/botsim/ntfy_topic`: every gate result (fail high priority), stop (urgent), waiting for a flag or budget (once per reason), paid round start (cost) and end (cost, result, boxes verified gone).

## Secrets and config on the runner

`BOTSIM_HETZNER_TOKEN` to `~/.config/botsim/hetzner_token`, `BOTSIM_SSH_KEY` to `~/.ssh/botsim_hetzner` (public half from `ssh-keygen -y`), `BOTSIM_RESULTS_KEY` to `~/.config/botsim/results_deploy_key`, `BOTSIM_NTFY_TOPIC` to `~/.config/botsim/ntfy_topic`; GitHub's host keys from the committed `tools/botsim/cloud/github_known_hosts`. All 0600.

## Not automated (code work the autopilot waits for)

- Fair Seer speed (`fair_speed_ok`): search only decisions that matter (shop, packs, skips, discards; trivial ones by the greedy rule), reuse rollouts across nearby decisions, keep leak and shuffle checks green, target under 60 s per lite game with the same wins on the same seeds.
- Net-guided Fair Seer for expert iteration (`expert_ok`): built as `TRAIN_PLAYER=fair` in the `train` job. Each lane plays one Fair Seer game with the current net; where the sampled worlds disagree, the net's MCTS move joins the candidates. Records carry world votes as soft targets. Rollouts still use the fast policy, not the net's value.
