#!/usr/bin/env bash
# Run S5 corpus in both modes, one Julia process at a time.
set -u
cd "$(dirname "$0")"
mkdir -p results
for pkg in Distances DataStructures JSON; do
  for standin in 0 1; do
    S5_STANDIN=$standin JULIA_NUM_THREADS=2 timeout 1800 julia +1.13 --project=. \
      -e 'include("corpus.jl"); println("maxrss_MB=", Sys.maxrss() ÷ 2^20)' "$pkg" > "results/$pkg-$standin.log" 2>&1
    echo "$pkg standin=$standin exit=$?"
  done
done
