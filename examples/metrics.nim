## Minimal metrics example: build a counter metric and record() it.
## Compile: nim c --path:src --mm:orc --threads:on examples/metrics.nim
import observy

var attrs = initAttributeSet()
attrs.add("service.name", AnyValue(kind: avString, strVal: "demo"))
let resource = Resource(attributes: attrs)
let scope = InstrumentationScope(name: "demo-app", attributes: initAttributeSet())

let metric = Metric(
  name: "http.requests.total", description: "Total requests", unit: "{request}",
  kind: mkSum, sum: MetricSum(
    dataPoints: @[NumberDataPoint(
      attributes: initAttributeSet(),
      timeUnixNano: 1_700_000_000_000_000_000'u64,
      kind: ndpInt, intValue: 1)],
    aggregationTemporality: aggTempCumulative, isMonotonic: true))

when isMainModule:
  var exporter = newOtlpExporter(loadFromEnv())
  let resp = exporter.record(resource, scope, @[metric])
  echo "metrics export status: ", resp.code
  exporter.close()
