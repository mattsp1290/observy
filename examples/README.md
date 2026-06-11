# observy examples

Runnable examples demonstrating traces, metrics, and logs export via OTLP/HTTP.

## Prerequisites

- [Nim](https://nim-lang.org/install.html) ≥ 2.0 (`nim --version`)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) or Docker Engine with Compose

## Quick Start

### 1. Start the OTel Collector

From the **repo root**:

```bash
docker compose up -d
```

### 2. Verify the collector is healthy

```bash
curl http://localhost:13133/
# expect: HTTP 200 OK
```

### 3. Run an example

```bash
nim c -r examples/traces.nim
# or
nim c -r examples/logs.nim
# or
nim c -r examples/metrics.nim
```

> **Note:** `examples/nim.cfg` supplies `--mm:orc --threads:on` automatically — no extra flags needed.
> For `-d:ds3` and `-d:vita`, the same file leaves the console `arc`/`threads:off` settings alone.

### 4. See the output

```bash
# Check collector logs for received spans
docker compose logs otelcol | grep span

# Inspect raw OTLP-JSON output
cat collector-output/signals.json | head -100
```

### 5. Teardown

```bash
docker compose down -v
```

---

## Environment variables

Override defaults without recompiling:

| Variable | Default | Description |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Collector endpoint base URL |
| `OTEL_SERVICE_NAME` | `observy-example` | `service.name` resource attribute |

Example:

```bash
OTEL_SERVICE_NAME=my-service nim c -r examples/traces.nim
```

---

## Compiler flags reference

All flags are pre-set in `examples/nim.cfg`:

| Flag | Required | Reason |
|---|---|---|
| `--mm:orc` | yes | Memory management (ORC) — required by observy |
| `--threads:on` | yes | Thread support — required by observy |
| `-d:observyGzip` | not yet | Gzip compression — **not yet implemented** (tracked: observy-5a9). Compiling with this flag does not enable compression; setting `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` raises at construction until the feature lands. |
| `-d:ssl` | optional | Enable HTTPS endpoints (requires OpenSSL) |

---

## Examples overview

| File | Signals | Highlights |
|---|---|---|
| `traces.nim` | 2 spans | Server span + child span; SpanEvent, SpanLink, attributes, Status=OK |
| `logs.nim` | 3 log records | INFO/WARN/ERROR; trace context, structured kvlist body |
| `metrics.nim` | 3 metric types | Counter (Sum), Gauge, Histogram; temporality selector |
| `observy_3ds.nim` | trace + metric + log | Nintendo 3DS build, plaintext OTLP/protobuf to `10.0.0.106:4318`; build with `scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds`; set `NIMFLAGS_3DS='-d:Observy3dsUtcOffsetSec=<seconds>'` if the 3DS/Azahar wall clock is local time rather than UTC |
| `observy_vita.nim` | trace + metric + log | PlayStation Vita headless build, plaintext OTLP/protobuf to `10.0.0.106:4318`; build with `scripts/build_vita.sh examples/observy_vita.nim observy_vita`; set `NIMFLAGS_VITA='-d:ObservyVitaUtcOffsetSec=<seconds>'` if the Vita clock is local time rather than UTC |
