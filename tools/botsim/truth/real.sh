#!/usr/bin/env bash
job=$1 jobs=$2 procs=$3
set -u
logs=$(mktemp -d)
tar xzf tools/botsim/truth/logs.tgz -C "$logs"
mkdir -p "$OUT/real" "$OUT/sim"
echo "game commit $BOTSIM_GAME_COMMIT" | tee "$OUT/commit.txt"
ls "$logs"/*.log.jsonl | sort | awk -v j="$job" -v k="$jobs" '(NR - 1) % k == j' > "$OUT/mine.txt"
for ((p = 0; p < procs; p++)); do
    mine=$(awk -v p="$p" -v k="$procs" '(NR - 1) % k == p' "$OUT/mine.txt" | tr '\n' ' ')
    [ -n "$mine" ] || continue
    BOTSIM_REPLAY_TAG="r$p" bash tools/botsim/diff/run.sh replay "$OUT/real" $mine > "$OUT/run_$p.txt" 2>&1 &
done
wait
rm -f "$OUT"/real/stdout_*.txt
timeout 3000 love tools/botsim/diff/lovesim "$PWD" "$OUT/sim" $(cat "$OUT/mine.txt") > /dev/null 2> "$OUT/sim_stderr.txt"
luajit tools/botsim/diff/compare.lua --dirs "$OUT/real" "$OUT/sim" --md > "$OUT/compare.md"
head -8 "$OUT/compare.md"
n=$(find "$OUT" -name '*.lua' | wc -l)
echo "lua files in out: $n"
[ "$n" -eq 0 ]
