# Bot-latro autopilot

Runs the training plan (docs/BOTLATRO_TRAINING_PLAN.md, steps 1 to 6) from GitHub Actions, with no PC and no Claude session. The design and contracts are in DESIGN.md; this file is the user side.

## Launch

The state lives in the private results repo (JupiterianSoul/botlatro-results), folder `autopilot/` (`autopilot-test/` for tests).

```
gh workflow run botsim-autopilot.yml --ref main -f command=init -f args='--profile full'
gh variable set BOTSIM_AUTOPILOT --body on
```

`init` refuses when a state exists; add `--reset` to start over. Profiles: `tiny` (CI test, Hetzner step dry), `tiny-paid` (same plus one real cpx02 round with the fake job), `full`. `--from-ci RUN_ID` starts from an earlier CI run's artifacts.

After that the hourly tick (minute 23) does the work. Any command can also run by hand with the same workflow:

```
gh workflow run botsim-autopilot.yml --ref main -f command=tick
```

## Commands

| command | what it does |
| --- | --- |
| `status` | print the state (`--json` for machines) |
| `tick` | one pass: poll the job, apply the gate, start the next one |
| `stop [reason]` | stop for good; also takes a live Hetzner round down |
| `resume` | clear a stop or a wait |
| `flag fair_speed_ok on` | let the fair_speed step run (code work is done) |
| `flag expert_ok on` | let the expert step run (net-guided Fair Seer exists) |
| `approve --eur X --round-cap Y` | the budget for paid rounds, only after you said yes in the picker |
| `results` | re-render RESULTS.md |

Global options: `--dir`, `--store-local PATH`, `--dry-run`.

## Where things are

- `autopilot/RESULTS.md` in the results repo: status line, one table per checkpoint (win rate with 95% Wilson interval, mean ante, seconds per game), the decks x stakes board of the best fair checkpoint, and the rows not counted because the leak or shuffle check did not pass.
- `autopilot/log.md`: one line per event.
- Alerts go to your ntfy topic: every gate result, every stop, a wait for a flag or budget (once), start and end of each paid round with its cost and a check that the boxes are gone.

## Steps and gates

| step | where | gate |
| --- | --- | --- |
| fair_bench | CI | no leak failures, every shuffled game identical, white wins at least 25% |
| fair_speed | CI, needs `fair_speed_ok` | mean s/game at most 60, wins not worse than the baseline |
| teacher | CI fan-out | game and record counts reached, leak test passed |
| imitation | CI, CPU torch | white mean ante at least 5.5, net shuffle check identical |
| expert | Hetzner, needs `expert_ok` and budget | beats the previous best on the fixed eval, shuffle check passes |
| ladder | Hetzner | promote at the profile's win rate, next stake, full benchmark after Gold |

Two gate failures in a row stop the autopilot and send an urgent alert. One failure retries; a paid step only retries after its free CI precheck passes again.

## Cost

Only expert and ladder spend money (Hetzner). A round needs `approved - spent >= round cost`, the round cost under the per-round cap, and the shared ledger under 100 EUR. When the budget is used up the autopilot waits and alerts; run `approve` again to continue. `stop` takes the boxes down.

The CI steps use free-tier Actions minutes. The hourly tick itself is a short job, about 1 to 2 minutes of runner time when idle, so roughly 25 to 50 minutes a day. The work jobs (botsim-work.yml) are the real cost: each matrix job can run up to 340 minutes. Turn the hourly tick off with `gh variable set BOTSIM_AUTOPILOT --body off`.

## Fixed seeds

`tools/botsim/bench/seeds.json` holds the benchmark seeds (prefix BENCH, 240 seeds, 15 decks, stakes 1 to 8). Never edit it; a new set gets a new prefix and version.
