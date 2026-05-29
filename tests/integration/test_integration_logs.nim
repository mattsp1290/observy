## Integration test for the Logs signal against a live OTel collector.
## Requires docker-compose up with collector-config.yml (see CLAUDE.md).
## Run with: nim c --mm:orc --threads:on -d:liveCollector -r tests/integration/test_integration_logs.nim
import unittest
import std/strutils
import ../../src/observy
import ./harness

when defined(liveCollector):
  const
    TID = [0xAA'u8,0xBB,0xCC,0xDD,0xEE,0xFF,0x00,0x11,
           0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99]

  proc makeILogResource(svc: string): Resource =
    var a = initAttributeSet()
    a.add("service.name", AnyValue(kind: avString, strVal: svc))
    Resource(attributes: a)

  proc makeILogScope(): InstrumentationScope =
    InstrumentationScope(name: "observy-test-scope", attributes: initAttributeSet())

  proc hasLogBody(c: string): bool {.gcsafe.} =
    strutils.contains(c, "integration-log-body")

  proc hasLogWarn(c: string): bool {.gcsafe.} =
    strutils.contains(c, "integration-log-warn")

  suite "Logs integration — live collector":
    setup:
      # Use 127.0.0.1 explicitly; see traces integration test and persistent memory.
      var cfg = loadFromEnv()
      cfg.signalEndpoints[SigLogs] = "http://127.0.0.1:4318/v1/logs"
      cfg.protocol = otlpProtoHttp
      var exporter = newOtlpExporter(cfg)
      waitForCollector()
      clearCollectorOutput()

    teardown:
      exporter.close()

    test "log record appears in collector output with correct body and traceId":
      let res   = makeILogResource("observy-test")
      let scope = makeILogScope()
      let log   = LogRecord(
        timeUnixNano:   1_000_000_000_000_000_000'u64,
        severityNumber: severityInfo,
        severityText:   "INFO",
        body:           AnyValue(kind: avString, strVal: "integration-log-body"),
        attributes:     initAttributeSet(),
        traceId:        TID,
      )

      let resp = exporter.record(res, scope, @[log])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasLogBody, timeoutMs = 10000)

      assertServiceName(json, "observy-test")
      assertLogBody(json, "integration-log-body")
      assertTraceIdHex(json, "aabbccddeeff00112233445566778899")
      check strutils.contains(json, "\"severityText\":\"INFO\"")

    test "wrong log body assertion fails as expected":
      let res   = makeILogResource("observy-test")
      let scope = makeILogScope()
      let log   = LogRecord(
        timeUnixNano:   1'u64,
        severityNumber: severityWarn,
        body:           AnyValue(kind: avString, strVal: "integration-log-warn"),
        attributes:     initAttributeSet(),
      )

      let resp = exporter.record(res, scope, @[log])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasLogWarn, timeoutMs = 10000)

      expect AssertionDefect:
        assertLogBody(json, "wrong-body-content")

else:
  suite "Logs integration (skipped — no -d:liveCollector)":
    test "skipped: compile with -d:liveCollector to run against live collector":
      skip()
