#!/usr/bin/env bash
# Boot each server config, run h2load matrix, tear down.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Keep Julia threads consistent across versions
JULIA_T=8
PORT_V1=19601
PORT_V2_H1=19602
PORT_V2_H2=19603

start_server() {
  local proj="$1" port="$2" pidfile="$3" log="$4"
  julia -t $JULIA_T --project="$proj" bench/server.jl "$port" >"$log" 2>&1 &
  echo $! > "$pidfile"
  # Wait for READY line
  for i in $(seq 1 30); do
    if grep -q '^READY' "$log" 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "ERROR: server $proj never became READY (see $log)" >&2
  return 1
}

stop_server() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  fi
}

mkdir -p bench/results

# --- v1 (HTTP/1.1 only, no HTTP/2 server support in HTTP.jl 1.x) ---
echo "=== v1 ==="
start_server bench/v1 $PORT_V1 bench/results/v1.pid bench/results/v1.log
trap "stop_server bench/results/v1.pid; stop_server bench/results/v2.pid" EXIT
bash bench/run_bench.sh v1-h1 "http://127.0.0.1:$PORT_V1" --h1
stop_server bench/results/v1.pid

# --- v2 HTTP/1.1 ---
echo "=== v2 HTTP/1.1 ==="
start_server bench/v2 $PORT_V2_H1 bench/results/v2.pid bench/results/v2-h1.log
bash bench/run_bench.sh v2-h1 "http://127.0.0.1:$PORT_V2_H1" --h1
stop_server bench/results/v2.pid

# --- v2 HTTP/2 cleartext ---
echo "=== v2 HTTP/2 ==="
start_server bench/v2 $PORT_V2_H2 bench/results/v2.pid bench/results/v2-h2.log
bash bench/run_bench.sh v2-h2 "http://127.0.0.1:$PORT_V2_H2" ""
stop_server bench/results/v2.pid

trap - EXIT
echo "ALL DONE"
