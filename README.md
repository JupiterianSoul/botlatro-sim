# botlatro-sim

A headless Balatro simulator in LuaJIT and the bots trained on it (Seer, Fair Seer, the net). This is the training side of the Balatro Overhaul mod.

Current results (w14, fair play, real wins only): 5.27% at Gold Stake over 3000 games on all 15 decks, 78.5% at White Stake on the Red deck. Full tables, method and how each version was accepted: [RESULTS.md](RESULTS.md).

## Game files

The game itself is not here. The sim's card tables (`assets/bot/sim/data_*.lua`) and the game files some tests compare against (`assets/game.lua`, `assets/challenges.lua`, `assets/functions/`) are fetched at CI time from the private mod repo by `.github/actions/game-files`, using the `BOTSIM_GAME_KEY` deploy key. They are in `.gitignore`; don't commit them.

## What's here

- `assets/bot/sim/` is the simulator: the game rules as a pure state machine (`bot.sim.engine`, `bot.sim.state`), deterministic from the seed.
- `assets/bot/seer/` and `assets/bot/nn/` are the players: the Seer search, its fair variant that only sees what a human would see, and the net that scores moves.
- `tools/botsim/` has the benches and tests (`bench.lua`, `fuzz.lua`, `replay.lua`, `test/`, `truth/`), `c/` a small C scanner the sim can load through FFI (`make -C tools/botsim/c`), `train/` the net training in PyTorch (`bnn/`) with the record and eval tools, `ci/` the job builders and readers for the Actions runs, and `cloud/` the scripts that ran the same jobs on rented boxes.
- `RESULTS.md` has the measured win rates and the rules a new version has to pass; `tools/botsim/BOT_VERSIONS.md` lists what changed in each player.

## Running it

With LuaJIT 2.1 and the game files in place, from the repo root:

```
luajit tools/botsim/bench.lua 40
```

plays 40 seeds over mixed decks and stakes and prints sim speed. Benchmarks and training run on GitHub Actions (`botsim-bench.yml`, `botsim-work.yml`), which build LuaJIT with FMA off so every machine plays the same seed the same way.

## License

All rights reserved, see [LICENSE](LICENSE).
