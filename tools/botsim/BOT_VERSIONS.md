# Bot versions

Gabriel's decision (2026-10-29): the game ships several bots.

| Version | Plays | Where |
| --- | --- | --- |
| Seer (cheat) | Reads the seed: knows every future card, shop and pack, plans with full knowledge. Always labeled as cheating, its stats kept apart. | PC and phone |
| Fair, PC | Fair Seer plus the trained net, with a "thinking" setting the player chooses (sampled worlds, search depth, seconds per move: Quick, Normal, Deep, Max or a number of seconds). Uses the C scan library through FFI when present. | PC only |
| Fair, phone | The trained net plus a small search, budget tuned to stay smooth on the phone. | Phone (and PC) |

Optional later: weaker VS Computer difficulty levels from earlier checkpoints or smaller thinking budgets.

Only the fair versions go through the leak and shuffle checks and count toward the Gold Stake goal.
