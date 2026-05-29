## Minimal traces example: build a span and record() it.
## Compile: nim c --path:src --mm:orc --threads:on examples/traces.nim
import observy

var attrs = initAttributeSet()
attrs.add("service.name", AnyValue(kind: avString, strVal: "demo"))
let resource = Resource(attributes: attrs)
let scope = InstrumentationScope(name: "demo-app", version: "0.1.0",
                                 attributes: initAttributeSet())

var spanAttrs = initAttributeSet()
spanAttrs.add("http.method", AnyValue(kind: avString, strVal: "GET"))
var tid: TraceId
var sid: SpanId
for i in 0 ..< 16: tid[i] = byte(i + 1)
for i in 0 ..< 8:  sid[i] = byte(i + 1)
let span = Span(
  traceId: tid, spanId: sid, name: "GET /", kind: skServer,
  startTimeUnixNano: 1_700_000_000_000_000_000'u64,
  endTimeUnixNano:   1_700_000_000_500_000_000'u64,
  attributes: spanAttrs, status: SpanStatus(code: statusOk))

when isMainModule:
  # Synchronous: one request to the configured endpoint (OTEL_* env vars).
  var exporter = newOtlpExporter(loadFromEnv())
  let resp = exporter.record(resource, scope, @[span])
  echo "traces export status: ", resp.code
  exporter.close()
