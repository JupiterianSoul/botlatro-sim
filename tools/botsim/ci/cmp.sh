#!/bin/bash
B=$1/g; g=$2/g; a=$3; bl=${4:-b3}
H=$(cd "$(dirname "$0")" && pwd)
G="$H/../train/games.py"
rm -rf $g/_all8_$a $g/_all1_$a $B/_all8_$bl $B/_all1_$bl; mkdir -p $g/_all8_$a $g/_all1_$a $B/_all8_$bl $B/_all1_$bl
for d in red blue black; do
  [ -d $g/$a-$d ] && python3 -I $G cmp $B/$bl-$d $g/$a-$d | sed "s/^[^ ]*/$a-$d/" && cp -r $g/$a-$d $g/_all8_$a/ && cp -r $B/$bl-$d $B/_all8_$bl/
  [ -d $g/${a}1-$d ] && python3 -I $G cmp $B/${bl}1-$d $g/${a}1-$d | sed "s/^[^ ]*/${a}1-$d/" && cp -r $g/${a}1-$d $g/_all1_$a/ && cp -r $B/${bl}1-$d $B/_all1_$bl/
done
[ "$(ls $g/_all8_$a)" ] && python3 -I $G cmp $B/_all8_$bl $g/_all8_$a | sed "s/^[^ ]*/$a-all/"
[ "$(ls $g/_all1_$a)" ] && python3 -I $G cmp $B/_all1_$bl $g/_all1_$a | sed "s/^[^ ]*/${a}1-all/"
true
