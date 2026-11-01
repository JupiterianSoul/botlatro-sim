#!/usr/bin/env bash
job=$1
P="who=net weights=ft/net.bnnw sims=32 fair=1 search_ph=shop,pack,blind_select quick_clear=1 pace=1.25 ro_h=1 ro_mon=0.5 ro_net=9 ro=128 ro_a=32 ro_z=2 curve=1 prefix=BENCH stakes=8"
mkdir -p "$OUT/logs"
slot_run() {
    awk -v j="$job" -v s="$1" '$1 == j && $2 == s' tools/botsim/truth/plan.txt | while read -r _ _ deck first seeds part; do
        timeout 19000 luajit tools/botsim/train/eval.lua $P first="$first" seeds="$seeds" decks="$deck" part="$part" parts=4 log="$OUT/logs" jsonl="$OUT/g_${deck}_${first}_${part}.jsonl" > /dev/null
        echo "$deck $first $part exit $?" >> "$OUT/exits.txt"
    done
}
for s in 0 1 2 3; do slot_run "$s" & done
wait
luajit tools/botsim/diff/log_check.lua "$OUT/logs" "$OUT/check_all.jsonl"
tar czf "$OUT/all_logs.tgz" -C "$OUT/logs" .
mkdir -p "$OUT/keep"
while read -r b; do
    [ -f "$OUT/logs/$b.jsonl" ] && mv "$OUT/logs/$b.jsonl" "$OUT/logs/$b.final" "$OUT/keep/"
done < tools/botsim/truth/keep.txt
rm -rf "$OUT/logs"
ls "$OUT/keep" | wc -l
