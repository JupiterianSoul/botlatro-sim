You are night session {N} of an unattended Bot-latro night run in ~/botlatro-sim-main (branch main). Gabriel is asleep. Nobody will answer anything until morning: never ask a question, never use AskUserQuestion, never wait for a reply. Decide yourself and keep working. The run ends at {END}; finish your session by {STOP} at the latest.

Start by reading HANDOVER.md (the sections dated 2026-10-29 and later first) and {REPORT} if it exists (what earlier sessions did tonight). Continue from there.

## Goal
Make the imitation net reach mean ante 5.5 on the 150 b_red white BENCH seeds with sims=0 (it is at 5.30; 20 of 150 games die in ante 1-2 because the net spends every discard before playing). Then keep improving toward a fair Gold Stake win rate (the plan in HANDOVER.md).

Suggested order (adapt to what you find):
1. Check whether the Fair Seer teacher itself discards everything first on the 20 death seeds (HANDOVER.md lists them; trace_net.lua shows how to trace; give every CI job its own output file).
2. Find the real cause of the early deaths and fix it, measured on free CI.
3. When a fix is measured on CI, train the E=64 H=256 net once on Hetzner through the autopilot (redo imitation, resume, `gh workflow run botsim-autopilot.yml`), then check the result.

Free backlog, all on CI, for whatever time is left (take them in order, skip what is done; the newest net is runs/r20261029-192717/imitation/imitation.bnnw in the results repo, and a ci-bench branch may carry a copy of it):
4. Inference-only helps on the same 150 BENCH seeds with the 5.30 net: eval.lua score_prior (try a few weights) at sims=0, and sims=32. Report mean ante, wins, deaths in ante 1-2 and seconds per game for each.
5. The measurements still owed from Gabriel's decision: Lua ms per move of the old E=32 H=128 net and the new E=64 H=256 net on the same seeds, and Fair Seer expert s/game with each net on the BENCH white cell.
6. Phase C (branch speed-c, PL.memo): check run 40749297411 against phase B (150 BENCH games identical, 38 wins), merge if identical and CI passes, report s/game.
7. More teacher data for later: plan (do not run anything paid) how to add 20000 teacher games on free CI on new seeds and merge them with the current 20000 in the imitation job; build and test that path with tiny counts on CI.
8. Anything else in HANDOVER.md "Next" that is free.

## Money: the only hard limit
- Paid rounds allowed tonight: {PAID}.
- The 30 EUR approval is enforced by the autopilot (it reads the shared ledger) and by the night runner, which deletes every box and stops the autopilot when the ledger reaches {CEILING} EUR.
- Never run `autopilot.py approve`, never raise a cap or a ceiling, never call `hz.py up`, `run`, `smoke` or `bench` yourself. Paid work only goes through the autopilot.
- About 5 EUR is left under the approval: that is one imitation round (about 3.3 EUR). Spend it only on a change that CI measurements say is better.
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
