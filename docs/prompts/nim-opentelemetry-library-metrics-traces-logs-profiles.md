# Project Planning with Beads

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary setup, implementation, testing, and documentation tasks. Go beyond the basics - consider edge cases, error handling, security considerations, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

## Project Information

### Links to Relevant Documentation
- https://opentelemetry.io/docs/specs/otlp/ — OTLP 1.10.0 spec (gRPC port 4317, HTTP port 4318)
- https://github.com/open-telemetry/opentelemetry-proto — Protobuf definitions for all signals
- https://github.com/open-telemetry/opentelemetry-proto-profile — Profiles signal proto (alpha)
- https://opentelemetry.io/docs/specs/otel/metrics/api/ — Metrics API (Counter, Histogram, Gauge, UpDownCounter, Observable variants)
- https://opentelemetry.io/docs/specs/otel/logs/ — Logs data model
- https://opentelemetry.io/docs/concepts/signals/profiles/ — Profiles (alpha)
- https://opentelemetry.io/docs/collector/ — Collector configuration & quick start
- https://github.com/guzba/zippy — Reference Nim library (style/structure inspiration)
- https://github.com/treeform/puppy — Reference Nim library (style/structure inspiration)

### Project Description
An OTLP exporter library for Nim — not a full OTel SDK. The library provides idiomatic Nim value types (Span, Metric, LogRecord, Profile) that users populate and pass to an exporter, which serialises them to OTLP protobuf or JSON and ships them to an OpenTelemetry collector. No TracerProvider, no automatic instrumentation, no sampling — just the data model + wire encoding + transport. Modeled after the clean, dependency-light style of zippy and puppy so any Nim project can `nimble install observy` and start exporting in minutes.

### Technical Stack
- Language: Nim — no Nimble dependencies; the only acceptable system-library dependency is OpenSSL (required for HTTPS via `-d:ssl`). HTTP-only (non-TLS) deployments need no external libraries at all.
- Transport: Nim's stdlib `httpclient` for OTLP/HTTP (HTTP/1.1). gRPC (which requires HTTP/2) is **out of scope for v1.0** and deferred to a future v2 epic.
- Serialization: Hand-rolled proto3 wire-format encoder/decoder in Nim + spec-compliant JSON mapping (see Context Documentation for encoding rules)
- Package manager: Nimble (`.nimble` package file, published to nimble.directory)
- Testing: `testament` (Nim's built-in test runner)
- CI: GitHub Actions
- Nim version target: latest stable; compiled with `--mm:orc --threads:on`

### Specific Requirements
- No Nimble dependencies — zero packages beyond Nim stdlib. OpenSSL is the only allowed system-level dependency (for TLS; plaintext-HTTP users need nothing extra).
- Clean, idiomatic Nim API: users fill in value types and call `export(exporter, span)` — no protobuf knowledge needed
- Nimble package with SemVer, so `nimble install observy` works out of the box
- OTLP/HTTP only at v1.0 (binary protobuf + JSON). gRPC is post-v1 and not in scope.
- All four signals: traces (stable), metrics (stable), logs (stable), profiles (alpha — behind `-d:observyProfiles` compile flag or `profiles` sub-module)
- **Data model completeness:**
  - Spans: SpanContext, TraceFlags, SpanKind, SpanEvent, SpanLink, Status, attributes (AnyValue)
  - Metrics: all six instrument types + all wire data-point types: NumberDataPoint, HistogramDataPoint, ExponentialHistogramDataPoint, Summary; configurable aggregation temporality (delta vs. cumulative); Exemplars
  - Logs: LogRecord with all spec fields (TraceId, SpanId, SeverityNumber, SeverityText, Body as AnyValue, attributes)
  - AnyValue: string, bool, int64, double, bytes, array, kvlist — foundational type shared by all signals
  - Attribute limits: max attribute count and value length truncation per signal type
- **Exporter lifecycle:** synchronous `forceFlush()` and blocking `shutdown()` (drains queue and stops worker thread); required for short-lived programs and serverless
- **Transport config:** configurable endpoint URL; arbitrary request-header injection (for Bearer tokens, API keys, etc.); `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` env-var support
- **Batch export** with configurable batch size and flush interval; thread-safe using Nim channels with `--mm:orc --threads:on`; `Isolated[T]` used for cross-thread payload passing
- **Retry policy:** exponential backoff on HTTP 429/502/503/504; honor `Retry-After` header (takes precedence over computed backoff); max elapsed time cap; drop with warning when queue full; non-retryable on all other 4xx
- **Partial-success handling:** parse `ExportTraceServiceResponse`, `ExportMetricsServiceResponse`, `ExportLogsServiceResponse` bodies on HTTP 200 and surface `partial_success.rejected_*` counts and `error_message` to the caller (log warning by default)
- Optional gzip compression (Content-Encoding: gzip) on HTTP requests
- Comprehensive README with quick-start examples for each signal
- Test suite with golden-byte proto round-trip fixtures, spec-conformant JSON encoding tests, and integration tests against a real OTel collector in CI (Docker Compose) with collector-output assertion (not just "no error")
- **Local dev Docker Compose environment:** `docker-compose.yml` in repo root spins up `otel/opentelemetry-collector-contrib` with a `file` exporter writing to `./collector-output/` and a `logging` exporter to stdout. Users and CI both use the same compose file. Health-check endpoint on `localhost:13133` so tests can wait for readiness before sending.
- **`examples/` directory:** a self-contained Nim project (its own `examples.nimble` or just a `nim.cfg`) with one runnable file per signal — `examples/traces.nim`, `examples/metrics.nim`, `examples/logs.nim` — each sending a small representative payload to `http://localhost:4318` and calling `forceFlush()` + `shutdown()`. A `README` in `examples/` explains how to `docker compose up -d` then `nim c -r examples/traces.nim` to see data arrive in the collector logs.

---

## Your Task

Analyze this project and create a comprehensive **Beads task graph** using the `bd` CLI. Beads provides dependency-aware, conflict-free task management for multi-agent execution.

---

<critical_constraint>
Your ONLY output is a bash shell script. Do NOT use `bd add` — the correct command to create a bead is `bd create`. Use `bd dep add` for dependencies. Do not implement anything yourself.
</critical_constraint>

## Output Format

Generate a shell script that creates the full task graph. The script should:

1. **Initialize Beads** (if not already initialized)
2. **Create all beads** with appropriate priorities
3. **Establish dependencies** between beads
4. **Add labels** for phase grouping

### Example Output

```bash
#!/bin/bash
# Project: observy
# Generated: 2026-05-28

set -e

# Initialize beads if needed
if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating project beads..."

# ========================================
# Phase 1: Project Setup & Infrastructure
# ========================================

SETUP_NIMBLE=$(bd create "Initialize Nimble package and repo structure" -p 0 --label setup --silent)

SETUP_CI=$(bd create "Configure GitHub Actions CI with testament and Docker OTel collector" -p 1 --label setup --silent)
bd dep add $SETUP_CI $SETUP_NIMBLE

# ========================================
# Phase 2: Protobuf Encoder (core primitive)
# ========================================

PROTO_CORE=$(bd create "Implement proto3 wire-format encoder/decoder in pure Nim" \
  -d "Encode/decode varint, length-delimited, packed-repeated, embedded messages. Validate against binary golden fixtures from opentelemetry-proto v1.10.0." \
  -p 0 --label core --silent)
bd dep add $PROTO_CORE $SETUP_NIMBLE

PROTO_GOLDEN=$(bd create "Write golden-byte fixtures for proto3 encoder" \
  -d "Capture reference payloads from Go or Python OTel SDK; store in tests/fixtures/; add round-trip testament tests." \
  -p 0 --label testing --silent)
bd dep add $PROTO_GOLDEN $PROTO_CORE

# ========================================
# Phase 3: Common OTel Data Model
# ========================================

MODEL_ANYVALUE=$(bd create "Implement AnyValue/KeyValue types and attribute-limit enforcement" \
  -d "AnyValue union: string, bool, int64, double, bytes, array, kvlist. Attribute count limits and value-length truncation per signal type." \
  -p 0 --label core --silent)
bd dep add $MODEL_ANYVALUE $PROTO_CORE

MODEL_RESOURCE=$(bd create "Implement Resource and InstrumentationScope types" \
  -d "Resource attributes (KeyValue list), InstrumentationScope (name, version, attributes). Both depend on AnyValue." \
  -p 0 --label core --silent)
bd dep add $MODEL_RESOURCE $MODEL_ANYVALUE

# ========================================
# Phase 4: Signal Implementations
# ========================================

SIGNAL_TRACES=$(bd create "Implement Traces signal data model" \
  -d "Span, SpanContext (traceId/spanId as 16/8-byte arrays), TraceFlags, SpanKind, SpanStatus, SpanEvent, SpanLink. All attributes use AnyValue." \
  -p 0 --label feature-traces --silent)
bd dep add $SIGNAL_TRACES $MODEL_RESOURCE

# ... continue for all phases ...

echo ""
echo "Bead graph created! View with:"
echo "  bd ready              # List unblocked tasks"
```

---

## Bead Creation Guidelines

### Priority Levels
- `-p 0` = Critical (blocking other work)
- `-p 1` = High (important but not blocking)
- `-p 2` = Medium (standard work)
- `-p 3` = Low (nice to have)

### Labels (Phase Grouping)
Use `--label` to group beads by phase:
- `setup` - Project initialization
- `core` - Core architecture
- `auth` - Authentication/authorization
- `ui` - UI components
- `feature-{name}` - Feature-specific work
- `testing` - Test coverage
- `docs` - Documentation
- `deploy` - Deployment/CI

### Dependency Rules
1. Never create cycles
2. Every bead should have a clear dependency chain back to setup tasks
3. Use `bd dep add CHILD PARENT` (child depends on parent completing first)
4. Parallel work should share a common ancestor, not depend on each other

### Task Granularity
- Each bead should be completable in **under 750 lines of code**
- Tasks should be atomic enough for one agent to complete without coordination
- If a task requires multiple file areas, consider splitting by file area

---

## File Reservation Planning

For each major work area, note the file patterns that will need exclusive reservation:

```bash
# Proto encoder:      src/observy/proto.nim, tests/test_proto.nim, tests/fixtures/
# Common model:       src/observy/model.nim, src/observy/anyvalue.nim, src/observy/resource.nim
# Traces signal:      src/observy/traces.nim, tests/test_traces.nim
# Metrics signal:     src/observy/metrics.nim, tests/test_metrics.nim
# Logs signal:        src/observy/logs.nim, tests/test_logs.nim
# Profiles signal:    src/observy/profiles.nim, tests/test_profiles.nim
# HTTP exporter:      src/observy/exporter_http.nim, tests/test_exporter_http.nim
# Batch processor:    src/observy/batch.nim
# Env-var config:     src/observy/config.nim, tests/test_config.nim
# Public API:         src/observy.nim (umbrella module)
# Nimble package:     observy.nimble
# CI:                 .github/workflows/ci.yml, docker-compose.yml, collector-config.yml
# Examples:           examples/traces.nim, examples/metrics.nim, examples/logs.nim, examples/README.md
# Docs:               README.md, docs/
```

---

## Context Documentation

Place any important context in `docs/` for agents to reference:

- **Proto version:** Pin to `opentelemetry-proto v1.10.0` (tag `v1.10.0` on https://github.com/open-telemetry/opentelemetry-proto). All proto field numbers come from this exact tag. Do not use HEAD.
- **Profiles HTTP path:** `/v1development/profiles` (not `/v1/profiles`). Gated behind `-d:observyProfiles` compile flag.
- **OTLP JSON encoding rules (non-obvious):** Trace IDs and Span IDs are lowercase hex strings (not base64). `bytes` fields other than trace/span IDs are base64-encoded. 64-bit integer fields (e.g. `start_time_unix_nano`) are serialised as JSON **strings**, not numbers. `oneof` fields use their protobuf JSON name. These rules diverge from standard proto3 JSON and must be tested with golden files.
- **Proto3 wire-format traps:** varint encoding for field tags and lengths; zigzag encoding for sint32/sint64; packed repeated fields for numeric arrays; length-delimited encoding for embedded messages. The encoder must be validated against binary golden fixtures captured from a known-good OTel SDK (e.g. Go or Python), not just round-trip self-tests.
- **Thread model:** compile with `--mm:orc --threads:on`. Use `Isolated[T]` to move telemetry payloads across thread boundaries to satisfy ORC's ownership rules. Channels (`Chan[T]`) are preferred over a lock-protected deque because they compose cleanly with ORC's destructor model.
- **zippy/puppy coding style:** single-file modules where possible, no object hierarchies deeper than 2 levels, prefer value types (`object`) over ref types; keep the public API surface small.
- **Retry policy detail:** exponential backoff on HTTP 429/502/503/504; honor `Retry-After` header (override computed delay); non-retryable on all other 4xx. Drop oldest batch with a warning when queue is full. Max retry elapsed time: 300 s default, configurable.
- **Partial success:** On HTTP 200 response, always decode the response body and check `partial_success.rejected_*`. Emit a warning log for any non-zero rejection count. Do not silently discard.
- **Scope boundary:** This is an exporter library, not a full OTel SDK. No TracerProvider, no Tracer, no automatic context propagation, no sampling. Users create and populate value types manually, then call `export()`.
- **Docker Compose / collector setup:** Use `otel/opentelemetry-collector-contrib` (not the core image — contrib has the `file` exporter). `collector-config.yml` configures: receivers `otlp` (grpc 4317, http 4318); processors `batch`; exporters `logging` (verbosity: detailed) + `file` (path: `/collector-output/signals.json`). The `file` exporter output is bind-mounted to `./collector-output/` on the host. CI integration tests read `./collector-output/signals.json` after export to assert the correct service name, span count, metric names, etc. The collector's health-check extension listens on port `13133`; tests poll `http://localhost:13133/` before sending.
- **Local dev workflow:** `docker compose up -d` starts the collector. `nim c -r examples/traces.nim` sends a trace. `docker compose logs otelcol` shows the span in pretty-printed logging exporter output. `cat collector-output/signals.json` shows the raw file-exporter output. `docker compose down -v` tears down and clears output.

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beads.sh && ./setup-beads.sh`
2. **Check ready work**: `bd ready` should show initial setup tasks

---

## Completeness Checklist

Ensure your task graph includes:

- [ ] All setup and configuration tasks
- [ ] Core architecture and shared utilities (proto encoder, AnyValue, Resource)
- [ ] Feature implementation tasks broken into sub-beads: data model / proto encoding / JSON encoding / tests per signal
- [ ] AnyValue/KeyValue foundational type and attribute-limit enforcement
- [ ] All metric data-point types: NumberDataPoint, HistogramDataPoint, ExponentialHistogramDataPoint, Summary, Exemplar
- [ ] Metric aggregation temporality selector (delta vs. cumulative) per exporter
- [ ] Partial-success response parsing and warning for all three stable signals
- [ ] ForceFlush and Shutdown lifecycle on the exporter/batch processor
- [ ] Configurable headers and OTEL_* env-var configuration parser
- [ ] Retry policy with Retry-After header handling
- [ ] OTLP JSON encoding (hex trace/span IDs, base64 bytes, string int64) with golden-file tests
- [ ] Proto3 golden-byte round-trip fixtures
- [ ] Integration tests with collector-output assertion against `./collector-output/signals.json` (not just "no error")
- [ ] `docker-compose.yml` + `collector-config.yml` using `otel/opentelemetry-collector-contrib` with `file` + `logging` exporters
- [ ] `examples/` directory with `traces.nim`, `metrics.nim`, `logs.nim` each runnable against the local compose stack
- [ ] `examples/README.md` explaining the local dev workflow (`docker compose up -d` → run example → inspect output)
- [ ] Error handling and edge cases
- [ ] API documentation and README quick-start for each signal
- [ ] Security considerations (input validation: attribute limits, value length)
- [ ] CI/CD and deployment tasks (nimble.directory publish)
- [ ] Clear dependency chains with no cycles

### Per-bead acceptance criteria
Each `bd create -d` description should end with a "Done when:" line specifying the observable outcome (e.g. "Done when: testament suite passes and golden-fixture bytes match reference payload").
