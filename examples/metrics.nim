## metrics.nim — minimal runnable metrics example for observy.
##
## Compile and run:
##   nim c -r examples/metrics.nim
##
## With a live collector:
##   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
##   OTEL_SERVICE_NAME=my-service nim c -r examples/metrics.nim
import std/os
import std/options
import observy

# ---------------------------------------------------------------------------
# Resource and scope
# ---------------------------------------------------------------------------
let svcName = getEnv("OTEL_SERVICE_NAME", "observy-example")
var resAttrs = initAttributeSet()
resAttrs.add("service.name", AnyValue(kind: avString, strVal: svcName))
let resource = Resource(attributes: resAttrs)
let scope = InstrumentationScope(
  name: "examples/metrics",
  version: "0.1.0",
  attributes: initAttributeSet())

# ---------------------------------------------------------------------------
# Counter: monotonic Sum (HTTP requests total)
# ---------------------------------------------------------------------------
var counterAttrs = initAttributeSet()
counterAttrs.add("http.method", AnyValue(kind: avString, strVal: "POST"))
counterAttrs.add("http.route",  AnyValue(kind: avString, strVal: "/api/users"))
counterAttrs.add("http.status", AnyValue(kind: avString, strVal: "201"))
let counter = Metric(
  name:        "http.requests.total",
  description: "Total HTTP requests",
  unit:        "{request}",
  kind: mkSum,
  sum: MetricSum(
    dataPoints: @[NumberDataPoint(
      attributes:   counterAttrs,
      timeUnixNano: 1_700_000_000_000_000_000'u64,
      kind: ndpInt, intValue: 42)],
    aggregationTemporality: aggTempCumulative,
    isMonotonic: true))

# ---------------------------------------------------------------------------
# Gauge: current memory usage
# ---------------------------------------------------------------------------
var gaugeAttrs = initAttributeSet()
gaugeAttrs.add("process.type", AnyValue(kind: avString, strVal: "worker"))
let gauge = Metric(
  name:        "process.memory.bytes",
  description: "Current process memory in bytes",
  unit:        "By",
  kind: mkGauge,
  gauge: MetricGauge(
    dataPoints: @[NumberDataPoint(
      attributes:   gaugeAttrs,
      timeUnixNano: 1_700_000_000_000_000_000'u64,
      kind: ndpDouble, doubleValue: 52_428_800.0)]))

# ---------------------------------------------------------------------------
# Histogram: request latency
# ---------------------------------------------------------------------------
var histAttrs = initAttributeSet()
histAttrs.add("http.route", AnyValue(kind: avString, strVal: "/api/users"))
let histogram = Metric(
  name:        "http.request.duration",
  description: "HTTP request duration in milliseconds",
  unit:        "ms",
  kind: mkHistogram,
  histogram: MetricHistogram(
    dataPoints: @[HistogramDataPoint(
      attributes:     histAttrs,
      timeUnixNano:   1_700_000_000_000_000_000'u64,
      count:          100'u64,
      sum:            some(8500.0),
      min:            some(12.0),
      max:            some(850.0),
      explicitBounds: @[10.0, 50.0, 100.0, 500.0, 1000.0],
      bucketCounts:   @[5'u64, 45'u64, 30'u64, 15'u64, 4'u64, 1'u64])],
    aggregationTemporality: aggTempCumulative))

# ---------------------------------------------------------------------------
# Export with alwaysCumulative selector (default, but explicit here)
# ---------------------------------------------------------------------------
when isMainModule:
  var cfg = loadFromEnv()
  cfg.temporalitySelector = alwaysCumulative()
  var exporter = newOtlpExporter(cfg)
  let resp = exporter.record(resource, scope, @[counter, gauge, histogram])
  echo "metrics export: ", resp.code, " (200=OK)"
  exporter.close()
