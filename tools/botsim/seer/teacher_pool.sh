#!/usr/bin/env bash
set -u
: "${OUT_DIR:?}" "${GAMES:?}" "${SEED:?}" "${WORKERS:?}" "${STAKE:=1}"
decks=(b_red b_blue b_yellow b_green b_black b_magic b_nebula b_ghost b_abandoned b_checkered b_zodiac b_painted b_anaglyph b_plasma b_erratic)
per=$(( (GAMES + WORKERS - 1) / WORKERS ))
pids=()
trap 'kill "${pids[@]}" 2>/dev/null; rm -f "$OUT_DIR"/*.part; exit 143' TERM INT
for ((w = 0; w < WORKERS; w++)); do
    deck=${decks[$(( (SEED + w) % ${#decks[@]} ))]}
    (
        luajit tools/botsim/seer/teacher.lua --seeds="$per" --decks="$deck" --stakes="$STAKE" \
            --prefix="T${SEED}W${w}S" ${SEER_ARGS:-} --out="$OUT_DIR/seer_$w.part" >/dev/null &&
            mv "$OUT_DIR/seer_$w.part" "$OUT_DIR/seer_$w.bspr"
    ) &
    pids+=($!)
done
wait
