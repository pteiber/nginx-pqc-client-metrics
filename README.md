# NGINX PQC Client Metrics Demo

This repo demonstrates how to use NGINX to track client coverage and support for
Post-Quantum Cryptography (PQC) key exchange.

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

## Reporting PQC Compatibility

`nginx.conf` shows two methods to collect and send the TLS metrics:

- **Custom access log** (`log_format json_combined`): every request is
  logged as one JSON line including `ssl_protocol`, `ssl_cipher`,
  `ssl_curve`, and `http_user_agent`. This log is ingested by Loki and powers the
  "NGINX PQC Client Coverage" Grafana dashboard.
- **OTel span attributes** (`otel_span_attr`): the same negotiation detail
  is attached to an OTel span and shipped to Tempo. These can be reviewed in Grafana's
  "Traces Drilldown" app.

Both read from the same underlying NGINX variables, populated the same way
regardless of which client connects. Detecting a client's PQC support
doesn't depend on the client cooperating beyond completing a normal TLS
1.3 handshake; NGINX reports on whatever actually happened on the wire, on
every connection, whether the client is PQC-aware or not.

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
