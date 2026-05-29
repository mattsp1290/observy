import unittest
import std/json
import ../src/observy/anyvalue
import ../src/observy/proto
import ../src/observy/resource
import ../src/observy/traces
import ../src/observy/logs
import ./testutil

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

# ---------------------------------------------------------------------------
# Proto encoding tests
# ---------------------------------------------------------------------------

proc makeLogRecord(): LogRecord =
  ## Constructs the same LogRecord as in tools/gen_fixtures.py (log_record.bin)
  const
    TID = [0x4b'u8,0xf9,0x2f,0x35,0x77,0xb3,0x4d,0xa6,
           0xa3,0xce,0x92,0x9d,0x0e,0x0e,0x47,0x36]
    SID = [0x00'u8,0xf0,0x67,0xaa,0x0b,0xa9,0x02,0xb7]
  var attrs = initAttributeSet()
  attrs.add("user.id",  AnyValue(kind: avString, strVal: "u-99999"))
  attrs.add("ip",       AnyValue(kind: avString, strVal: "192.168.1.1"))
  attrs.add("attempt",  AnyValue(kind: avInt,    intVal: 1))
  LogRecord(
    timeUnixNano:         1_000_000_000_000_000_000'u64,
    observedTimeUnixNano: 1_000_000_000_100_000_000'u64,
    severityNumber:       severityInfo,
    severityText:         "INFO",
    body:                 AnyValue(kind: avString, strVal: "user login succeeded"),
    attributes:           attrs,
    flags:                1'u32,
    traceId:              TID,
    spanId:               SID,
  )

proc protoFieldNumbers(buf: seq[byte]): seq[uint32] =
  ## Decode top-level field numbers present in a proto message buffer.
  var r = ProtoReader(data: buf)
  while r.pos < buf.len:
    let (fn, wt) = r.readTag()
    result.add(fn)
    r.skipField(wt)

suite "Logs proto encoding":
  test "log_record.bin — fixed64 times, fixed32 flags, body AnyValue, attributes":
    var w: ProtoWriter
    protoEncodeLogRecord(w, makeLogRecord())
    check w.buf == readBin("tests/fixtures/proto/log_record.bin")

  test "context-less log omits traceId (field 9) and spanId (field 10)":
    # Regression: fixed-size arrays never have len 0, so writeBytes can't
    # auto-suppress an all-zero traceId/spanId. The encoder must guard explicitly.
    let rec = LogRecord(
      timeUnixNano: 1_000_000_000_000_000_000'u64,
      severityNumber: severityInfo,
      body: AnyValue(kind: avString, strVal: "no trace context"),
      attributes: initAttributeSet(),
    )
    var w: ProtoWriter
    protoEncodeLogRecord(w, rec)
    let fields = protoFieldNumbers(w.buf)
    check 9'u32 notin fields    # traceId absent
    check 10'u32 notin fields   # spanId absent

  test "log with trace context includes fields 9 and 10":
    var w: ProtoWriter
    protoEncodeLogRecord(w, makeLogRecord())
    let fields = protoFieldNumbers(w.buf)
    check 9'u32 in fields
    check 10'u32 in fields

suite "Logs JSON encoding":
  test "jsonEncodeLogRecord produces valid JSON with severity and body":
    let j = parseJson(jsonEncodeLogRecord(makeLogRecord()))
    check j["timeUnixNano"].kind == JString
    check j["timeUnixNano"].getStr() == "1000000000000000000"
    check j["severityNumber"].getInt() == 9    # INFO
    check j["severityText"].getStr() == "INFO"
    check j["body"]["stringValue"].getStr() == "user login succeeded"

  test "jsonEncodeLogRecord hex-encodes traceId and spanId":
    let j = parseJson(jsonEncodeLogRecord(makeLogRecord()))
    check j["traceId"].getStr() == "4bf92f3577b34da6a3ce929d0e0e4736"
    check j["traceId"].getStr().len == 32
    check j["spanId"].getStr() == "00f067aa0ba902b7"
    check j["spanId"].getStr().len == 16

  test "jsonEncodeLogRecord omits traceId/spanId when all-zero":
    let rec = LogRecord(body: AnyValue(kind: avString, strVal: "x"),
                        attributes: initAttributeSet())
    let j = parseJson(jsonEncodeLogRecord(rec))
    check not j.hasKey("traceId")
    check not j.hasKey("spanId")

  test "jsonEncodeLogRecord omits body when default empty-string AnyValue":
    # Matches the proto encoder, which suppresses the empty embedded body message.
    let rec = LogRecord(timeUnixNano: 1'u64, attributes: initAttributeSet())
    let j = parseJson(jsonEncodeLogRecord(rec))
    check not j.hasKey("body")

  test "jsonEncodeLogRecord includes body when explicitly set":
    let rec = LogRecord(timeUnixNano: 1'u64, attributes: initAttributeSet(),
                        body: AnyValue(kind: avString, strVal: "hello"))
    let j = parseJson(jsonEncodeLogRecord(rec))
    check j["body"]["stringValue"].getStr() == "hello"

  test "logRecordsToJson produces ExportLogsServiceRequest structure":
    let j = parseJson(logRecordsToJson(
      Resource(attributes: initAttributeSet()),
      InstrumentationScope(attributes: initAttributeSet()),
      @[makeLogRecord()]))
    check j.hasKey("resourceLogs")
    check j["resourceLogs"][0]["scopeLogs"][0]["logRecords"][0]["severityText"].getStr() == "INFO"
