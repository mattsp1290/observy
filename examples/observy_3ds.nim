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

    TID = [0x4b'u8, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6,
           0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36]
    SID = [0x00'u8, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7]

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

  proc buildSpan(t0: uint64): Span =
    var attrs = initAttributeSet()
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    Span(
      traceId: TID,
      spanId: SID,
      name: "boot",
      kind: skInternal,
      startTimeUnixNano: t0,
      endTimeUnixNano: t0 + 1_000_000'u64,
      attributes: attrs,
      status: SpanStatus(code: statusOk))

  proc buildMetric(t0: uint64): Metric =
    var attrs = initAttributeSet()
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    Metric(
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

  proc buildLog(t0: uint64): LogRecord =
    var attrs = initAttributeSet()
    attrs.add("device", AnyValue(kind: avString, strVal: "nintendo-3ds"))
    LogRecord(
      timeUnixNano: t0,
      observedTimeUnixNano: t0,
      severityNumber: severityInfo,
      severityText: "INFO",
      body: AnyValue(kind: avString, strVal: "observy 3DS verification"),
      attributes: attrs,
      traceId: TID,
      spanId: SID)

  proc main() =
    gfxInitDefault()
    consoleInit(GFX_TOP, nil)
    logLine("observy 3DS start")
    logLine("collector: " & CollectorEndpoint)

    let t0 = nowUnixNano()
    let runId = "3ds-" & $t0
    let resource = buildResource(runId)
    let scope = buildScope()

    var cfg = buildConfig()
    cfg.temporalitySelector = alwaysCumulative()
    var exporter = newOtlpExporter(cfg)
    try:
      let traces = exporter.record(resource, scope, @[buildSpan(t0)])
      logLine("traces: " & $traces.code.int)

      let metrics = exporter.record(resource, scope, @[buildMetric(t0)])
      logLine("metrics: " & $metrics.code.int)

      let logs = exporter.record(resource, scope, @[buildLog(t0)])
      logLine("logs: " & $logs.code.int)
      logLine("run.id: " & runId)
    except CatchableError as e:
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
