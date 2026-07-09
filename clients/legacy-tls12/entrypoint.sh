#!/bin/sh
HOST="${SERVER_HOST:-nginx}"
MIN_INTERVAL="${MIN_INTERVAL_SECONDS:-5}"
MAX_INTERVAL="${MAX_INTERVAL_SECONDS:-15}"
while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  START=$(awk '{print $1}' /proc/uptime)

  # --tls-max 1.2 forces a ClientHello with no TLS 1.3
  # supported_versions entry; the server has no overlapping
  # protocol version and rejects the handshake outright.
  # -sS: silent progress meter but keep error messages (-s alone
  # also silences errors, which is why the earlier attempt at
  # this client always logged an empty error string).
  OUTPUT=$(curl -sSk \
    --tlsv1.2 --tls-max 1.2 \
    "https://${HOST}/handshake-info" 2>&1)
  CURL_EXIT=$?

  END=$(awk '{print $1}' /proc/uptime)
  LATENCY=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.0f", (e-s)*1000}')

  if [ "$CURL_EXIT" -eq 0 ]; then
    ERR_FIELD="null"
  else
    ERR_RAW=$(echo "$OUTPUT" | tr '"' "'" | tr '\n' ' ' | sed 's/  *$//')
    ERR_FIELD="\"${ERR_RAW}\""
  fi

  # curve stays "unknown": no TLS 1.3 handshake ever completes,
  # so there's never a negotiated group to report. This also
  # keeps this client excluded from the curve-negotiation panels
  # (which filter out curve == "unknown"), same convention used
  # by the other clients on a failed/unparsed attempt.
  printf '{"client":"legacy-tls12","ts":"%s","curve":"unknown","hrr":false,"latency_ms":%s,"error":%s}\n' \
    "$TS" "$LATENCY" "$ERR_FIELD"

  # Random 5-15s delay, seeded per-container (hostname = container
  # name under podman) mixed with wall-clock time: plain time-only
  # seeding would give simultaneously-started containers the same
  # first sleep (verified: srand() alone collides within the same
  # second). Kept even at a single instance per client in case this
  # is later scaled via `podman compose up --scale <client>=N`.
  SEED=$(( $(date +%s) + $(hostname | cksum | cut -d' ' -f1) ))
  sleep "$(awk -v seed="$SEED" -v min="$MIN_INTERVAL" -v max="$MAX_INTERVAL" 'BEGIN{srand(seed); print int(min+rand()*(max-min+1))}')"
done
