import unittest
import ../src/observy/anyvalue
import ../src/observy/traces
import ../src/observy/logs

suite "Logs data model":
  test "SeverityNumber covers all 25 spec values":
    check ord(severityUnspecified) == 0
    check ord(severityTrace)       == 1
    check ord(severityTrace2)      == 2
    check ord(severityTrace3)      == 3
    check ord(severityTrace4)      == 4
    check ord(severityDebug)       == 5
    check ord(severityDebug2)      == 6
    check ord(severityDebug3)      == 7
    check ord(severityDebug4)      == 8
    check ord(severityInfo)        == 9
    check ord(severityInfo2)       == 10
    check ord(severityInfo3)       == 11
    check ord(severityInfo4)       == 12
    check ord(severityWarn)        == 13
    check ord(severityWarn2)       == 14
    check ord(severityWarn3)       == 15
    check ord(severityWarn4)       == 16
    check ord(severityError)       == 17
    check ord(severityError2)      == 18
    check ord(severityError3)      == 19
    check ord(severityError4)      == 20
    check ord(severityFatal)       == 21
    check ord(severityFatal2)      == 22
    check ord(severityFatal3)      == 23
    check ord(severityFatal4)      == 24

  test "LogRecord full construction with all spec fields":
    var tid: TraceId
    var sid: SpanId
    for i in 0 ..< 16: tid[i] = byte(i)
    for i in 0 ..< 8:  sid[i] = byte(i + 100)

    var attrs = initAttributeSet()
    attrs.add("service.name", AnyValue(kind: avString, strVal: "my-svc"))

    let rec = LogRecord(
      timeUnixNano:           1_000_000_000'u64,
      observedTimeUnixNano:   1_000_000_001'u64,
      severityNumber:         severityInfo,
      severityText:           "INFO",
      body:                   AnyValue(kind: avString, strVal: "request completed"),
      attributes:             attrs,
      droppedAttributesCount: 0'u32,
      flags:                  1'u32,
      traceId:                tid,
      spanId:                 sid,
    )

    check rec.timeUnixNano == 1_000_000_000'u64
    check rec.observedTimeUnixNano == 1_000_000_001'u64
    check rec.severityNumber == severityInfo
    check rec.severityText == "INFO"
    check rec.body.kind == avString
    check rec.body.strVal == "request completed"
    check rec.attributes.pairs.len == 1
    check rec.flags == 1'u32
    check rec.traceId[0] == 0'u8
    check rec.spanId[0] == 100'u8

  test "LogRecord default severity is unspecified":
    let rec = LogRecord(
      body: AnyValue(kind: avString, strVal: "hello"),
      attributes: initAttributeSet(),
    )
    check rec.severityNumber == severityUnspecified
    check rec.droppedAttributesCount == 0'u32

  test "LogRecord body can be kvlist":
    let body = AnyValue(kind: avKvList, kvlistVal: @[
      KeyValue(key: "msg", value: AnyValue(kind: avString, strVal: "ok")),
    ])
    let rec = LogRecord(body: body, attributes: initAttributeSet())
    check rec.body.kind == avKvList
    check rec.body.kvlistVal.len == 1

  test "LogRecord traceId and spanId are zero by default":
    let rec = LogRecord(
      body: AnyValue(kind: avString, strVal: "x"),
      attributes: initAttributeSet(),
    )
    var zeroTid: TraceId
    var zeroSid: SpanId
    check rec.traceId == zeroTid
    check rec.spanId == zeroSid

  test "LogRecord eventName field":
    let rec = LogRecord(
      body: AnyValue(kind: avString, strVal: "my.event occurred"),
      attributes: initAttributeSet(),
      eventName: "my.event",
    )
    check rec.eventName == "my.event"

  test "LogRecord eventName defaults to empty string":
    let rec = LogRecord(
      body: AnyValue(kind: avString, strVal: "plain log"),
      attributes: initAttributeSet(),
    )
    check rec.eventName == ""
