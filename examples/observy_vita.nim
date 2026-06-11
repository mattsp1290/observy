## PlayStation Vita OTLP/HTTP protobuf verification example.
##
## Build:
##   scripts/build_vita.sh examples/observy_vita.nim observy_vita
##
## Run with the Vita clock set correctly. Datadog will drop or misplace
## telemetry with a wrong wall-clock timestamp.

when not defined(vita):
  {.error: "examples/observy_vita.nim must be built with scripts/build_vita.sh (-d:vita)".}
else:
  import std/strutils

  import observy
  import observy/time_vita

  const
    CollectorEndpoint {.strdefine.} = "http://10.0.0.106:4318"
    ObservyVitaUtcOffsetSec {.intdefine.} = 0
      ## Seconds added to clock_gettime(CLOCK_REALTIME) before stamping.
      ## Keep 0 when the Vita clock is UTC; for EDT-local RTC use 14400.
    ResultPath = "ux0:data/observy_vita_result.txt"

  proc sceNetCtlInetGetState(state: ptr cint): cint
    {.importc, header: "<psp2/net/netctl.h>".}
  proc sceKernelExitProcess(status: cint): cint
    {.importc, header: "<psp2/kernel/processmgr.h>", discardable.}
  proc mkdir(path: cstring; mode: cint): cint
    {.importc, header: "<sys/stat.h>", discardable.}

  var crumbs: seq[string]

  proc crumb(line: string) =
    crumbs.add(line)
    try:
      mkdir("ux0:data", 0o777.cint)
      writeFile(ResultPath, crumbs.join("\n") & "\n")
    except CatchableError:
      discard

  proc codeInt(resp: ExportResponse): int =
    resp.code.int

  proc excSummary(e: ref CatchableError): string =
    $e.name & ": " & e.msg

  proc buildConfig(): ExporterConfig =
    result = ExporterConfig(
      endpoint: CollectorEndpoint,
      protocol: otlpProtoHttp,
      timeoutMs: 10_000,
      compression: compNone)
    result.signalEndpoints[SigTraces] = CollectorEndpoint & "/v1/traces"
    result.signalEndpoints[SigMetrics] = CollectorEndpoint & "/v1/metrics"
    result.signalEndpoints[SigLogs] = CollectorEndpoint & "/v1/logs"

  proc buildResource(runId: string): Resource =
    var attrs = initAttributeSet()
    attrs.add("service.name", AnyValue(kind: avString, strVal: "observy-vita-verify"))
    attrs.add("telemetry.sdk.language", AnyValue(kind: avString, strVal: "nim"))
    attrs.add("device", AnyValue(kind: avString, strVal: "playstation-vita"))
    attrs.add("observy.run.id", AnyValue(kind: avString, strVal: runId))
    Resource(attributes: attrs, droppedAttributesCount: attrs.dropped)

  proc buildScope(): InstrumentationScope =
    InstrumentationScope(
      name: "examples/observy_vita",
      version: "0.1.0",
      attributes: initAttributeSet())

  proc fillIdBytes(dest: var openArray[byte]; seed: uint64) =
    for i in 0 ..< dest.len:
      dest[i] = byte((seed shr ((i mod 8) * 8)) and 0xff'u64)

  proc buildTraceId(t0: uint64): TraceId =
    fillIdBytes(result, t0)
    result[0] = 0x4b'u8
    result[8] = result[8] xor 0xa3'u8

  proc buildSpanId(t0: uint64; salt: uint64): SpanId =
    fillIdBytes(result, t0 xor salt)
    result[0] = result[0] or 0x01'u8

  proc markerAttrs(): AttributeSet =
    result = initAttributeSet()
    result.add("device", AnyValue(kind: avString, strVal: "playstation-vita"))

  proc buildSpans(t0: uint64; traceId: TraceId; rootId, childId: SpanId): seq[Span] =
    var rootAttrs = markerAttrs()
    rootAttrs.add("example", AnyValue(kind: avString, strVal: "observy_vita"))
    var childAttrs = markerAttrs()
    childAttrs.add("step", AnyValue(kind: avString, strVal: "child"))
    var eventAttrs = markerAttrs()
    @[
      Span(
        traceId: traceId,
        spanId: rootId,
        name: "vita-verify-root",
        kind: skInternal,
        startTimeUnixNano: t0,
        endTimeUnixNano: t0 + 2_000_000'u64,
        attributes: rootAttrs,
        droppedAttributesCount: rootAttrs.dropped,
        events: @[SpanEvent(
          timeUnixNano: t0 + 500_000'u64,
          name: "vita-breadcrumb",
          attributes: eventAttrs,
          droppedAttributesCount: eventAttrs.dropped)],
        status: SpanStatus(code: statusOk)),
      Span(
        traceId: traceId,
        spanId: childId,
        parentSpanId: rootId,
        name: "vita-verify-child",
        kind: skInternal,
        startTimeUnixNano: t0 + 500_000'u64,
        endTimeUnixNano: t0 + 1_500_000'u64,
        attributes: childAttrs,
        droppedAttributesCount: childAttrs.dropped,
        status: SpanStatus(code: statusOk))
    ]

  proc buildMetrics(t0: uint64): seq[Metric] =
    var attrs = markerAttrs()
    let gauge = Metric(
      name: "observy.vita.boot.gauge",
      description: "Vita observy verification gauge",
      unit: "{boot}",
      kind: mkGauge,
      gauge: MetricGauge(
        dataPoints: @[NumberDataPoint(
          attributes: attrs,
          startTimeUnixNano: t0,
          timeUnixNano: t0,
          kind: ndpDouble,
          doubleValue: 1.0)]))
    @[gauge]

  proc buildLog(t0: uint64; traceId: TraceId; spanId: SpanId; runId: string): LogRecord =
    var attrs = markerAttrs()
    attrs.add("observy.run.id", AnyValue(kind: avString, strVal: runId))
    LogRecord(
      timeUnixNano: t0,
      observedTimeUnixNano: t0,
      severityNumber: severityInfo,
      severityText: "INFO",
      body: AnyValue(kind: avString, strVal: "observy Vita verification"),
      attributes: attrs,
      droppedAttributesCount: attrs.dropped,
      traceId: traceId,
      spanId: spanId)

  proc offsetUnixNano(rawT0: uint64): uint64 =
    let offsetNanos = ObservyVitaUtcOffsetSec.int64 * 1_000_000_000'i64
    if offsetNanos >= 0:
      rawT0 + uint64(offsetNanos)
    else:
      rawT0 - uint64(-offsetNanos)

  proc main() =
    crumb("START observy Vita verify")
    crumb("collector=" & CollectorEndpoint)

    let rawT0 = nowUnixNano()
    let t0 = offsetUnixNano(rawT0)
    let runId = "vita-" & $t0
    crumb("run.id=" & runId)
    crumb("timestamp.raw_unix_nano=" & $rawT0)
    crumb("timestamp.utc_offset_sec=" & $ObservyVitaUtcOffsetSec)
    crumb("timestamp.unix_nano=" & $t0)

    let traceId = buildTraceId(t0)
    let rootId = buildSpanId(t0, 0x00f067aa0ba902b7'u64)
    let childId = buildSpanId(t0, 0x11c077bb1cb813c8'u64)
    let resource = buildResource(runId)
    let scope = buildScope()

    var exporter: OtlpHttpExporter
    var exporterReady = false
    var netState: cint = -1
    var netRc: cint = -1
    var tracesCode = -1
    var metricsCode = -1
    var logsCode = -1
    var failed = false

    try:
      var cfg = buildConfig()
      cfg.temporalitySelector = alwaysCumulative()
      exporter = newOtlpExporter(cfg)
      exporterReady = true
      crumb("exporter.init PASS")

      netRc = sceNetCtlInetGetState(addr netState)
      crumb("sceNetCtlInetGetState rc=" & $netRc & " state=" & $netState & " (3 means IP obtained)")

      try:
        let resp = exporter.record(resource, scope, buildSpans(t0, traceId, rootId, childId))
        tracesCode = codeInt(resp)
        crumb("traces.code=" & $tracesCode)
        if tracesCode != 200: failed = true
      except CatchableError as e:
        failed = true
        crumb("traces.error=" & excSummary(e))

      try:
        let resp = exporter.record(resource, scope, buildMetrics(t0))
        metricsCode = codeInt(resp)
        crumb("metrics.code=" & $metricsCode)
        if metricsCode != 200: failed = true
      except CatchableError as e:
        failed = true
        crumb("metrics.error=" & excSummary(e))

      try:
        let resp = exporter.record(resource, scope, @[buildLog(t0, traceId, rootId, runId)])
        logsCode = codeInt(resp)
        crumb("logs.code=" & $logsCode)
        if logsCode != 200: failed = true
      except CatchableError as e:
        failed = true
        crumb("logs.error=" & excSummary(e))

      if not failed and tracesCode == 200 and metricsCode == 200 and logsCode == 200:
        crumb("PASS")
      else:
        crumb("FAIL traces=" & $tracesCode &
              " metrics=" & $metricsCode &
              " logs=" & $logsCode &
              " netctl.rc=" & $netRc &
              " netctl.state=" & $netState)
    except CatchableError as e:
      crumb("FAIL " & excSummary(e) &
            " netctl.rc=" & $netRc &
            " netctl.state=" & $netState)
    finally:
      if exporterReady:
        exporter.close()
        crumb("exporter.close PASS")

    discard sceKernelExitProcess(0)

  main()
