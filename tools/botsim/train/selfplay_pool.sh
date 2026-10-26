#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
usage: $0 [-w workers] [-o outdir] [-r runs_per_file] [-k keep_per_worker] [-n files_per_worker] [-s seed] [-c first_cpu] [-t teacher] [-- selfplay args]

Runs one self-play process per core. Each worker writes complete .bspr files named w<worker>_<index>.bspr
into outdir (written as .part, renamed when done, so a reader never sees half a file) and keeps only its
newest keep_per_worker files. -n 0 runs until stopped (Ctrl+C or SIGTERM stops every worker).
-c pins worker i to cpu first_cpu+i (-c -1 leaves pinning to the OS). -t 1 runs the greedy teacher instead.

defaults: workers=\$(nproc) outdir=tools/botsim/train/out/pool runs=50 keep=20 files=0 seed=1 cpu=0 teacher=0
example:  $0 -w 8 -o /data/gen3 -r 100 -k 50 -- weights=gen2.bnnw sims=64 adaptive=1 conf=0.9 fast_sims=16 full_frac=0.25
EOF
}

workers=$(nproc)
outdir=tools/botsim/train/out/pool
runs=50
keep=20
files=0
seed=1
cpu=0
teacher=0
while getopts "w:o:r:k:n:s:c:t:h" opt; do
    case $opt in
        w) workers=$OPTARG ;;
        o) outdir=$OPTARG ;;
        r) runs=$OPTARG ;;
        k) keep=$OPTARG ;;
        n) files=$OPTARG ;;
        s) seed=$OPTARG ;;
        c) cpu=$OPTARG ;;
        t) teacher=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[ "${1:-}" = "--" ] && shift

root=$(cd "$(dirname "$0")/../../.." && pwd)
script=tools/botsim/train/selfplay.lua
[ "$teacher" = "1" ] && script=tools/botsim/train/teacher.lua
mkdir -p "$outdir"
outdir=$(cd "$outdir" && pwd)

worker() {
    local w=$1
    shift
    local i=0
    local last
    last=$(ls -1 "$outdir"/w"${w}"_*.bspr 2>/dev/null | sed 's/.*_\([0-9]*\)\.bspr$/\1/' | sort -n | tail -1 || true)
    [ -n "$last" ] && i=$((10#$last + 1))
    local pin=()
    [ "$cpu" -ge 0 ] && pin=(taskset -c $((cpu + w)))
    while [ "$files" -eq 0 ] || [ "$i" -lt "$files" ]; do
        local name
        name=$(printf "w%d_%06d" "$w" "$i")
        local tmp="$outdir/.$name.part"
        (cd "$root" && nice -n 19 "${pin[@]}" luajit "$script" runs="$runs" seed=$((seed * 1000 + w)) first=$((i * runs + 1)) \
            out="$tmp" quiet=2 "$@") >> "$outdir/w$w.log" 2>&1
        mv "$tmp" "$outdir/$name.bspr"
        ls -1 "$outdir"/w"${w}"_*.bspr | sort | head -n -"$keep" | xargs -r rm -f
        i=$((i + 1))
    done
}

pids=()
stop() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    pkill -f "out=$outdir/\.w" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -f "$outdir"/.w*.part
    exit 130
}
trap stop INT TERM

for ((w = 0; w < workers; w++)); do
    worker "$w" "$@" &
    pids+=($!)
done
echo "started $workers workers writing to $outdir"
wait
grep -h "decisions/s" "$outdir"/w*.log | tail -n "$workers"
