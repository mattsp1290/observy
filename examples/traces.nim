## traces.nim — minimal runnable traces example for observy.
##
## Compile and run:
##   nim c -r examples/traces.nim
##
## With a live collector (docker compose up):
##   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
##   OTEL_SERVICE_NAME=my-service nim c -r examples/traces.nim
##   docker compose logs otelcol   # expect 2 spans
import std/os
import observy

# ---------------------------------------------------------------------------
# Resource and scope
# ---------------------------------------------------------------------------
let svcName = getEnv("OTEL_SERVICE_NAME", "observy-example")
var resAttrs = initAttributeSet()
resAttrs.add("service.name", AnyValue(kind: avString, strVal: svcName))
let resource = Resource(attributes: resAttrs)
let scope = InstrumentationScope(
  name: "examples/traces",
  version: "0.1.0",
  attributes: initAttributeSet())

# ---------------------------------------------------------------------------
# Parent span: server span with event, link, and attributes
# ---------------------------------------------------------------------------
const
  TID = [0x4b'u8, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6,
         0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36]
  SID = [0x00'u8, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7]
  CSID = [0x11'u8, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]

var parentAttrs = initAttributeSet()
parentAttrs.add("http.method",      AnyValue(kind: avString, strVal: "POST"))
parentAttrs.add("http.target",      AnyValue(kind: avString, strVal: "/api/users"))
parentAttrs.add("http.status_code", AnyValue(kind: avInt,    intVal: 201))

var evAttrs = initAttributeSet()
evAttrs.add("user.id", AnyValue(kind: avString, strVal: "u-99999"))
let ev = SpanEvent(
  timeUnixNano: 1_700_000_000_100_000_000'u64,
  name: "user.created",
  attributes: evAttrs)

var lkAttrs = initAttributeSet()
lkAttrs.add("link.type", AnyValue(kind: avString, strVal: "child_of"))
let lk = SpanLink(
  traceId:    TID,
  spanId:     SID,
  traceState: "vendor=abc",
  attributes: lkAttrs)

let parentSpan = Span(
  traceId:           TID,
  spanId:            SID,
  name:              "POST /api/users",
  kind:              skServer,
  startTimeUnixNano: 1_700_000_000_000_000_000'u64,
  endTimeUnixNano:   1_700_000_000_500_000_000'u64,
  attributes:        parentAttrs,
  events:            @[ev],
  links:             @[lk],
  status:            SpanStatus(code: statusOk))

# ---------------------------------------------------------------------------
# Child span: internal span referencing the parent
# ---------------------------------------------------------------------------
var childAttrs = initAttributeSet()
childAttrs.add("db.system",    AnyValue(kind: avString, strVal: "postgresql"))
childAttrs.add("db.operation", AnyValue(kind: avString, strVal: "INSERT"))
childAttrs.add("db.table",     AnyValue(kind: avString, strVal: "users"))

let childSpan = Span(
  traceId:           TID,
  spanId:            CSID,
  parentSpanId:      SID,
  name:              "db.insert users",
  kind:              skInternal,
  startTimeUnixNano: 1_700_000_000_050_000_000'u64,
  endTimeUnixNano:   1_700_000_000_200_000_000'u64,
  attributes:        childAttrs,
  status:            SpanStatus(code: statusOk))

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
when isMainModule:
  var exporter = newOtlpExporter(loadFromEnv())
  let resp = exporter.record(resource, scope, @[parentSpan, childSpan])
  echo "traces export: ", resp.code, " (200=OK)"
  exporter.close()
