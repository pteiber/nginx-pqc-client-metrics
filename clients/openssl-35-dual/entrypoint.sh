#!/bin/sh
HOST="${SERVER_HOST:-nginx}"
MIN_INTERVAL="${MIN_INTERVAL_SECONDS:-5}"
MAX_INTERVAL="${MAX_INTERVAL_SECONDS:-15}"
USER_AGENT="openssl-35-dual"

# Fixed path (not a per-iteration mktemp) so the captured TLS session persists
# across loop iterations. -sess_in replays it as a PSK so nginx reports the
# connection as reused: resuming a hybrid-PQC handshake avoids exactly the
# expensive full key exchange this demo is about. The file lives in the
# container's writable /tmp and resets on restart (first request after a
# restart is then a full handshake, which is expected).
SESS_FILE=/tmp/openssl-35-dual.sess

# Capture a fresh session ticket on a SEPARATE, untimed connection.
#
# The TLS 1.3 NewSessionTicket is a post-handshake message: the server sends it
# shortly after the handshake completes, so s_client has to stay on the
# connection to receive it before -sess_out can write it. The trailing "sleep"
# holds s_client's stdin open long enough for the ticket to arrive (without it,
# stdin hits EOF the instant the request is sent, s_client closes, and -sess_out
# writes nothing, so reuse silently never happens). That wait is why capture is
# kept OUT of the timed request below: folding it in would add ~1s to every
# latency_ms sample and make resumption look slower than a full handshake, the
# opposite of the truth. As always in this repo, printf is piped straight into
# s_client; never capture it in a variable ($(...) strips the trailing CRLF
# that terminates the HTTP headers).
capture_session() {
  { printf 'GET /handshake-info HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nConnection: close\r\n\r\n' "$HOST" "$USER_AGENT"; sleep 1; } \
    | openssl s_client -connect "${HOST}:443" -groups "X25519MLKEM768:X25519" -tls1_3 -sess_out "$SESS_FILE" >/dev/null 2>&1 || true
}

while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # BusyBox date has no sub-second precision (%N is not expanded);
  # /proc/uptime gives centisecond resolution instead.
  START=$(awk '{print $1}' /proc/uptime)

  # -groups lists X25519MLKEM768 first: s_client sends a key_share
  # only for the first group, so the server (which accepts
  # X25519MLKEM768) negotiates it directly with no HRR round trip.
  # -tls1_3 alone restricts to TLS 1.3; combining it with
  # -no_ssl3/-no_tls1/etc is rejected by OpenSSL 3.6 ("Cannot
  # supply both a protocol flag and '-no_<prot>'").
  # No -insecure: that's a curl flag, not an s_client one. s_client
  # already treats verification failures as non-fatal by default.
  # Piping via a variable ($(...)) would strip the trailing blank
  # line that terminates the HTTP headers (command substitution
  # drops trailing newlines), leaving nginx waiting on an incomplete
  # request; piping printf's output directly avoids that.
  #
  # Resume from a previously captured ticket when one exists (-sess_in). No
  # -sess_out here: refreshing the ticket needs the connection held open (see
  # capture_session), which would pollute the latency measurement. A single
  # ticket resumes many times, and the recapture-on-miss below refreshes it
  # when it eventually expires. First iteration has no file, so it is a genuine
  # full handshake with an honest latency sample.
  if [ -f "$SESS_FILE" ]; then
    SESS_ARGS="-sess_in $SESS_FILE"
  else
    SESS_ARGS=""
  fi

  OUTPUT=$(printf 'GET /handshake-info HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nConnection: close\r\n\r\n' "$HOST" "$USER_AGENT" | openssl s_client \
    -connect "${HOST}:443" \
    -groups "X25519MLKEM768:X25519" \
    -tls1_3 \
    $SESS_ARGS \
    -msg 2>&1 || true)

  END=$(awk '{print $1}' /proc/uptime)
  LATENCY=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.0f", (e-s)*1000}')

  # Refresh the ticket for the next iteration whenever this handshake was not
  # reused: either the first run (no file yet) or a ticket that expired and
  # made the server fall back to a full handshake. s_client prints "Reused,"
  # on a resumed session and "New," on a full one. Capture is untimed so it
  # never affects the latency logged above.
  if ! echo "$OUTPUT" | grep -q "Reused, TLSv1.3"; then
    capture_session
  fi

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

  printf '{"client":"openssl-35-dual","ts":"%s","curve":"%s","hrr":%s,"latency_ms":%d,"error":%s}\n' \
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
