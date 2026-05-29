## Integration test for the Metrics signal against a live OTel collector.
## Requires docker-compose up with collector-config.yml (see CLAUDE.md).
## Run with: nim c --mm:orc --threads:on -d:liveCollector -r tests/integration/test_integration_metrics.nim
import unittest
import std/strutils
import ../../src/observy
import ./harness

when defined(liveCollector):
  proc makeIMetricResource(): Resource =
    var a = initAttributeSet()
    a.add("service.name", AnyValue(kind: avString, strVal: "observy-test"))
    Resource(attributes: a)

  proc makeIMetricScope(): InstrumentationScope =
    InstrumentationScope(name: "observy-test-scope", attributes: initAttributeSet())

  proc makeCounter(name: string; value: int64): Metric =
    Metric(
      name: name,
      kind: mkSum,
      sum: MetricSum(
        dataPoints: @[NumberDataPoint(
          attributes:   initAttributeSet(),
          timeUnixNano: 1_000_000_000_000_000_000'u64,
          kind: ndpInt,
          intValue: value,
        )],
        aggregationTemporality: aggTempCumulative,
        isMonotonic: true,
      ),
    )

  proc makeHistogram(name: string): Metric =
    Metric(
      name: name,
      kind: mkHistogram,
      histogram: MetricHistogram(
        dataPoints: @[HistogramDataPoint(
          attributes:     initAttributeSet(),
          timeUnixNano:   1_000_000_000_000_000_000'u64,
          count:          5'u64,
          explicitBounds: @[0.0, 5.0, 10.0, 25.0, 50.0],
          bucketCounts:   @[0'u64, 1'u64, 2'u64, 1'u64, 1'u64, 0'u64],
        )],
        aggregationTemporality: aggTempCumulative,
      ),
    )

  proc hasCounter(c: string): bool {.gcsafe.} =
    strutils.contains(c, "observy.test.counter")

  proc hasLatency(c: string): bool {.gcsafe.} =
    strutils.contains(c, "observy.test.latency")

  suite "Metrics integration — live collector":
    setup:
      # Use 127.0.0.1 explicitly to avoid IPv6 ::1 resolution hang.
      var cfg = loadFromEnv()
      cfg.signalEndpoints[SigMetrics] = "http://127.0.0.1:4318/v1/metrics"
      cfg.protocol = otlpProtoHttp
      cfg.temporalitySelector = alwaysCumulative()
      var exporter = newOtlpExporter(cfg)
      waitForCollector()
      clearCollectorOutput()

    teardown:
      exporter.close()

    test "counter metric appears in collector output with correct value":
      let res   = makeIMetricResource()
      let scope = makeIMetricScope()
      let counter = makeCounter("observy.test.counter", 42)

      let resp = exporter.record(res, scope, @[counter])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasCounter, timeoutMs = 10000)

      assertServiceName(json, "observy-test")
      assertMetricName(json, "observy.test.counter")
      check strutils.contains(json, "\"intValue\":\"42\"")

    test "temporality selector alwaysCumulative applies to outbound counter":
      let res   = makeIMetricResource()
      let scope = makeIMetricScope()
      var m = makeCounter("observy.test.counter", 1)
      m.sum.aggregationTemporality = aggTempDelta   # start as delta

      let resp = exporter.record(res, scope, @[m])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasCounter, timeoutMs = 10000)

      # The exporter applies alwaysCumulative; collector output should show CUMULATIVE (2)
      assertMetricName(json, "observy.test.counter")
      check strutils.contains(json, "\"aggregationTemporality\":2")

    test "histogram metric appears in collector output with buckets":
      let res   = makeIMetricResource()
      let scope = makeIMetricScope()
      let hist  = makeHistogram("observy.test.latency")

      let resp = exporter.record(res, scope, @[hist])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasLatency, timeoutMs = 10000)

      assertServiceName(json, "observy-test")
      assertMetricName(json, "observy.test.latency")
      check strutils.contains(json, "\"explicitBounds\"")

    test "wrong metric name assertion fails as expected":
      let res   = makeIMetricResource()
      let scope = makeIMetricScope()
      let counter = makeCounter("observy.test.counter", 1)

      let resp = exporter.record(res, scope, @[counter])
      check int(resp.code) in 200 .. 299

      let json = waitForOutput(hasCounter, timeoutMs = 10000)

      expect AssertionDefect:
        assertMetricName(json, "wrong.metric.name")

else:
  suite "Metrics integration (skipped — no -d:liveCollector)":
    test "skipped: compile with -d:liveCollector to run against live collector":
      skip()
