#!/usr/bin/env bash
# Corpus run with tag $TAG; DataStructures traces unknown calls and alias demotions in named methods.
set -u
cd "$(dirname "$0")"
for pkg in Distances DataStructures JSON; do
  trace=""; [ "$pkg" = DataStructures ] && trace="promote,DefaultDictBase,_,DefaultDict,copyto!,PriorityQueue,SortedDict,setindex!"
  S5_TRACE_UNKNOWN="$trace" S5_TAG="$TAG" JULIA_NUM_THREADS=1 timeout 1800 julia --project=. \
    -e 'include("corpus.jl"); println("maxrss_MB=", Sys.maxrss() ÷ 2^20)' "$pkg" > "results/$pkg-$TAG.log" 2>&1 &
done
wait
echo "== DONE"
