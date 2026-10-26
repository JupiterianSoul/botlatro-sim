# botlatro-sim

A headless Balatro simulator in LuaJIT and the bots trained on it (Seer, Fair Seer, the net). This is the training side of the Balatro Overhaul mod, split out so CI runs on a public repo.

The game itself is not here. The sim's card tables (`assets/bot/sim/data_*.lua`) and the game files some tests compare against (`assets/game.lua`, `assets/challenges.lua`, `assets/functions/`) are fetched at CI time from the private mod repo by `.github/actions/game-files`, using the `BOTSIM_GAME_KEY` deploy key. They are in `.gitignore`; don't commit them.

- `assets/bot/` the sim (`sim/`), Seer search (`seer/`) and the net (`nn/`)
- `tools/botsim/` benches, tests, training, Hetzner tooling (`cloud/`) and the autopilot (`autopilot/`, start with its README)
- results go to a separate private repo, never here

Workflows: `botsim-autopilot` (tick + unit tests on `ci-ap-*` pushes), `botsim-work` (CI fan-out), `botsim-bench` (push a `ci-bench-*` branch with `tools/botsim/ci_bench.txt`), and the hourly schedule that only runs while the repo variable `BOTSIM_AUTOPILOT` is `on`.
