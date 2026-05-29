# Changelog

## v0.1.0 — 2026-05-29

Initial release. OTLP/HTTP exporter for Nim supporting traces, metrics, logs, and profiles (alpha).

### Features

- **Traces** — `Span`, `SpanEvent`, `SpanLink`, `SpanStatus`; proto and JSON encoding; `record()` synchronous send
- **Metrics** — `Metric` with Sum, Gauge, Histogram, ExponentialHistogram, Summary; aggregation temporality selector (`alwaysCumulative()` / `alwaysDelta()`); proto and JSON encoding
- **Logs** — `LogRecord` with all 25 `SeverityNumber` values; all `AnyValue` body kinds; proto and JSON encoding
- **Profiles** (alpha) — behind `-d:observyProfiles`; HTTP path `/v1development/profiles`
- **OTLP proto encoding** — byte-exact against opentelemetry-proto v1.10.0; attribute oneof zero-value correctness (`avInt 0`, `avBool false`, `avString ""` all emit correct field tags)
- **OTLP JSON encoding** — OTLP-JSON canonical form; `int64` nanos as strings; `intValue` as quoted string; `traceId`/`spanId` as lowercase hex
- **BatchProcessor** — bounded channel, `forceFlush()`, `shutdown()`; gcsafe `onBatch` callback; 4-thread concurrent producer support
- **Retry** — exponential backoff with jitter, `Retry-After` header support, configurable elapsed budget
- **Partial-success** — proto and JSON decoding; warn hook on 2xx with rejections
- **Gzip compression** — behind `-d:observyGzip`; links libz; `Content-Encoding: gzip` header
- **Input validation** — URL scheme (http/https only), header CR/LF injection prevention
- **Configuration** — `loadFromEnv()` reads all `OTEL_EXPORTER_OTLP_*` env vars; `ExporterConfig` with per-signal endpoint overrides
- **Attribute limits** — `AttributeSet` with `maxCount` (default 128) and `maxValueLen` (default 4096); UTF-8-safe string truncation; `dropped` counter
- **Examples** — `examples/traces.nim`, `examples/logs.nim`, `examples/metrics.nim` with `examples/nim.cfg`
- **Integration tests** — traces, metrics, logs against OTel collector-contrib 0.119.0; `-d:liveCollector` guard
