## Minimal logs example: build a log record and record() it.
## Compile: nim c --path:src --mm:orc --threads:on examples/logs.nim
import observy

var attrs = initAttributeSet()
attrs.add("service.name", AnyValue(kind: avString, strVal: "demo"))
let resource = Resource(attributes: attrs)
let scope = InstrumentationScope(name: "demo-app", attributes: initAttributeSet())

let log = LogRecord(
  timeUnixNano: 1_700_000_000_000_000_000'u64,
  severityNumber: severityInfo, severityText: "INFO",
  body: AnyValue(kind: avString, strVal: "request completed"),
  attributes: initAttributeSet())

when isMainModule:
  var exporter = newOtlpExporter(loadFromEnv())
  let resp = exporter.record(resource, scope, @[log])
  echo "logs export status: ", resp.code
  exporter.close()
