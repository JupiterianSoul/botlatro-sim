#!/bin/bash
key() { for r in "$@"; do gh run view $r -R JupiterianSoul/botlatro-sim --json jobs --jq '[.jobs[]|select(.status=="completed")]|length'; done | tr '\n' ' '; }
max=$1; shift; k0=$(key "$@"); t=0
while [ $t -lt $max ]; do sleep 60; t=$((t+60)); k=$(key "$@"); [ "$k" != "$k0" ] && break; done
echo "$k0 -> $k after $t s"; date -u +%H:%M
