import unittest
import std/options
import std/json
import std/atomics
import std/strutils
# The whole point: a single `import observy` must expose every public observy
# type and proc used below. No `import observy/...` sub-module imports allowed
# (stdlib imports above are fine — they are not observy sub-modules).
import ../src/observy

suite "umbrella: types are reachable via `import observy`":
  test "AnyValue / KeyValue / AttributeSet":
    var a = initAttributeSet()
    a.add("k", AnyValue(kind: avString, strVal: "v"))
    check a.pairs.len == 1

  test "Resource / InstrumentationScope":
    let r = Resource(attributes: initAttributeSet())
    let s = InstrumentationScope(name: "lib", attributes: initAttributeSet())
    check jsonEncode(r).len > 0
    check jsonEncode(s).len > 0

  test "Span and trace types":
    var tid: TraceId
    var sid: SpanId
    let span = Span(traceId: tid, spanId: sid, name: "op", kind: skServer,
                    attributes: initAttributeSet(), status: SpanStatus(code: statusOk))
    check span.kind == skServer

  test "LogRecord and SeverityNumber":
    let lr = LogRecord(severityNumber: severityInfo, severityText: "INFO",
                       body: AnyValue(kind: avString, strVal: "hi"),
                       attributes: initAttributeSet())
    check lr.severityNumber == severityInfo

  test "Metric and data-point types":
    let m = Metric(name: "m", kind: mkSum, sum: MetricSum(
      dataPoints: @[NumberDataPoint(attributes: initAttributeSet(),
                                    kind: ndpInt, intValue: 1)],
      aggregationTemporality: aggTempCumulative, isMonotonic: true))
    check m.kind == mkSum
    # Option-typed histogram fields reachable too
    let h = HistogramDataPoint(attributes: initAttributeSet(), sum: some(1.0))
    check h.sum.isSome

  test "ExporterConfig / OtlpProtocol / SignalIndex":
    var cfg: ExporterConfig
    cfg.protocol = otlpJsonHttp
    check defaultContentType(cfg.protocol) == "application/json"
    check SigTraces == 0

  test "BatchConfig / ExportResult / PartialSuccess / RetryHooks":
    let bc = defaultBatchConfig()
    check bc.maxSize == 512
    var er: ExportResult
    check not er.succeeded
    var ps: PartialSuccess
    check ps.rejectedCount == 0
    let hooks = defaultRetryHooks()
    check hooks.nowSec != nil

suite "umbrella: encoders reachable":
  test "spanToJson builds an ExportTraceServiceRequest":
    var tid: TraceId
    var sid: SpanId
    let span = Span(traceId: tid, spanId: sid, name: "op",
                    attributes: initAttributeSet())
    let j = parseJson(spanToJson(Resource(attributes: initAttributeSet()),
                                 InstrumentationScope(attributes: initAttributeSet()),
                                 @[span]))
    check j.hasKey("resourceSpans")

  test "metricToJson and logRecordsToJson reachable":
    let mj = metricToJson(Resource(attributes: initAttributeSet()),
                          InstrumentationScope(attributes: initAttributeSet()), @[])
    check mj.contains("resourceMetrics")
    let lj = logRecordsToJson(Resource(attributes: initAttributeSet()),
                              InstrumentationScope(attributes: initAttributeSet()), @[])
    check lj.contains("resourceLogs")

  test "proto encoders reachable (Span)":
    var w: ProtoWriter
    var tid: TraceId
    var sid: SpanId
    protoEncodeSpan(w, Span(traceId: tid, spanId: sid, name: "x",
                            attributes: initAttributeSet()))
    check w.buf.len > 0

suite "umbrella: public constructors":
  test "newOtlpExporter builds an exporter; partial-success helper reachable":
    var e = newOtlpExporter(ExporterConfig(protocol: otlpProtoHttp))
    let ps = e.handleResponse(ExportResponse(code: Http200,
      contentType: "application/x-protobuf", body: ""))
    e.close()
    check ps.rejectedCount == 0

  test "newOtlpExporter from loadFromEnv":
    var e = newOtlpExporter(loadFromEnv())
    check e.config.endpoint.len > 0
    e.close()

  test "BatchProcessor start/submit/forceFlush/shutdown reachable":
    var p = newBatchProcessor[int](
      BatchConfig(maxSize: 2, flushIntervalMs: 10_000, maxQueueSize: 100))
    var flushed: Atomic[int]
    p.start(proc (items: seq[int]) {.gcsafe.} =
      {.cast(gcsafe).}: discard flushed.fetchAdd(items.len))
    p.submit(1)
    p.submit(2)
    p.forceFlush()
    p.shutdown()
    check flushed.load() == 2
