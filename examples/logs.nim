## logs.nim — minimal runnable logs example for observy.
##
## Compile and run:
##   nim c -r examples/logs.nim
##
## With a live collector:
##   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \
##   OTEL_SERVICE_NAME=my-service nim c -r examples/logs.nim
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
  name: "examples/logs",
  version: "0.1.0",
  attributes: initAttributeSet())

# ---------------------------------------------------------------------------
# Log records covering several AnyValue body kinds
# ---------------------------------------------------------------------------
const
  TID = [0x4b'u8, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6,
         0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36]
  SID = [0x00'u8, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7]

# INFO log with trace context and attributes
var loginAttrs = initAttributeSet()
loginAttrs.add("user.id",   AnyValue(kind: avString, strVal: "u-12345"))
loginAttrs.add("ip",        AnyValue(kind: avString, strVal: "192.168.1.1"))
loginAttrs.add("attempt",   AnyValue(kind: avInt,    intVal: 1))
let loginLog = LogRecord(
  timeUnixNano:         1_700_000_000_000_000_000'u64,
  observedTimeUnixNano: 1_700_000_000_001_000_000'u64,
  severityNumber:       severityInfo,
  severityText:         "INFO",
  body:                 AnyValue(kind: avString, strVal: "user login succeeded"),
  attributes:           loginAttrs,
  flags:                1'u32,
  traceId:              TID,
  spanId:               SID)

# WARN log without trace context
var warnAttrs = initAttributeSet()
warnAttrs.add("queue.name",  AnyValue(kind: avString, strVal: "jobs"))
warnAttrs.add("queue.depth", AnyValue(kind: avInt,    intVal: 950))
let warnLog = LogRecord(
  timeUnixNano:   1_700_000_001_000_000_000'u64,
  severityNumber: severityWarn,
  severityText:   "WARN",
  body:           AnyValue(kind: avString, strVal: "queue near capacity"),
  attributes:     warnAttrs)

# ERROR log with structured kvlist body
let errorBody = AnyValue(kind: avKvList, kvlistVal: @[
  KeyValue(key: "error",   value: AnyValue(kind: avString, strVal: "connection refused")),
  KeyValue(key: "retries", value: AnyValue(kind: avInt,    intVal: 3)),
])
let errorLog = LogRecord(
  timeUnixNano:   1_700_000_002_000_000_000'u64,
  severityNumber: severityError,
  severityText:   "ERROR",
  body:           errorBody,
  attributes:     initAttributeSet())

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
when isMainModule:
  var exporter = newOtlpExporter(loadFromEnv())
  let resp = exporter.record(resource, scope, @[loginLog, warnLog, errorLog])
  echo "logs export: ", resp.code, " (200=OK)"
  exporter.close()
