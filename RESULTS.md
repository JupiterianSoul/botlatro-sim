# Results: w13

w13 is the current Bot-latro player. It plays fair: it never reads the seed, sees only what a human sees on screen, and gets one try per seed. Every number below counts real wins only, meaning the run beat the ante 8 boss.

## Gold Stake, all 15 decks

6000 games, 400 per deck, seeds BENCH41401 to BENCH41800.

**161 wins, 2.68% (95% interval 2.27% to 3.09%).** Every deck has at least two wins.

| Deck | Games | Wins | Win rate | Reached ante 5 | Reached ante 8 | Mean ante |
|---|---|---|---|---|---|---|
| Blue | 400 | 22 | 5.5% | 84% | 16% | 5.69 |
| Anaglyph | 400 | 18 | 4.5% | 74% | 12% | 5.26 |
| Yellow | 400 | 16 | 4.0% | 78% | 10% | 5.35 |
| Erratic | 400 | 16 | 4.0% | 76% | 9% | 5.26 |
| Ghost | 400 | 14 | 3.5% | 78% | 9% | 5.27 |
| Red | 400 | 13 | 3.2% | 73% | 8% | 5.15 |
| Checkered | 400 | 10 | 2.5% | 83% | 10% | 5.58 |
| Magic | 400 | 9 | 2.2% | 73% | 8% | 5.05 |
| Nebula | 400 | 8 | 2.0% | 69% | 8% | 4.97 |
| Abandoned | 400 | 8 | 2.0% | 79% | 11% | 5.30 |
| Zodiac | 400 | 8 | 2.0% | 69% | 6% | 4.92 |
| Plasma | 400 | 6 | 1.5% | 78% | 6% | 5.25 |
| Green | 400 | 6 | 1.5% | 75% | 8% | 5.13 |
| Painted | 400 | 5 | 1.2% | 78% | 6% | 5.15 |
| Black | 400 | 2 | 0.5% | 47% | 2% | 3.90 |

Mean ante counts a win as 9. With 400 games a deck, the gap between neighbouring rows is mostly noise. Black is the exception: it is clearly the hardest, with half its runs dead before ante 5.

## Every stake, Red deck

200 games per stake, seeds BENCH34001 to BENCH34200.

| Stake | Wins | Win rate | Reached ante 8 |
|---|---|---|---|
| 1 White | 149 | 74.5% | 88% |
| 2 Red | 147 | 73.5% | 88% |
| 3 Green | 71 | 35.5% | 58% |
| 4 Black | 56 | 28.0% | 53% |
| 5 Blue | 50 | 25.0% | 44% |
| 6 Purple | 18 | 9.0% | 20% |
| 7 Orange | 6 | 3.0% | 12% |
| 8 Gold | 13 of 400 | 3.2% | 8% |

## How it plays

- **Hands:** a solver picks every play and discard. It looks ahead over the draws still to come in the round.
- **Shops, packs and blind skips:** a rollout search makes these choices. For each candidate move it plays the run forward in its head, five candidates at a time and up to 128 rollouts, two antes deep from ante 3 on. A small neural net judges the position where each rollout stops.
- **Joker order:** jokers are re-sorted before every blind and inside every rollout.
- **Scaling jokers:** the net underrated jokers whose own mult, xMult or chips grow during a run (Hologram, Spare Trousers, Constellation, Campfire and others). w12 and w13 add a measured value per ante for each one held. That value was fitted on separate games, on seeds outside every test range.

The exact command line is in `tools/botsim/ci/w13_decks.txt` and `w13_ladder.txt`.

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

## What it still gets wrong

Most runs that die at antes 4 to 8 score only 40 to 60% of what the blind needs. The build is far short, not unlucky on the last hand.

Several rule-based fixes were built and measured, and none of them won more games:
- early money discipline
- deck building with tarots
- valuing hand levels, enhanced cards and vouchers
- a build power check

The net already prices those about right. What is left is spread across every decision, so the next step is training a better net.

## Reproducing

The sim needs the game's card tables, which are not in this repo; see the README. The release for this version has the net weights (`r5val.bnnw`) and all 7400 game records used above, one JSON line per game. In those records a real win is `won == 1` and `need == 0`. `tools/botsim/train/games.py` counts them.
