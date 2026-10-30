#!/bin/bash
A="who=net weights=tools/botsim/ci_nets/big60kvw.bnnw sims=32 fair=1 search_ph=shop,pack,blind_select quick_clear=1 pace=1.25 prefix=BENCH first=1 seeds=6 decks=b_red,b_anaglyph stakes=1,5"
luajit tools/botsim/train/eval.lua $A jsonl=$OUT/a.jsonl > $OUT/a.txt 2>&1
luajit tools/botsim/train/eval.lua $A jsonl=$OUT/b.jsonl rec=$OUT/r.bspr > $OUT/b.txt 2>&1
sed 's/"time":[0-9.]*,//' $OUT/a.jsonl > $OUT/a2
sed 's/"time":[0-9.]*,//' $OUT/b.jsonl > $OUT/b2
if cmp -s $OUT/a2 $OUT/b2; then echo "rec check: identical $(wc -l < $OUT/a2) games" > $OUT/result.txt; else echo "rec check: DIFF" > $OUT/result.txt; diff $OUT/a2 $OUT/b2 >> $OUT/result.txt; fi
ls -l $OUT/r.bspr >> $OUT/result.txt
