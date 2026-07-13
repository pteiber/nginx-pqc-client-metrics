# NGINX PQC Client Metrics Demo

This repo demonstrates how to use NGINX to track client coverage and support for
Post-Quantum Cryptography (PQC) key exchange, and to monitor TLS session resumption.

NGINX exposes this data in ordinary variables on every connection (see NGINX's
[full list of TLS variables](https://nginx.org/en/docs/http/ngx_http_ssl_module.html#variables)).
These variables can be injected anywhere NGINX config allows them. This repo shows two ways to do
that: a custom TLS logging `log_format`, and TLS parameters injected into OpenTelemetry span
attributes (via the NGINX OTel module).

A complete Podman/Docker demo, including a Grafana dashboard, shows NGINX tracking TLS connection
metrics end to end.

![Grafana dashboard](dashboard.png)

## TLS Connection Variables

| NGINX variable | Span attribute | Meaning |
|---|---|---|
| `$ssl_protocol` | `tls.protocol` | Negotiated TLS version (`TLSv1.3`) |
| `$ssl_cipher` | `tls.cipher` | Negotiated cipher suite |
| `$ssl_curve` | `tls.curve` | Negotiated key exchange group |
| `$ssl_curves` | `tls.client_curves` | Full `supported_groups` the client offered |
| `$ssl_ciphers` | `tls.client_ciphers` | Full cipher list the client offered |
| `$ssl_session_id` | `tls.session_id` | TLS session identifier |
| `$ssl_session_reused` | `tls.session_reused` | `r` if session was resumed |
| `$ssl_server_name` | `tls.server_name` | SNI hostname |
| `$ssl_early_data` | `tls.early_data` | Whether 0-RTT data was used |
| `$hostname` | `nginx.server` | Which NGINX instance served the request |

## Reporting PQC Compatibility

`nginx.conf` shows two methods to collect and send the TLS metrics:

- **Custom access log** (`log_format json_combined`): every request is
  logged as one JSON line including `ssl_protocol`, `ssl_cipher`,
  `ssl_curve`, `tls_session_reused`, `nginx_server`, and `http_user_agent`.
  This log is ingested by Loki and powers the "NGINX PQC Client Coverage"
  Grafana dashboard.
- **OTel span attributes** (`otel_span_attr`): the same negotiation detail
  is attached to an OTel span and shipped to Tempo. These can be reviewed in Grafana's
  "Traces Drilldown" app.

Both read from the same underlying NGINX variables, populated the same way
regardless of which client connects. Detecting a client's PQC support
doesn't depend on the client cooperating beyond completing a normal TLS
1.3 handshake; NGINX reports on whatever actually happened on the wire, on
every connection, whether the client is PQC-aware or not.

## Session Resumption

A PQC (hybrid X25519MLKEM768) handshake is more expensive than classical
ECDHE, both in CPU and in bytes on the wire, so how often clients resume an
existing session instead of doing a full handshake directly affects the cost
of going post-quantum. NGINX reports this per connection via
`$ssl_session_reused` (`r` when the session was resumed, `.` otherwise). In
TLS 1.3 resumption is ticket/PSK-based; the classical TLS 1.2 session-ID cache
does not apply to this TLS-1.3-only server.

The server enables resumption explicitly (`ssl_session_cache`,
`ssl_session_tickets`, and a shared `ssl_session_ticket_key` so any worker can
decrypt any worker's ticket). The raw `$ssl_session_reused` value is emitted
both in the access log (`tls_session_reused`) and as the `tls.session_reused`
span attribute, alongside `nginx_server` / `nginx.server` (`$hostname`) so
resumption can be broken down by NGINX instance. The `r`/`.` value is mapped to
`Full`/`None` in the Grafana dashboard, and left raw in the span so a
trace/APM backend can remap it on its side.

The dashboard visualizes this with an overall reuse percentage gauge, reuse
counts broken down by NGINX server and by client IP, and a per-client-IP reuse
percentage so resumption effectiveness is directly comparable across clients.

To make resumption observable, two clients reuse sessions across their looped
requests: `go-dual-share` (via a Go `ClientSessionCache`) and `openssl-35-dual`
(via `s_client -sess_out` / `-sess_in` to a persisted session file). The other
clients always full-handshake, giving the dashboard a real reused-vs-full mix.
The `curl-pq` / `curl-classic` clients are intentionally not converted: curl
keeps a TLS session cache only within a single process, and each loop iteration
is a fresh `curl` invocation, so cross-request resumption is not possible from
the curl CLI here without a contrived single-invocation trick.

## Fine-grained observability at scale

This demo shows single-instance snapshots, but every stat here is derived from
per-connection data that NGINX already tags with several dimensions on every
log line and span: NGINX instance (`nginx_server` / `nginx.server`), client IP
(`remote_addr`), request URI (`uri`), user agent, and the negotiated curve,
cipher, and resumption state. Any of these metrics (PQC adoption, curve mix,
session reuse rate, and so on) can therefore be sliced by any of those
dimensions with a `sum by (...)` in LogQL or an equivalent grouping in a
trace/APM backend, and trended over time from the same data (for example
`count_over_time(... [5m])` per step for a moving rate).

In a large environment that means an operator can answer questions like "which
servers or client subnets have low session reuse", "how is PQC adoption
trending on this endpoint", or "which clients still fall back to classical
ECDHE", down to a single server, IP, or URI, without changing what NGINX
collects. The dashboard panels here are deliberately simple snapshots; the
underlying data supports much finer breakdowns and historical trends when the
scale of the deployment makes them worthwhile.

## Demo

Seven client containers repeatedly connect to NGINX with different TLS
configurations: some negotiate the hybrid PQC group, some fall back to
classical ECDHE, one deliberately triggers a HelloRetryRequest, and one is
capped at TLS 1.2 to demonstrate a failed handshake. Bring up the stack and
watch the dashboard fill in as NGINX reports what each client actually
negotiated.

### Prerequisites

- `podman-compose` or another container runtime. Podman on macOS tested.

### Deploying

```bash
cp .env.example .env   # edit HOST_HTTPS_PORT if needed

podman compose build
podman compose up -d
podman compose ps
```

### Verifying TLS Negotiation

```bash
curl -sk https://localhost:${HOST_HTTPS_PORT:-8443}/handshake-info | jq .
# Expected: {"ssl_protocol":"TLSv1.3","ssl_cipher":"TLS_AES_256_GCM_SHA384","ssl_curve":"X25519MLKEM768"}
```

### Viewing the Dashboard

Open <http://localhost:3000> in your browser of choice.

### Environment Variables

All clients respect:

| Variable | Default | Description |
|----------|---------|-------------|
| `SERVER_HOST` | `nginx` | NGINX service DNS (the compose service name) |
| `MIN_INTERVAL_SECONDS` | `5` | Minimum seconds between connection attempts |
| `MAX_INTERVAL_SECONDS` | `15` | Maximum seconds between connection attempts |

See `.env.example` for the compose-level variables (`HOST_HTTPS_PORT`).
