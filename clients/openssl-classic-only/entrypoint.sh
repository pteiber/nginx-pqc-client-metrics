#!/bin/sh
HOST="${SERVER_HOST:-nginx}"
MIN_INTERVAL="${MIN_INTERVAL_SECONDS:-5}"
MAX_INTERVAL="${MAX_INTERVAL_SECONDS:-15}"
USER_AGENT="openssl-classic-only"
while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # BusyBox date has no sub-second precision (%N is not expanded);
  # /proc/uptime gives centisecond resolution instead.
  START=$(awk '{print $1}' /proc/uptime)

  # Classical groups only, no PQC key shares.
  # -tls1_3 alone restricts to TLS 1.3; combining it with
  # -no_ssl3/-no_tls1/etc is rejected by OpenSSL 3.6 ("Cannot
  # supply both a protocol flag and '-no_<prot>'").
  # No -insecure: that's a curl flag, not an s_client one. s_client
  # already treats verification failures as non-fatal by default.
  # Piping via a variable ($(...)) would strip the trailing blank
  # line that terminates the HTTP headers (command substitution
  # drops trailing newlines), leaving nginx waiting on an incomplete
  # request; piping printf's output directly avoids that.
  OUTPUT=$(printf 'GET /handshake-info HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nConnection: close\r\n\r\n' "$HOST" "$USER_AGENT" | openssl s_client \
    -connect "${HOST}:443" \
    -groups "X25519:P-256" \
    -tls1_3 \
    -msg 2>&1 || true)

  END=$(awk '{print $1}' /proc/uptime)
  LATENCY=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.0f", (e-s)*1000}')

  # Hybrid/PQC groups print "Negotiated TLS1.3 group: <name>";
  # classical ECDHE groups instead print "Peer Temp Key: <name>, N bits".
  CURVE=$(echo "$OUTPUT" | grep -o 'Negotiated TLS1.3 group:.*' | sed 's/Negotiated TLS1.3 group: //' | tr -d ' \r')
  if [ -z "$CURVE" ]; then
    CURVE=$(echo "$OUTPUT" | grep -o 'Peer Temp Key:[^,]*' | sed 's/Peer Temp Key: //' | tr -d ' \r')
  fi
  if [ -z "$CURVE" ]; then
    CURVE="unknown"
  fi

  # A single handshake has exactly one ClientHello; HRR (a
  # server-requested retry) produces two. Not expected for this
  # client (its first-listed group is server-acceptable), but
  # detected accurately in case the server ever requests otherwise.
  CLIENTHELLO_COUNT=$(echo "$OUTPUT" | grep -c "Handshake \[length [0-9a-f]*\], ClientHello")
  HRR="false"
  if [ "$CLIENTHELLO_COUNT" -gt 1 ]; then
    HRR="true"
  fi

  # "verify error: self-signed certificate" is expected on every
  # successful run and is not fatal; s_client prints DONE on a
  # clean session close, which is the reliable success signal.
  if echo "$OUTPUT" | grep -q "^DONE$"; then
    ERR_FIELD="null"
  else
    ERR_RAW=$(echo "$OUTPUT" | tail -1 | tr '"' "'")
    ERR_FIELD="\"${ERR_RAW}\""
  fi

  printf '{"client":"openssl-classic-only","ts":"%s","curve":"%s","hrr":%s,"latency_ms":%d,"error":%s}\n' \
    "$TS" "$CURVE" "$HRR" "$LATENCY" "$ERR_FIELD"

  # Random 5-15s delay, seeded per-container (hostname = container
  # name under podman) mixed with wall-clock time: plain time-only
  # seeding would give simultaneously-started containers the same
  # first sleep (verified: srand() alone collides within the same
  # second). Kept even at a single instance per client in case this
  # is later scaled via `podman compose up --scale <client>=N`.
  SEED=$(( $(date +%s) + $(hostname | cksum | cut -d' ' -f1) ))
  sleep "$(awk -v seed="$SEED" -v min="$MIN_INTERVAL" -v max="$MAX_INTERVAL" 'BEGIN{srand(seed); print int(min+rand()*(max-min+1))}')"
done
