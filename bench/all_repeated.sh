#!/usr/bin/env bash
# Run the full matrix N times and aggregate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNS=3
mkdir -p bench/results
for i in $(seq 1 $RUNS); do
  echo "######## RUN $i / $RUNS ########"
  rm -rf bench/results/v1-h1 bench/results/v2-h1 bench/results/v2-h2
  bash bench/all.sh 2>&1 | tail -1
  for label in v1-h1 v2-h1 v2-h2; do
    cp -r "bench/results/$label" "bench/results/${label}_run${i}"
  done
done
echo "All runs done"
