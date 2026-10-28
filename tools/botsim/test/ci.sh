#!/usr/bin/env bash
out=${1:-sim-test.txt}
luajit tools/botsim/test/run.lua > "$out" 2>&1
status=$?
if [ "$status" -eq 0 ] && [ -f tools/botsim/c/libbotsim.so ]; then
    luajit tools/botsim/fuzz_scan.lua n=200 >> "$out" 2>&1
    status=$?
fi
grep -E '^FAIL' "$out"
tail -n 3 "$out"
if [ "$status" -ne 0 ] || grep -q '^FAIL' "$out"; then
    exit 1
fi
