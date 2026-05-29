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

# ---------------------------------------------------------------------------
# Proto request builders — wrap encoded signal items in the OTLP service request
# nesting: ExportXServiceRequest{1=ResourceX{1=resource, 2=ScopeX{1=scope,
# 2=items}}}. Embedded messages share the length-delimited wire format with
# `bytes`, so writeBytes composes them. (An empty resource/scope is omitted, which
# is valid proto3 — the collector defaults it.)
# ---------------------------------------------------------------------------

proc protoEncodeTraceRequest*(res: Resource; scope: InstrumentationScope;
                              spans: seq[Span]): seq[byte] =
  var scopeSpans: ProtoWriter
  scopeSpans.writeBytes(1, protoEncode(scope))
  for s in spans:
    var sw: ProtoWriter
    protoEncodeSpan(sw, s)
    scopeSpans.writeBytes(2, sw.buf)
  var resourceSpans: ProtoWriter
  resourceSpans.writeBytes(1, protoEncode(res))
  resourceSpans.writeBytes(2, scopeSpans.buf)
  var req: ProtoWriter
  req.writeBytes(1, resourceSpans.buf)
  req.buf

proc protoEncodeLogsRequest*(res: Resource; scope: InstrumentationScope;
                             logs: seq[LogRecord]): seq[byte] =
  var scopeLogs: ProtoWriter
  scopeLogs.writeBytes(1, protoEncode(scope))
  for l in logs:
    var lw: ProtoWriter
    protoEncodeLogRecord(lw, l)
    scopeLogs.writeBytes(2, lw.buf)
  var resourceLogs: ProtoWriter
  resourceLogs.writeBytes(1, protoEncode(res))
  resourceLogs.writeBytes(2, scopeLogs.buf)
  var req: ProtoWriter
  req.writeBytes(1, resourceLogs.buf)
  req.buf

proc protoEncodeMetricsRequest*(res: Resource; scope: InstrumentationScope;
                                metrics: seq[Metric]): seq[byte] =
  var scopeMetrics: ProtoWriter
  scopeMetrics.writeBytes(1, protoEncode(scope))
  for m in metrics:
    var mw: ProtoWriter
    protoEncodeMetric(mw, m)
    scopeMetrics.writeBytes(2, mw.buf)
  var resourceMetrics: ProtoWriter
  resourceMetrics.writeBytes(1, protoEncode(res))
  resourceMetrics.writeBytes(2, scopeMetrics.buf)
  var req: ProtoWriter
  req.writeBytes(1, resourceMetrics.buf)
  req.buf

proc strToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

# ---------------------------------------------------------------------------
# record() — the primary emit API (named `record`, never `export` which is a
# Nim keyword). Two forms per signal:
#   - record(batchProcessor, item): enqueue one item for async batched export.
#   - record(exporter, resource, scope, items): synchronous, single request.
# ---------------------------------------------------------------------------

# Instantiating BatchProcessor[Span|LogRecord|Metric] makes the compiler generate
# Isolated[T].=destroy for these types; std/isolation's =destroy is conservatively
# inferred as possibly-raising, producing a spurious [Effect] warning at the
# instantiation site. Suppress it locally (the destructors here cannot actually
# raise) so the library builds warning-free.
{.push warning[Effect]: off.}

proc record*(p: var BatchProcessor[Span]; span: Span) =
  ## Enqueue a span for async batched export. Blocks only under backpressure.
  p.submit(span)

proc record*(p: var BatchProcessor[LogRecord]; log: LogRecord) =
  ## Enqueue a log record for async batched export.
  p.submit(log)

proc record*(p: var BatchProcessor[Metric]; metric: Metric) =
  ## Enqueue a metric for async batched export.
  p.submit(metric)

{.pop.}

proc handle2xx(e: var OtlpHttpExporter; resp: ExportResponse) =
  ## On a 2xx, decode partial-success and warn on any rejection (never silently
  ## drop it). This is the synchronous emit path's wiring of handleResponse
  ## (observy-5gl). Non-2xx responses are returned as-is for the caller to act on.
  if int(resp.code) in 200 .. 299:
    discard e.handleResponse(resp)

proc record*(e: var OtlpHttpExporter; resource: Resource;
             scope: InstrumentationScope; spans: seq[Span]): ExportResponse =
  ## Synchronously encode + send spans as one OTLP request (protocol-selected:
  ## protobuf or JSON). SINGLE attempt — no automatic retry (wrap with your own
  ## policy or use retryWithBackoff). On a 2xx, partial-success is decoded and any
  ## rejection is surfaced via the exporter's warn hook. Returns the ExportResponse
  ## (check `.code`). Raises on a transport-level failure (connection/timeout/TLS).
  let payload =
    case e.config.protocol
    of otlpProtoHttp: protoEncodeTraceRequest(resource, scope, spans)
    of otlpJsonHttp:  strToBytes(spanToJson(resource, scope, spans))
  result = e.sendSignal(SigTraces, payload)
  e.handle2xx(result)

proc record*(e: var OtlpHttpExporter; resource: Resource;
             scope: InstrumentationScope; logs: seq[LogRecord]): ExportResponse =
  ## Synchronously encode + send log records as one OTLP request. Single attempt;
  ## partial-success surfaced via the warn hook on 2xx. See the spans overload.
  let payload =
    case e.config.protocol
    of otlpProtoHttp: protoEncodeLogsRequest(resource, scope, logs)
    of otlpJsonHttp:  strToBytes(logRecordsToJson(resource, scope, logs))
  result = e.sendSignal(SigLogs, payload)
  e.handle2xx(result)

proc record*(e: var OtlpHttpExporter; resource: Resource;
             scope: InstrumentationScope; metrics: seq[Metric]): ExportResponse =
  ## Synchronously encode + send metrics as one OTLP request. Single attempt;
  ## partial-success surfaced via the warn hook on 2xx. If e.config has a
  ## temporalitySelector, it is applied to each metric before encoding.
  let resolved =
    if e.config.temporalitySelector != nil:
      var r = newSeq[Metric](metrics.len)
      for i, m in metrics: r[i] = applyTemporalitySelector(m, e.config.temporalitySelector)
      r
    else:
      metrics
  let payload =
    case e.config.protocol
    of otlpProtoHttp: protoEncodeMetricsRequest(resource, scope, resolved)
    of otlpJsonHttp:  strToBytes(metricToJson(resource, scope, resolved))
  result = e.sendSignal(SigMetrics, payload)
  e.handle2xx(result)
