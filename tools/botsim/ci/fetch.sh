#!/bin/bash
run=$1; dir=$2
cd "$dir" || exit 1
for j in $(gh run view $run -R JupiterianSoul/botlatro-sim --json jobs -q '.jobs[]|select(.status=="completed" and .conclusion=="success")|.name'); do
  [ "$j" = plan ] && continue
  [ -d bench-$j ] || gh run download $run -R JupiterianSoul/botlatro-sim -n bench-$j -D bench-$j >/dev/null 2>&1 || echo fail $j
done
echo left $(gh run view $run -R JupiterianSoul/botlatro-sim --json jobs -q '[.jobs[]|select(.status!="completed")]|length')
