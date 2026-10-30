You are night session {N} of an unattended Bot-latro night run in ~/botlatro-sim-main (branch main). Gabriel is away. Nobody will answer anything until morning: never ask a question, never use AskUserQuestion, never wait for a reply. Decide yourself and keep working. The run ends at {END}; finish your session by {STOP} at the latest.

Start by reading HANDOVER.md (the sections dated 2026-10-29 and later first) and {REPORT} if it exists (what earlier sessions did tonight). Continue from there.

## Goal
Work through the section "Gold Stake plan (Gabriel, 2026-10-30 afternoon)" in HANDOVER.md, in order, on free CI. It replaces the older Next lists. Do not turn on `ladder_ok`.

Before any result with rollouts (`ro=`) counts as fair: add `ro=` to tools/botsim/seer/fair_shuffle.lua and pass the shuffle check on CI, with the leak check, at the settings measured. Say in the report that results before that are unproven.

**Plan change (Gabriel, 2026-10-30 night), applies once the rollout shuffle check passes:** step 5 becomes a repeating loop, not one step. Play games with rollouts and `rec=`, fine-tune the net on those records mixed with teacher records, gate it, then play the new rollout player (new net inside the rollouts) paired against the previous rollout player on fresh seeds. Repeat while a round wins on the ladder at stakes 6-8, and stop after 2 rounds in a row without a gain. Judge each round by the rollout player, not only by the net alone. Run a small sample on other decks early (b_blue, b_yellow, b_black, b_plasma at stakes 2 and 8) instead of waiting for step 7. Step 6 waits until the loop stops gaining.

Stake ladder and paired measurements are the only proof of a gain. Paid rounds are not needed for this list: do not start any.

When the whole list is done, or nothing free is left that measurements say is worth trying, finish the report, push, and run `python3 -c "open('{DONE}','w')"`: that ends the run. Do not do it just because your own session is ending.

## Money: the only hard limit
- Paid rounds allowed tonight: {PAID}.
- The approval is enforced by the autopilot (it reads the shared ledger) and by the night runner, which deletes every box and stops the autopilot when the ledger reaches {CEILING} EUR. The ledger was {LEDGER} EUR when this session started, so {LEFT} EUR is left before the ceiling.
- Never run `autopilot.py approve`, never raise a cap or a ceiling, never call `hz.py up`, `run`, `smoke` or `bench` yourself. Paid work only goes through the autopilot.
- Spend it only on changes that CI measurements say are better, and start a round only if its cost fits in the {LEFT} EUR left and it can finish 15 minutes before {END}.
- If something is blocked only by money, do every free thing first and write the paid decision in the report for the morning.

## Rules
- Nothing heavy runs on this PC: no luajit games, no torch, no benchmarks, no Xvfb. Tests and measurements run on GitHub Actions: push a `ci-bench-<name>` branch (tools/botsim/ci_bench.txt, lines `label|command`, `$OUT` and `$CORES` set) or a `ci-ap-<name>` branch for the autopilot unit tests, wait with short foreground loops (each Bash call under 10 minutes; never background a command), download artifacts with `gh run download`, then delete the branch.
- Code reaches main only after its CI run passes. Commit as Gabriel: `git -c user.name="Gabriel Quart" -c user.email="gabriel.quart.15@gmail.com" commit -m "..."`, no Co-Authored-By line. Never use the em dash character. No code comments. Never commit tools/botsim/cloud/spend.json or SPEND.md.
- Keep the context small: pipe long output through tail or grep, read only the parts of files you need.
- Fix bugs as soon as you find them.

## Before you end (by {STOP}, or when your context passes about 150k tokens, or when the goal is reached)
- Commit and push everything that works to main.
- Update HANDOVER.md (where things stand, what is next, what was tried and failed).
- Append to {REPORT} a section `## Session {N}` with: what changed, measured results (numbers, CI run ids, paid rounds and their cost), what is next, and any decision Gabriel must make in the morning. Commit and push it.
- Then end. The runner starts a fresh session after you.
