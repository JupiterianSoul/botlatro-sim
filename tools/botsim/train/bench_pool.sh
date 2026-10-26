#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
usage: $0 -m barrier|lanes -t secs -w workers -o outdir [-d repo] [-r runs_per_file] -- selfplay args

Plays self-play the way the train job does for secs seconds and prints games/s and decisions/s for the box.
barrier: one selfplay_pool.sh round with every worker at a time (the job before lanes), lanes: one round
loop per worker under chrt -i 0 (the job now). -d runs the pool of another checkout (an older commit).
EOF
}

mode=lanes
secs=120
workers=$(nproc)
outdir=
repo=$(cd "$(dirname "$0")/../../.." && pwd)
runs=5
while getopts "m:t:w:o:d:r:h" opt; do
    case $opt in
        m) mode=$OPTARG ;;
        t) secs=$OPTARG ;;
        w) workers=$OPTARG ;;
        o) outdir=$OPTARG ;;
        d) repo=$(cd "$OPTARG" && pwd) ;;
        r) runs=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ "${1:-}" = "--" ] && shift
[ -n "$outdir" ] || { usage; exit 1; }
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)
pool=$repo/tools/botsim/train/selfplay_pool.sh
idle=()
command -v chrt >/dev/null && idle=(chrt -i 0)

round() {
    local dir=$1 w=$2 seed=$3
    shift 3
    mkdir -p "$dir"
    local stake=$((seed % 2 + 1))
    "${idle[@]}" bash "$pool" -w "$w" -o "$dir" -r "$runs" -n 1 -s "$seed" -c -1 -- "$@" stake=$stake \
        games="$dir/g_{seed}.jsonl" recs="$dir/r_{seed}.jsonl" rec_runs=1 >/dev/null 2>&1
}

t0=$(date +%s.%N)
end=$((SECONDS + secs))
if [ "$mode" = "barrier" ]; then
    n=0
    while [ $SECONDS -lt $end ]; do
        n=$((n + 1))
        round "$outdir/r$n" "$workers" $((100000 + n)) "$@"
    done
else
    for ((l = 0; l < workers; l++)); do
        (
            n=0
            while [ $SECONDS -lt $end ]; do
                n=$((n + 1))
                round "$outdir/l${l}_$n" 1 $((100000 + l * 1000 + n)) "$@"
            done
        ) &
    done
    wait
fi
t1=$(date +%s.%N)
games=$(cat "$outdir"/*/g_*.jsonl 2>/dev/null | wc -l)
dec=$(cat "$outdir"/*/g_*.jsonl 2>/dev/null | grep -o '"dec":[0-9]*' | cut -d: -f2 | awk '{s += $1} END {print s + 0}')
awk -v m="$mode" -v w="$workers" -v g="$games" -v d="$dec" -v t0="$t0" -v t1="$t1" 'BEGIN {
    dt = t1 - t0
    printf "%s workers %d wall %.1fs games %d decisions %d | %.2f games/s %.3f games/s per worker %.0f decisions/s\n", m, w, dt, g, d, g / dt, g / dt / w, d / dt
}'
