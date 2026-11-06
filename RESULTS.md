# Results: w14

w14 is the current Bot-latro player. It plays fair: it never reads the seed, sees only what a human sees on screen, and gets one try per seed. Every number below counts real wins only, meaning the run beat the ante 8 boss.

## Gold Stake, all 15 decks

3000 games, 200 per deck, seeds BENCH41601 to BENCH41800.

**158 wins, 5.27% (95% interval 4.47% to 6.07%).** w13 won 83 of the same 3000 seeds (2.77%). Every deck has at least one win.

| Deck | Games | Wins | Win rate | Reached ante 5 | Reached ante 8 | Mean ante |
|---|---|---|---|---|---|---|
| Yellow | 200 | 20 | 10.0% | 79% | 16% | 5.61 |
| Anaglyph | 200 | 19 | 9.5% | 76% | 20% | 5.54 |
| Blue | 200 | 15 | 7.5% | 80% | 18% | 5.72 |
| Zodiac | 200 | 15 | 7.5% | 70% | 14% | 5.13 |
| Ghost | 200 | 14 | 7.0% | 82% | 16% | 5.54 |
| Checkered | 200 | 11 | 5.5% | 87% | 13% | 5.72 |
| Green | 200 | 11 | 5.5% | 80% | 12% | 5.47 |
| Magic | 200 | 9 | 4.5% | 78% | 14% | 5.41 |
| Plasma | 200 | 8 | 4.0% | 78% | 6% | 5.38 |
| Abandoned | 200 | 8 | 4.0% | 78% | 12% | 5.35 |
| Nebula | 200 | 8 | 4.0% | 68% | 12% | 5.03 |
| Painted | 200 | 7 | 3.5% | 78% | 10% | 5.33 |
| Erratic | 200 | 6 | 3.0% | 74% | 13% | 5.33 |
| Red | 200 | 6 | 3.0% | 74% | 10% | 5.22 |
| Black | 200 | 1 | 0.5% | 47% | 4% | 4.07 |

Mean ante counts a win as 9. With 200 games a deck, the gap between neighbouring rows is mostly noise. Black is the exception: it is clearly the hardest, with half its runs dead before ante 5.

## Every stake, Red deck

200 games per stake, seeds BENCH34001 to BENCH34200. w13 on the same seeds in brackets.

| Stake | Wins | Win rate | Reached ante 8 |
|---|---|---|---|
| 1 White | 157 (149) | 78.5% | 89% |
| 2 Red | 151 (147) | 75.5% | 90% |
| 3 Green | 97 (71) | 48.5% | 70% |
| 4 Black | 81 (56) | 40.5% | 64% |
| 5 Blue | 70 (50) | 35.0% | 57% |
| 6 Purple | 33 (18) | 16.5% | 28% |
| 7 Orange | 15 (6) | 7.5% | 20% |
| 8 Gold | 6 of 200 (7) | 3.0% | 10% |

## How it plays

- **Hands:** a solver picks every play and discard. It looks ahead over the draws still to come in the round.
- **Shops, packs and blind skips:** a rollout search makes these choices. For each candidate move it plays the run forward in its head, five candidates at a time and up to 128 rollouts, two antes deep from ante 3 on. A small neural net judges the position where each rollout stops.
- **Joker order:** jokers are re-sorted before every blind and inside every rollout.
- **The net:** w14's net was trained on 5949 of w13's own games (812389 decisions). At each shop, pack and blind choice it learned the move the search picked and where the run ended.
- **Scaling jokers:** the net underrated jokers whose own mult, xMult or chips grow during a run (Hologram, Spare Trousers, Constellation, Campfire and others). w12 and w13 add a measured value per ante for each one held. That value was fitted on separate games, on seeds outside every test range.

The exact command line is in `tools/botsim/ci/w14_decks.txt` and `w14_ladder.txt`.

## How each version was accepted

Each version is the previous one plus a single change. A change is kept only when all of these hold:

1. **Paired games.** Both versions play the same seeds, so only their decisions differ.
2. **A Gold gain on all 15 decks** that clears the noise: z of 2 or more on the mean ante, or on the games only one side won.
3. **A stake ladder not worse in real wins.** This is the stake 1 to 7 table above, played by both versions.
4. **A shuffle check.** Replaying with harmless internal reordering must give identical games.
5. **Two leak checks.**
   - An empty hint about the future must change nothing.
   - A planted peek at the future must be caught.

   Passing both shows the player cannot use hidden information.

| Version | Change | Evidence |
|---|---|---|
| w1 | fair hand solver | |
| w2 to w6 | joker order and swaps, one value scale, tie-breaks, solver judges every clearing play | Gold win rate on Red, Blue and Black went from 0.52% (w3) to 0.95% (w5) |
| w7 | one more ante of rollout depth at antes 4 to 7, selling jokers mid-fight | +0.103 antes, z 6.5, over 2100 games |
| w8 | the same depth from ante 3 | +0.097 antes, z 3.3, and +0.042, z 2.2, on fresh seeds |
| w9 | five candidates in the rollout race | ladder 450 vs 416 wins |
| w10 | faster race | same strength, 12 to 20% less time |
| w11 | joker order inside rollouts, cached | +0.062 antes, z 2.59 |
| w12 | scaling joker values | 77 vs 59 wins over two Gold samples |
| w13 | scaling values refit on 6000 w12 games | ladder 497 vs 469 wins, z 2.6 on games one side won |
| w14 | net retrained on 5949 of w13's own games | Gold 158 vs 83 wins over 3000 games, +0.20 antes, z 5.0 and 4.6 on two samples; ladder 604 vs 497 wins |

## What it still gets wrong

Most runs that die at antes 4 to 8 score only 40 to 60% of what the blind needs. The build is far short, not unlucky on the last hand.

Several rule-based fixes were built and measured, and none of them won more games:
- early money discipline
- deck building with tarots
- valuing hand levels, enhanced cards and vouchers
- a build power check

The net already prices those about right. What is left is spread across every decision, which is why w14 came from training the net on the player's own games instead. The next versions repeat that: play with the new net, train on those games, keep the net only if it wins more.

## Reproducing

The sim needs the game's card tables, which are not in this repo; see the README. w14's net is `tools/botsim/n13c.bnnw` on the `nets` branch, which the w14 job files fetch. w13's release has its net (`r5val.bnnw`) and the w13 game records. In the game records a real win is `won == 1` and `need == 0`. `tools/botsim/train/games.py` counts them.
