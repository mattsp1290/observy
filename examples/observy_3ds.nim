## Nintendo 3DS OTLP/HTTP protobuf example.
##
## Build:
##   scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds
##
## Run with the 3DS RTC set correctly. Datadog will drop or misplace telemetry
## with a wrong wall-clock timestamp.

when not defined(ds3):
  {.error: "examples/observy_3ds.nim must be built with -d:ds3".}
else:
  import observy
  import observy/time_3ds

  const
    GFX_TOP = cint(0)
    KEY_START = uint32(1 shl 3)
    CollectorEndpoint {.strdefine.} = "http://10.0.0.106:4318"
    Observy3dsUtcOffsetSec {.intdefine.} = 0
      ## Seconds added to libctru osGetTime-derived wall time before stamping.
      ## Azahar can expose local wall time rather than UTC; for EDT use 14400.
    ResultPath = "observy_3ds_result.txt"

  proc gfxInitDefault() {.importc, header: "<3ds.h>".}
  proc gfxExit() {.importc, header: "<3ds.h>".}
  proc gfxFlushBuffers() {.importc, header: "<3ds.h>".}
  proc gfxSwapBuffers() {.importc, header: "<3ds.h>".}
  proc gspWaitForVBlank() {.importc, header: "<3ds.h>".}
  proc consoleInit(screen: cint; con: pointer): pointer
    {.importc, header: "<3ds.h>", discardable.}
  proc hidScanInput() {.importc, header: "<3ds.h>".}
  proc hidKeysDown(): uint32 {.importc, header: "<3ds.h>".}
  proc aptMainLoop(): bool {.importc, header: "<3ds.h>".}
  proc svcOutputDebugString(str: cstring; length: cint): cint
    {.importc, header: "<3ds.h>", discardable.}
  proc cprintf(fmt: cstring) {.importc: "printf", varargs, header: "<stdio.h>".}

  proc logLine(s: string) =
    cprintf("%s\n", s.cstring)
    discard svcOutputDebugString(s.cstring, cint(s.len))

  proc writeResult(status, detail: string) =
    writeFile(ResultPath, status & "\n" & detail & "\n")
    logLine("wrote " & ResultPath)

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
    attrs.add("service.name", AnyValue(kind: avString, strVal: "observy-3ds-verify"))
    attrs.add("telemetry.sdk.language", AnyValue(kind: avString, strVal: "nim"))
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    attrs.add("observy.run.id", AnyValue(kind: avString, strVal: runId))
    Resource(attributes: attrs)

  proc buildScope(): InstrumentationScope =
    InstrumentationScope(
      name: "examples/observy_3ds",
      version: "0.1.0",
      attributes: initAttributeSet())

  proc fillIdBytes(dest: var openArray[byte]; seed: uint64) =
    for i in 0 ..< dest.len:
      dest[i] = byte((seed shr ((i mod 8) * 8)) and 0xff'u64)

  proc buildTraceId(t0: uint64): TraceId =
    fillIdBytes(result, t0)
    result[0] = 0x4b'u8
    result[8] = result[8] xor 0xa3'u8

  proc buildSpanId(t0: uint64): SpanId =
    fillIdBytes(result, t0 xor 0x00f067aa0ba902b7'u64)
    result[0] = result[0] or 0x01'u8

  proc buildSpan(t0: uint64; traceId: TraceId; spanId: SpanId): Span =
    var attrs = initAttributeSet()
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    Span(
      traceId: traceId,
      spanId: spanId,
      name: "boot",
      kind: skInternal,
      startTimeUnixNano: t0,
      endTimeUnixNano: t0 + 1_000_000'u64,
      attributes: attrs,
      status: SpanStatus(code: statusOk))

  proc buildMetrics(t0: uint64): seq[Metric] =
    var attrs = initAttributeSet()
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    let counter = Metric(
      name: "observy.3ds.boot.count",
      description: "3DS observy verification boot count",
      unit: "{boot}",
      kind: mkSum,
      sum: MetricSum(
        dataPoints: @[NumberDataPoint(
          attributes: attrs,
          startTimeUnixNano: t0,
          timeUnixNano: t0,
          kind: ndpInt,
          intValue: 1)],
        aggregationTemporality: aggTempCumulative,
        isMonotonic: true))
    let gauge = Metric(
      name: "observy.3ds.boot.gauge",
      description: "3DS observy verification gauge",
      unit: "{boot}",
      kind: mkGauge,
      gauge: MetricGauge(
        dataPoints: @[NumberDataPoint(
          attributes: attrs,
          startTimeUnixNano: t0,
          timeUnixNano: t0,
          kind: ndpDouble,
          doubleValue: 1.0)]))
    @[counter, gauge]

  proc buildLog(t0: uint64; traceId: TraceId; spanId: SpanId): LogRecord =
    var attrs = initAttributeSet()
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    LogRecord(
      timeUnixNano: t0,
      observedTimeUnixNano: t0,
      severityNumber: severityInfo,
      severityText: "INFO",
      body: AnyValue(kind: avString, strVal: "observy 3DS verification"),
      attributes: attrs,
      traceId: traceId,
      spanId: spanId)

  proc main() =
    gfxInitDefault()
    consoleInit(GFX_TOP, nil)
    logLine("observy 3DS start")
    logLine("collector: " & CollectorEndpoint)

    let rawT0 = nowUnixNano()
    let offsetNanos = Observy3dsUtcOffsetSec.int64 * 1_000_000_000'i64
    let t0 =
      if offsetNanos >= 0:
        rawT0 + uint64(offsetNanos)
      else:
        rawT0 - uint64(-offsetNanos)
    let runId = "3ds-" & $t0
    let traceId = buildTraceId(t0)
    let spanId = buildSpanId(t0)
    let resource = buildResource(runId)
    let scope = buildScope()

    var cfg = buildConfig()
    cfg.temporalitySelector = alwaysCumulative()
    var exporter = newOtlpExporter(cfg)
    try:
      let traces = exporter.record(resource, scope, @[buildSpan(t0, traceId, spanId)])
      logLine("traces: " & $traces.code.int)

      let metrics = exporter.record(resource, scope, buildMetrics(t0))
      logLine("metrics: " & $metrics.code.int)

      let logs = exporter.record(resource, scope, @[buildLog(t0, traceId, spanId)])
      logLine("logs: " & $logs.code.int)
      logLine("run.id: " & runId)
      let ok = traces.code.int == 200 and metrics.code.int == 200 and logs.code.int == 200
      writeResult(
        if ok: "PASS" else: "FAIL",
        "collector=" & CollectorEndpoint & "\n" &
        "run.id=" & runId & "\n" &
        "timestamp.raw_unix_nano=" & $rawT0 & "\n" &
        "timestamp.utc_offset_sec=" & $Observy3dsUtcOffsetSec & "\n" &
        "timestamp.unix_nano=" & $t0 & "\n" &
        "traces.code=" & $traces.code.int & "\n" &
        "metrics.code=" & $metrics.code.int & "\n" &
        "logs.code=" & $logs.code.int)
    except CatchableError as e:
      writeResult(
        "FAIL",
        "collector=" & CollectorEndpoint & "\n" &
        "run.id=" & runId & "\n" &
        "timestamp.raw_unix_nano=" & $rawT0 & "\n" &
        "timestamp.utc_offset_sec=" & $Observy3dsUtcOffsetSec & "\n" &
        "timestamp.unix_nano=" & $t0 & "\n" &
        "error=" & $e.name & ": " & e.msg)
      logLine("export failed: " & $e.name & ": " & e.msg)
    finally:
      exporter.close()

    logLine("START exits")
    var frames = 0
    while aptMainLoop() and frames < 1800:
      inc frames
      gspWaitForVBlank()
      gfxFlushBuffers()
      gfxSwapBuffers()
      hidScanInput()
      if (hidKeysDown() and KEY_START) != 0:
        break

    gfxExit()

  main()
