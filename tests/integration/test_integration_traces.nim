## Integration test for the Traces signal against a live OTel collector.
## Requires docker-compose up with collector-config.yml (see CLAUDE.md).
## Run with: nim c --mm:orc --threads:on -d:liveCollector -r tests/integration/test_integration_traces.nim
import unittest
import std/strutils
import ../../src/observy
import ./harness

when defined(liveCollector):
  const
    TID = [0x4b'u8,0xf9,0x2f,0x35,0x77,0xb3,0x4d,0xa6,
           0xa3,0xce,0x92,0x9d,0x0e,0x0e,0x47,0x36]
    SID = [0x00'u8,0xf0,0x67,0xaa,0x0b,0xa9,0x02,0xb7]

  proc makeITestResource(svc: string): Resource =
    var a = initAttributeSet()
    a.add("service.name", AnyValue(kind: avString, strVal: svc))
    Resource(attributes: a)

  proc makeITestScope(): InstrumentationScope =
    InstrumentationScope(name: "observy-test-scope", attributes: initAttributeSet())

  proc makeITestSpan(name: string): Span =
    Span(
      traceId:           TID,
      spanId:            SID,
      name:              name,
      kind:              skServer,
      startTimeUnixNano: 1_000_000_000_000_000_000'u64,
      endTimeUnixNano:   1_000_000_001_000_000_000'u64,
      attributes:        initAttributeSet(),
    )

  proc hasIntegrationTest(c: string): bool {.gcsafe.} =
    strutils.contains(c, "integration-test")

  proc hasIntegrationTest2(c: string): bool {.gcsafe.} =
    strutils.contains(c, "integration-test-2")

  suite "Traces integration — live collector":
    setup:
      # Must use 127.0.0.1, not localhost — stdlib httpclient may resolve to
      # ::1 on systems with IPv6 loopback preferred, and the collector only
      # listens on 0.0.0.0 (IPv4). See persistent memory note.
      var cfg = loadFromEnv()
      cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:4318/v1/traces"
      cfg.protocol = otlpProtoHttp
      var exporter = newOtlpExporter(cfg)
      waitForCollector()
      clearCollectorOutput()

    teardown:
      exporter.close()

    test "single span appears in collector output":
      let res   = makeITestResource("observy-test")
      let scope = makeITestScope()
      let span  = makeITestSpan("integration-test")

      let resp = exporter.record(res, scope, @[span])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasIntegrationTest, timeoutMs = 10000)

      assertServiceName(json, "observy-test")
      assertSpanCount(json, 1)
      assertTraceIdHex(json, "4bf92f3577b34da6a3ce929d0e0e4736")
      check strutils.contains(json, "integration-test")

    test "wrong serviceName assertion fails as expected":
      let res   = makeITestResource("observy-test")
      let scope = makeITestScope()
      let span  = makeITestSpan("integration-test-2")

      let resp = exporter.record(res, scope, @[span])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasIntegrationTest2, timeoutMs = 10000)

      expect AssertionDefect:
        assertServiceName(json, "wrong-service-name")

else:
  suite "Traces integration (skipped — no -d:liveCollector)":
    test "skipped: compile with -d:liveCollector to run against live collector":
      skip()
