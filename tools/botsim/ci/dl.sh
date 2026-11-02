#!/bin/bash
R=$1; D=$2; mkdir -p $D
H=$(cd "$(dirname "$0")" && pwd)
cd "$H/../../.."
for n in $(gh api "repos/{owner}/{repo}/actions/runs/$R/artifacts?per_page=100" --jq '.artifacts[].name'); do
  [ -d $D/$n ] || timeout 60 gh run download $R -n $n -D $D/$n >/dev/null 2>&1
done
rm -rf $D/g; python3 -I "$H/grp.py" $D
ls $D | grep -c bench
