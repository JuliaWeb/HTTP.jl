#!/usr/bin/env bash
# Run a profile capture for one (version, endpoint, protocol) cell.
# Args: $1=version (v1|v2), $2=endpoint (tiny|json|large), $3=h2load proto flag
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$1"; ENDPOINT="$2"; PROTO="${3:-}"
LABEL="$VERSION-$([ -z "$PROTO" ] && echo h2 || echo h1)-$ENDPOINT"
PORT=$((19700 + RANDOM % 100))
PROF_OUT="bench/results/profile_${LABEL}.txt"
LOG="bench/results/profile_${LABEL}.log"
PID_FILE="bench/results/profile_${LABEL}.pid"

mkdir -p bench/results

echo "=== $LABEL on :$PORT ==="
julia -t 8 --project="bench/$VERSION" bench/profile_server.jl "$PORT" "$PROF_OUT" 25 >"$LOG" 2>&1 &
echo $! > "$PID_FILE"

# wait READY
for i in $(seq 1 30); do
  grep -q '^READY' "$LOG" 2>/dev/null && break
  sleep 1
done

# warmup
h2load -n 5000 -c 16 -t 2 $PROTO "http://127.0.0.1:$PORT/$ENDPOINT" > /dev/null 2>&1 || true

# kick off h2load in background
h2load -n 100000 -c 64 -t 4 $PROTO "http://127.0.0.1:$PORT/$ENDPOINT" > "${PROF_OUT%.txt}.h2load.txt" 2>&1 &
LOAD_PID=$!

# small head start so the load is steady-state when profiling starts
sleep 1

# signal profile to start
touch "${PROF_OUT}.begin"

# wait for h2load to finish (or profile window to elapse)
wait $LOAD_PID 2>/dev/null || true

# wait for server to write profile and exit
for i in $(seq 1 30); do
  grep -q 'WROTE' "$LOG" 2>/dev/null && break
  sleep 1
done

# cleanup
kill "$(cat $PID_FILE)" 2>/dev/null || true
wait 2>/dev/null || true
rm -f "${PROF_OUT}.begin" "$PID_FILE"
echo "  -> $PROF_OUT (and ${PROF_OUT%.txt}.h2load.txt)"
