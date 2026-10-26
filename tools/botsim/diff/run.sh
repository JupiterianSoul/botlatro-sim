#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE=${1:?usage: run.sh generate <runs.jsonl> <out_dir> [procs] | run.sh replay <out_dir> <log.jsonl>...}
shift
SECS="${BOTSIM_SECONDS:-1500}"

WORK="$(mktemp -d /tmp/botsim_diff.XXXXXX)"
trap 'pkill -f "love $WORK/game" 2>/dev/null; rm -rf "$WORK"' EXIT

rsync -a --delete --exclude 'multiplayer/node_modules' "$REPO/assets/" "$WORK/game/"
mv "$WORK/game/main.lua" "$WORK/game/game_main.lua"
cp "$HERE/recorder.lua" "$WORK/game/main.lua"
cp "$HERE/json.lua" "$WORK/game/botsim_json.lua"
cp "$REPO/tools/turbo/turbo.lua" "$WORK/game/turbo.lua"

launch() {
    local tag="$1" out="$2"
    shift 2
    local DATA="$WORK/data_$tag"
    mkdir -p "$DATA" "$out"
    echo "proc $tag: start $(date +%T)"
    env -u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null \
        NO_NAME_PROMPT=1 XDG_DATA_HOME="$DATA" MODLOADER_MAIN_ALIAS=game_main.lua MODLOADER_DOWNLOADS="$WORK/no_downloads" \
        TURBO="${BOTSIM_TURBO:-1}" BOTSIM_OUT="$out" BOTSIM_TAG="$tag" BOTSIM_SECONDS="$SECS" "$@" \
        timeout -k 10 $((SECS + 120)) \
        xvfb-run -a -s "-screen 0 1280x720x24" love "$WORK/game" > "$out/stdout_$tag.txt" 2>&1
    echo "proc $tag: exit $? $(date +%T)"
    grep -h "RUN_END\|ALL_DONE\|TIME_LIMIT\|FATAL_EXIT" "$out/recorder_$tag.log" 2>/dev/null | cut -c1-220 | tail -40
}

if [ "$MODE" = generate ]; then
    RUNS="$1" OUT="$2" PROCS="${3:-2}"
    mkdir -p "$OUT"
    n=$(grep -c . "$RUNS")
    for ((p = 0; p < PROCS; p++)); do
        awk -v p="$p" -v k="$PROCS" 'NF && (NR - 1) % k == p' "$RUNS" > "$WORK/runs_$p.jsonl"
        [ -s "$WORK/runs_$p.jsonl" ] || continue
        launch "gen$p" "$OUT" BOTSIM_MODE=generate BOTSIM_RUNS="$WORK/runs_$p.jsonl" BOTSIM_POLICY_SEED=$((p + 1)) &
    done
    wait
    echo "generate: $n runs requested, $(ls "$OUT"/*.snap.jsonl 2>/dev/null | wc -l) snapshot files"
elif [ "$MODE" = replay ]; then
    OUT="$1"
    shift
    launch replay "$OUT" BOTSIM_MODE=replay BOTSIM_LOGS="$*"
else
    echo "unknown mode $MODE"
    exit 2
fi
