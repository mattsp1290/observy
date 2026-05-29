# observy

An OTLP exporter library for Nim. Send traces, metrics, and logs to any OpenTelemetry Collector.

> **Scope:** observy is an *exporter*, not a full OTel SDK. It encodes and ships telemetry — it does not manage `TracerProvider`, `Tracer`, sampling, context propagation, or automatic instrumentation.

---

## Installation

```bash
nimble install observy
```

Compile your program with:

```bash
nim c --mm:orc --threads:on -r myapp.nim
```

Both `--mm:orc` and `--threads:on` are **required**.

---

## Quick Start: Traces

```nim
import observy

var resAttrs = initAttributeSet()
resAttrs.add("service.name", AnyValue(kind: avString, strVal: "my-service"))
let resource = Resource(attributes: resAttrs)
let scope    = InstrumentationScope(name: "my-app", version: "1.0.0",
                                    attributes: initAttributeSet())

var spanAttrs = initAttributeSet()
spanAttrs.add("http.method", AnyValue(kind: avString, strVal: "GET"))
var tid: TraceId; var sid: SpanId
for i in 0..<16: tid[i] = byte(i+1)
for i in 0..<8:  sid[i] = byte(i+1)

let span = Span(
  traceId: tid, spanId: sid, name: "GET /api/users", kind: skServer,
  startTimeUnixNano: 1_700_000_000_000_000_000'u64,
  endTimeUnixNano:   1_700_000_001_000_000_000'u64,
  attributes: spanAttrs, status: SpanStatus(code: statusOk))

var exporter = newOtlpExporter(loadFromEnv())
let resp = exporter.record(resource, scope, @[span])
echo resp.code   # 200 = success
exporter.close()
```

---

## Quick Start: Metrics

```nim
import observy

var resAttrs = initAttributeSet()
resAttrs.add("service.name", AnyValue(kind: avString, strVal: "my-service"))
let resource = Resource(attributes: resAttrs)
let scope    = InstrumentationScope(name: "my-app", attributes: initAttributeSet())

let counter = Metric(
  name: "http.requests.total", unit: "{request}",
  kind: mkSum,
  sum: MetricSum(
    dataPoints: @[NumberDataPoint(
      attributes: initAttributeSet(),
      timeUnixNano: 1_700_000_000_000_000_000'u64,
      kind: ndpInt, intValue: 42)],
    aggregationTemporality: aggTempCumulative,
    isMonotonic: true))

var cfg = loadFromEnv()
cfg.temporalitySelector = alwaysCumulative()
var exporter = newOtlpExporter(cfg)
let resp = exporter.record(resource, scope, @[counter])
echo resp.code
exporter.close()
```

---

## Quick Start: Logs

```nim
import observy

var resAttrs = initAttributeSet()
resAttrs.add("service.name", AnyValue(kind: avString, strVal: "my-service"))
let resource = Resource(attributes: resAttrs)
let scope    = InstrumentationScope(name: "my-app", attributes: initAttributeSet())

let infoLog = LogRecord(
  timeUnixNano:   1_700_000_000_000_000_000'u64,
  severityNumber: severityInfo, severityText: "INFO",
  body: AnyValue(kind: avString, strVal: "user login succeeded"),
  attributes: initAttributeSet())

let errorLog = LogRecord(
  timeUnixNano:   1_700_000_001_000_000_000'u64,
  severityNumber: severityError, severityText: "ERROR",
  body: AnyValue(kind: avString, strVal: "database connection failed"),
  attributes: initAttributeSet())

var exporter = newOtlpExporter(loadFromEnv())
let resp = exporter.record(resource, scope, @[infoLog, errorLog])
echo resp.code
exporter.close()
```

---

## Configuration

### ExporterConfig fields

| Field | Type | Default | Description |
|---|---|---|---|
| `endpoint` | string | `http://localhost:4318` | Base OTLP HTTP endpoint URL |
| `signalEndpoints` | array[4, string] | derived from `endpoint` | Per-signal endpoint overrides |
| `headers` | seq[(string, string)] | `[]` | Extra HTTP headers (e.g. auth tokens) |
| `protocol` | OtlpProtocol | `otlpProtoHttp` | `otlpProtoHttp` or `otlpJsonHttp` |
| `compression` | CompressionType | `compNone` | `compNone` or `compGzip` (see below) |
| `temporalitySelector` | proc | `nil` | Aggregation temporality for metrics |
| `timeoutMs` | int | 10000 | Per-request HTTP timeout in ms (0 = use default) |
| `maxRetryElapsed` | int | 300 | Max cumulative retry window in seconds (0 = 300s default) |

### OTEL_* environment variables

| Variable | Default | Description |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | Base endpoint; `/v1/{signal}` appended |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | derived | Override traces endpoint directly |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | derived | Override metrics endpoint directly |
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` | derived | Override logs endpoint directly |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | `key=value,key2=value2` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | `http/protobuf` or `http/json` |
| `OTEL_EXPORTER_OTLP_COMPRESSION` | — | `gzip` (requires `-d:observyGzip`) |
| `OTEL_SERVICE_NAME` | — | Sets `service.name` resource attribute |

Signal-specific endpoint variables take precedence over the base endpoint. Values set in `OTEL_EXPORTER_OTLP_*_ENDPOINT` are used verbatim (no `/v1/{signal}` appended).

---

## Batch Export

For high-throughput or async export, use `BatchProcessor`:

```nim
import observy

var exporter = newOtlpExporter(loadFromEnv())
let resource = Resource(attributes: initAttributeSet())
let scope    = InstrumentationScope(attributes: initAttributeSet())

proc onBatch(spans: seq[Span]) {.gcsafe.} =
  discard exporter.record(resource, scope, spans)

var p = newBatchProcessor[Span](defaultBatchConfig())
p.start(onBatch)

# Submit spans from any thread:
p.submit(mySpan)

# Drain before shutdown:
p.forceFlush()
p.shutdown()
exporter.close()
```

`BatchConfig` fields: `maxSize` (512), `flushIntervalMs` (5000), `maxQueueSize` (2048).

---

## Retry Policy

Use `retryWithBackoff` to wrap `sendSignal` with automatic retries on transient HTTP errors:

```nim
# Set max retry window via config (default: 300 seconds)
var cfg = loadFromEnv()
cfg.maxRetryElapsed = 30   # 30 seconds
var exporter = newOtlpExporter(cfg)

# retryWithBackoff uses cfg.maxRetryElapsed for the elapsed budget
let result = exporter.retryWithBackoff(endpoint, payload, contentType)
if result.succeeded:
  echo "exported after ", result.attempts, " attempt(s)"
```

Retried status codes: 429 (rate-limit), 502, 503, 504. Respects `Retry-After` headers. Non-retried: 400, 401, 403, 404 (permanent failures).

---

## TLS

HTTPS endpoints work automatically when compiled with `-d:ssl` (requires OpenSSL):

```bash
nim c --mm:orc --threads:on -d:ssl -r myapp.nim
```

Set `OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.example.com` or configure `config.endpoint`.

---

## Gzip Compression

Compile with `-d:observyGzip` to enable gzip compression (requires zlib):

```bash
# Install zlib (once)
brew install zlib           # macOS
apt-get install zlib1g-dev  # Ubuntu/Debian

# Compile with gzip support
nim c --mm:orc --threads:on -d:observyGzip -r myapp.nim
```

Enable in config:

```nim
var cfg = loadFromEnv()
cfg.compression = compGzip
var exporter = newOtlpExporter(cfg)
```

Or via env: `OTEL_EXPORTER_OTLP_COMPRESSION=gzip`.

> **Note:** Without `-d:observyGzip`, setting `compGzip` raises `ValueError` at exporter construction — fail-fast to prevent silent Content-Encoding mismatch.

---

## Profiles (alpha)

Experimental profiles signal — compile with `-d:observyProfiles`:

```bash
nim c --mm:orc --threads:on -d:observyProfiles -r myapp.nim
```

HTTP path: `/v1development/profiles`. The API is not stable and the path is subject to change.

---

## Signal endpoint paths

| Signal | Default path |
|---|---|
| Traces | `/v1/traces` |
| Metrics | `/v1/metrics` |
| Logs | `/v1/logs` |
| Profiles | `/v1development/profiles` |
