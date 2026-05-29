## observy — an OTLP exporter library for Nim.
##
## `import observy` exposes everything needed to build and ship telemetry for all
## signals without importing sub-modules:
##   - value types: AnyValue/KeyValue/AttributeSet, Resource/InstrumentationScope,
##     Span/SpanEvent/SpanLink, LogRecord, Metric (+ data-point types)
##   - encoders: protoEncode*/jsonEncode* and the per-signal spanToJson /
##     logRecordsToJson / metricToJson request builders
##   - transport: OtlpHttpExporter (newOtlpExporter), sendSignal, retryWithBackoff,
##     partial-success handling (handleResponse)
##   - batching: BatchProcessor[T] with start/submit/forceFlush/shutdown
##   - config: ExporterConfig / loadFromEnv (OTEL_* env vars)
##
## Style (after zippy/puppy): value types, shallow object nesting, small surface,
## zero Nimble dependencies (OpenSSL only for HTTPS via -d:ssl). Compile consumers
## with `--mm:orc --threads:on`.
##
## Profiles (alpha) are gated behind `-d:observyProfiles`.

import observy/anyvalue;      export anyvalue
import observy/proto;         export proto
import observy/json_encode;   export json_encode
import observy/resource;      export resource
import observy/traces;        export traces
import observy/metrics;       export metrics
import observy/logs;          export logs
import observy/config;        export config
import observy/exporter_http; export exporter_http
import observy/retry;         export retry
import observy/batch;         export batch

when defined(observyProfiles):
  import observy/profiles;    export profiles

# ---------------------------------------------------------------------------
# Friendly constructors (the documented public API names)
# ---------------------------------------------------------------------------

proc newOtlpExporter*(config: ExporterConfig): OtlpHttpExporter =
  ## Construct an OTLP/HTTP exporter from a config (alias for
  ## newOtlpHttpExporter). Pair with loadFromEnv() for OTEL_*-driven setup:
  ##   var exporter = newOtlpExporter(loadFromEnv())
  newOtlpHttpExporter(config)
