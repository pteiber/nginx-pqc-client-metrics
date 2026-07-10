# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A demo showing NGINX's ability to detect and report per-client TLS 1.3 post-quantum-crypto
(PQC) key exchange support: which clients negotiate the hybrid `X25519MLKEM768` group versus
falling back to classical ECDHE. NGINX reports this via a custom JSON access log and OTel
span attributes, visualized in a provisioned Grafana dashboard. The whole stack runs through
`podman compose`, no Kubernetes, despite some residual naming from an earlier K3s-based
version of this demo (`namespace="pqc-demo"` as a Loki label, "pod IP" in one panel title).

## Commands

- `podman compose build` (or `build nginx` / `build go-dual-share` to build just those two;
  every other service pulls a public image, nothing else to build)
- `cp .env.example .env` then `podman compose up -d`
- `podman compose ps`, `podman compose logs -f <service>`, `podman compose down`
- `podman exec nginx nginx -t`: validate `nginx.conf` syntax after editing it
- `sh -n clients/<name>/entrypoint.sh`: syntax-check a client script after editing it

No test suite, no linter, no CI config exists in this repo. Verification is manual/live:

- `curl -sk https://localhost:${HOST_HTTPS_PORT:-8443}/handshake-info | jq .`
- `curl -s "http://localhost:3100/loki/api/v1/query?query=<url-encoded LogQL>"` to test a LogQL
  expression directly against Loki before putting it in a dashboard panel
- `curl -s "http://localhost:3200/api/search?tags="` to check traces are landing in Tempo
- `curl -s http://localhost:3000/api/dashboards/uid/pqc-tls-demo` to confirm Grafana picked up
  a dashboard JSON change

**podman-compose quirk:** `podman compose up -d --force-recreate <single-service>` can tear
down *dependent* containers along with the network instead of cleanly recreating just the
target. After doing this, run a plain `podman compose up -d` (no args) to bring the rest of
the stack back, and check `podman ps` rather than assuming the single-service recreate left
everything else untouched.

## Architecture

1. `nginx.conf` is the single source of truth for the server: TLS group preference
   (`ssl_conf_command Groups "X25519MLKEM768:X25519:P-256"`), the JSON `log_format`, and
   `otel_span_attr` directives that copy TLS variables onto trace spans. Built into the image
   by `Dockerfile.nginx` (official `nginx:1.31.2-alpine-otel`; no NGINX Plus license needed,
   though the same config also works unmodified against NGINX Plus).

2. Seven client containers (`clients/*/`) each hit `GET /handshake-info` in a loop with a
   random 5-15s delay, each configured with different TLS groups to negotiate a different
   outcome: `go-dual-share` (custom Go binary), `curl-pq` / `curl-classic` / `openssl-35-dual`
   / `openssl-classic-only` / `hrr-trigger` (shell `entrypoint.sh`, `openquantumsafe/*`
   images), `legacy-tls12` (stock curl image, always fails since it's capped at TLS 1.2
   against a TLS-1.3-only server). Every client prints one JSON log line per attempt
   (`client`, `curve`, `hrr`, `latency_ms`, `error`) to stdout.

   The three `openssl s_client`-based clients build a raw HTTP request with `printf` piped
   directly into `s_client`'s stdin. Never capture that `printf` output in a shell variable
   first (`x=$(printf ...)`): command substitution strips the trailing newline that
   terminates the HTTP headers and silently breaks the request (this caused real 400s/408s
   in this repo's history).

3. The observability stack is fully self-contained in `compose.yaml`. Promtail reads
   container logs from the **systemd journal directly** (`/var/log/journal`, bind-mounted
   `:ro,z`) rather than podman's Docker-API-compatible socket: `docker_sd_configs` against
   the socket is blocked by SELinux on macOS podman machine VMs (a confined container's
   `connect()` to a host socket is denied by policy, separate from file permissions). This
   means container filtering in `monitoring/promtail/promtail.yaml` is a static regex
   allowlist of container names, not a dynamic label. Flow: Promtail → Loki → Grafana
   (dashboard), and NGINX → Tempo (OTel traces via `ngx_otel_module`, gRPC on 4317) →
   Prometheus (Tempo's metrics-generator `remote_write`, needed only so Grafana's trace-view
   TraceQL metrics queries don't fail with "empty ring"; Prometheus scrapes nothing itself).

4. `monitoring/grafana/dashboards/pqc-tls-demo.json` is hand-maintained JSON, not exported
   from the UI. Bump the top-level `"version"` field on every edit (Grafana's own internal
   dashboard versioning is separate and won't reflect file changes on its own), and run
   `python3 -m json.tool <file> > /dev/null` to validate before reloading. Every panel's Loki
   datasource is the `${loki_ds}` template variable (never a hardcoded UID), and LogQL
   queries filter on `{namespace="pqc-demo"}`; both are load-bearing for the dashboard to
   "just work" against the provisioned datasource with zero manual setup. Reload after an
   edit with `podman compose up -d --force-recreate grafana`.

5. All 7 clients and nginx write structured JSON logs. Promtail's `pipeline_stages`
   (`monitoring/promtail/promtail.yaml`) compute a `level` label explicitly rather than
   relying on Loki's `detected_level` heuristic, which false-positives on the JSON key
   `"error"` even when its value is `null`.

## Conventions

- No em dashes in any prose this repo touches (comments, README, commit messages). This repo
  is public; use commas, semicolons, or sentence breaks instead.
- Prefer `podman` / `podman compose` over `docker` / `docker compose` in commands and docs,
  though `compose.yaml` itself is runtime-agnostic.
