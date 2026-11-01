#!/usr/bin/env bash
order=$1
parts=$2
n=$3
shift 3
python3 tools/botsim/train/games.py mklist "$n" 20001 > "$OUT/list_fwd.txt"
case "$order" in
    fwd) cp "$OUT/list_fwd.txt" "$OUT/list.txt" ;;
    rev) tac "$OUT/list_fwd.txt" > "$OUT/list.txt" ;;
    *) shuf --random-source=<(yes "$order") "$OUT/list_fwd.txt" > "$OUT/list.txt" ;;
esac
for ((j = 0; j < parts; j++)); do
    (timeout 19000 luajit tools/botsim/train/eval.lua "$@" digest=1 curve=1 list="$OUT/list.txt" part="$j" parts="$parts" jsonl="$OUT/games_$j.jsonl" > "$OUT/games_$j.txt" 2>&1; echo "$j exit $?" >> "$OUT/exits.txt") &
done
wait
cat "$OUT/exits.txt"
wc -l "$OUT"/games_*.jsonl | tail -1
