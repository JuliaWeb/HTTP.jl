#!/usr/bin/env bash
# Run h2load matrix against a single server.
#
# Args:
#   $1 = label  (e.g. "v1-h1", "v2-h1", "v2-h2")
#   $2 = base url (e.g. http://127.0.0.1:19501)
#   $3 = h2load extra flag ("--h1" for HTTP/1.1; "" for HTTP/2 cleartext default)
set -euo pipefail
LABEL="$1"; BASE="$2"; PROTO_FLAG="${3:-}"

REQUESTS=100000
RESULTS_DIR="bench/results/$LABEL"
mkdir -p "$RESULTS_DIR"

# Warmup (~5k requests, discard results) to let the JIT settle
echo "warmup $LABEL ..."
h2load -n 5000 -c 16 -t 2 $PROTO_FLAG "$BASE/json" > /dev/null 2>&1 || true

for ENDPOINT in tiny json large; do
  for CONC in 1 64 512; do
    # h2load thread count: cap at 8 hardware threads, scale with concurrency
    if   [[ "$CONC" -le 1   ]]; then THREADS=1
    elif [[ "$CONC" -le 64  ]]; then THREADS=4
    else THREADS=8
    fi

    # For c=1, h2load issues 1 in-flight request per connection.
    # For HTTP/2 we let h2load bump max-concurrent-streams. For HTTP/1.1 c=1 means c=1.
    # To get useful numbers at c=1 with HTTP/2, we leave h2load defaults
    # (which limit concurrent streams to 1 unless -m is used). To keep
    # apples-to-apples with HTTP/1.1, leave -m at default for both.

    OUT="$RESULTS_DIR/${ENDPOINT}_c${CONC}.txt"
    echo ">>> $LABEL $ENDPOINT c=$CONC t=$THREADS"
    h2load -n $REQUESTS -c $CONC -t $THREADS $PROTO_FLAG "$BASE/$ENDPOINT" > "$OUT" 2>&1 \
      || echo "    (h2load nonzero exit, output kept at $OUT)"
  done
done
echo "done $LABEL -> $RESULTS_DIR"
