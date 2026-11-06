# botlatro-sim

A headless Balatro simulator in LuaJIT and the bots trained on it (Seer, Fair Seer, the net). This is the training side of the Balatro Overhaul mod.

Current results (w13, fair play, real wins only): 2.68% at Gold Stake over 6000 games on all 15 decks, 74.5% at White Stake on the Red deck. Full tables, method and how each version was accepted: [RESULTS.md](RESULTS.md).

The game itself is not here. The sim's card tables (`assets/bot/sim/data_*.lua`) and the game files some tests compare against (`assets/game.lua`, `assets/challenges.lua`, `assets/functions/`) are fetched at CI time from the private mod repo by `.github/actions/game-files`, using the `BOTSIM_GAME_KEY` deploy key. They are in `.gitignore`; don't commit them.
