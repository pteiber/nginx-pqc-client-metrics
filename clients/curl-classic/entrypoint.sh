#!/bin/sh
HOST="${SERVER_HOST:-nginx}"
MIN_INTERVAL="${MIN_INTERVAL_SECONDS:-5}"
MAX_INTERVAL="${MAX_INTERVAL_SECONDS:-15}"
while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  BODY_FILE=$(mktemp)

  # --ipv4 avoids the ~1s AAAA-lookup-timeout-then-fallback stall
  # that otherwise inflates time_appconnect in IPv6-less clusters.
  # Single request captures body + timing together (was two).
  VERBOSE=$(curl -sk \
    --ipv4 \
    --curves "X25519" \
    --tlsv1.3 --tls-max 1.3 \
    --verbose \
    --write-out 'CURL_METRICS:%{time_appconnect}\n' \
    -o "$BODY_FILE" \
    "https://${HOST}/handshake-info" 2>&1 || true)

  BODY=$(cat "$BODY_FILE" 2>/dev/null || echo "{}")
  rm -f "$BODY_FILE"

  CURVE_FROM_BODY=$(echo "$BODY" | grep -o '"ssl_curve":"[^"]*"' | sed 's/"ssl_curve":"//;s/"//' || echo "")
  CURVE_FROM_VERBOSE=$(echo "$VERBOSE" | grep -i 'SSL connection using' | grep -o '[A-Za-z0-9_]*$' | head -1 || echo "")
  CURVE="${CURVE_FROM_BODY:-${CURVE_FROM_VERBOSE:-unknown}}"

  LATENCY=$(echo "$VERBOSE" | grep 'CURL_METRICS:' | tail -1 | cut -d: -f2)
  LATENCY_MS=$(awk "BEGIN {printf \"%.2f\", ${LATENCY:-0} * 1000}" 2>/dev/null || echo "0")

  HRR="false"
  if echo "$VERBOSE" | grep -qi "HelloRetryRequest"; then
    HRR="true"
  fi

  ERR_RAW=$(echo "$VERBOSE" | grep -i "curl:.*error\|failed" | head -1 | tr '"' "'" || true)
  if [ -n "$ERR_RAW" ]; then
    ERR_FIELD="\"${ERR_RAW}\""
  else
    ERR_FIELD="null"
  fi

  printf '{"client":"curl-classic","ts":"%s","curve":"%s","hrr":%s,"latency_ms":%s,"error":%s}\n' \
    "$TS" "$CURVE" "$HRR" "$LATENCY_MS" "$ERR_FIELD"

  # Random 5-15s delay, seeded per-container (hostname = container
  # name under podman) mixed with wall-clock time: plain time-only
  # seeding would give simultaneously-started containers the same
  # first sleep (verified: srand() alone collides within the same
  # second). Kept even at a single instance per client in case this
  # is later scaled via `podman compose up --scale <client>=N`.
  SEED=$(( $(date +%s) + $(hostname | cksum | cut -d' ' -f1) ))
  sleep "$(awk -v seed="$SEED" -v min="$MIN_INTERVAL" -v max="$MAX_INTERVAL" 'BEGIN{srand(seed); print int(min+rand()*(max-min+1))}')"
done
