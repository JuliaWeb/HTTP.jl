#!/bin/zsh
# Run the WS bench suite under both HTTP.jl versions, N trials each.
#   ./run_baseline.sh [trials] [scale]
set -e
cd "$(dirname "$0")"
TRIALS=${1:-3}
SCALE=${2:-1.0}
JULIA=~/.juliaup/bin/julialauncher
V2_PROJ=../..                 # the ws-perf worktree (dev HTTP + dev Reseau)
V1_PROJ=/tmp/ws_bench_http1   # pinned HTTP 1.11.0
mkdir -p results
for trial in $(seq 1 $TRIALS); do
  for v in v2 v1; do
    proj=$([ $v = v2 ] && echo $V2_PROJ || echo $V1_PROJ)
    out=results/${v}_trial${trial}.txt
    echo "── $v trial $trial → $out"
    WSBENCH_PORT=$((9143 + trial * 20)) $JULIA -t 4 --project=$proj ws_bench.jl $SCALE 2>&1 | tee $out | grep -E "^#|^RESULT" || true
  done
done
echo "done — results/ ready for compare.jl"
