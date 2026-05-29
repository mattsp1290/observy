import unittest
import std/json
import ../src/observy/anyvalue
import ../src/observy/proto
import ../src/observy/resource
import std/sequtils
import ../src/observy/traces
import ./testutil

suite "Traces data model":
  test "TraceId and SpanId are correct byte arrays":
    var tid: TraceId
    var sid: SpanId
    check tid.len == 16
    check sid.len == 8

  test "SpanKind values match OTLP spec":
    check ord(skUnspecified) == 0
    check ord(skInternal)    == 1
    check ord(skServer)      == 2
    check ord(skClient)      == 3
    check ord(skProducer)    == 4
    check ord(skConsumer)    == 5

  test "StatusCode values match OTLP spec":
    check ord(statusUnset)  == 0
    check ord(statusOk)     == 1
    check ord(statusError)  == 2

  test "SpanStatus construction":
    let s = SpanStatus(code: statusOk, message: "")
    check s.code == statusOk

  test "SpanEvent construction":
    var attrs = initAttributeSet()
    attrs.add("key", AnyValue(kind: avString, strVal: "val"))
    let ev = SpanEvent(
      timeUnixNano: 1_000_000_000'u64,
      name: "my.event",
      attributes: attrs,
      droppedAttributesCount: 0'u32,
    )
    check ev.name == "my.event"
    check ev.timeUnixNano == 1_000_000_000'u64
    check ev.attributes.pairs.len == 1

  test "SpanLink construction":
    var tid: TraceId
    var sid: SpanId
    tid[0] = 0xAB'u8
    sid[0] = 0xCD'u8
    let link = SpanLink(
      traceId: tid,
      spanId: sid,
      traceState: "",
      attributes: initAttributeSet(),
      droppedAttributesCount: 0'u32,
      flags: 1'u32,
    )
    check link.traceId[0] == 0xAB'u8
    check link.spanId[0] == 0xCD'u8
    check link.flags == 1'u32

  test "Span full construction":
    var traceId: TraceId
    var spanId: SpanId
    var parentId: SpanId
    for i in 0 ..< 16: traceId[i] = byte(i)
    for i in 0 ..< 8:  spanId[i]  = byte(i + 16)

    var attrs = initAttributeSet()
    attrs.add("http.method", AnyValue(kind: avString, strVal: "GET"))

    let ev = SpanEvent(
      timeUnixNano: 100'u64,
      name: "exception",
      attributes: initAttributeSet(),
      droppedAttributesCount: 0'u32,
    )

    let link = SpanLink(
      traceId: traceId,
      spanId: spanId,
      traceState: "",
      attributes: initAttributeSet(),
      droppedAttributesCount: 0'u32,
      flags: 0'u32,
    )

    let span = Span(
      traceId: traceId,
      spanId: spanId,
      parentSpanId: parentId,
      traceState: "",
      name: "GET /api/v1/users",
      kind: skServer,
      startTimeUnixNano: 1_000_000'u64,
      endTimeUnixNano: 2_000_000'u64,
      attributes: attrs,
      droppedAttributesCount: 0'u32,
      events: @[ev],
      droppedEventsCount: 0'u32,
      links: @[link],
      droppedLinksCount: 0'u32,
      status: SpanStatus(code: statusOk, message: ""),
      flags: 1'u32,
    )

    check span.name == "GET /api/v1/users"
    check span.kind == skServer
    check span.traceId[0] == 0'u8
    check span.spanId[0] == 16'u8
    check span.attributes.pairs.len == 1
    check span.events.len == 1
    check span.links.len == 1
    check span.status.code == statusOk
    check span.flags == 1'u32

  test "Span default values are zero":
    let span = Span(
      name: "minimal",
      attributes: initAttributeSet(),
    )
    check span.kind == skUnspecified
    check span.status.code == statusUnset
    check span.events.len == 0
    check span.links.len == 0
    check span.droppedAttributesCount == 0'u32
    check span.flags == 0'u32

# ---------------------------------------------------------------------------
# Proto encoding tests
# ---------------------------------------------------------------------------

proc makeFullSpan(): Span =
  ## Constructs the same Span as in tools/gen_fixtures.py (full_span.bin)
  const
    TID = [0x4b'u8,0xf9,0x2f,0x35,0x77,0xb3,0x4d,0xa6,
           0xa3,0xce,0x92,0x9d,0x0e,0x0e,0x47,0x36]
    SID = [0x00'u8,0xf0,0x67,0xaa,0x0b,0xa9,0x02,0xb7]
    PID = [0xaa'u8,0xbb,0xcc,0xdd,0x11,0x22,0x33,0x44]  # parent
    LTD = [0xff'u8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
           0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff]
    LSI = [0x11'u8,0x22,0x33,0x44,0x55,0x66,0x77,0x88]

  var attrs = initAttributeSet()
  attrs.add("http.method",      AnyValue(kind: avString, strVal: "POST"))
  attrs.add("http.url",         AnyValue(kind: avString, strVal: "https://api.example.com/users"))
  attrs.add("http.status_code", AnyValue(kind: avInt,    intVal: 201))
  attrs.add("latency.ms",       AnyValue(kind: avDouble, dblVal: 12.5))
  attrs.add("http.success",     AnyValue(kind: avBool,   boolVal: true))
  attrs.add("request.id",       AnyValue(kind: avBytes,  bytesVal: @[0x01'u8, 0x02, 0x03, 0x04]))

  var evAttrs = initAttributeSet()
  evAttrs.add("user.id", AnyValue(kind: avString, strVal: "u-12345"))
  let ev = SpanEvent(timeUnixNano: 1_000_000_000_500_000_000'u64,
                     name: "user.created", attributes: evAttrs)

  var lkAttrs = initAttributeSet()
  lkAttrs.add("link.type", AnyValue(kind: avString, strVal: "child_of"))
  let lk = SpanLink(traceId: LTD, spanId: LSI, attributes: lkAttrs)

  Span(
    traceId:           TID,
    spanId:            SID,
    parentSpanId:      PID,
    traceState:        "rojo=00f067aa0ba902b7",
    name:              "POST /api/users",
    kind:              skServer,
    startTimeUnixNano: 1_000_000_000_000_000_000'u64,
    endTimeUnixNano:   1_000_000_002_000_000_000'u64,
    attributes:        attrs,
    events:            @[ev],
    links:             @[lk],
    status:            SpanStatus(code: statusOk),
    flags:             1'u32,
  )

suite "Traces proto encoding":
  test "minimal_span — root span, no parent, fixed64 timestamps":
    const
      TID = [0x4b'u8,0xf9,0x2f,0x35,0x77,0xb3,0x4d,0xa6,
             0xa3,0xce,0x92,0x9d,0x0e,0x0e,0x47,0x36]
      SID = [0x00'u8,0xf0,0x67,0xaa,0x0b,0xa9,0x02,0xb7]
    var w: ProtoWriter
    let s = Span(
      traceId: TID, spanId: SID, name: "GET /api/users",
      kind: skServer,
      startTimeUnixNano: 1_000_000_000_000_000_000'u64,
      endTimeUnixNano:   1_000_000_001_000_000_000'u64,
      attributes: initAttributeSet(),
    )
    protoEncodeSpan(w, s)
    check w.buf == readBin("tests/fixtures/proto/minimal_span.bin")

  test "full_span.bin — all fields, attributes, event, link, status":
    var w: ProtoWriter
    protoEncodeSpan(w, makeFullSpan())
    check w.buf == readBin("tests/fixtures/proto/full_span.bin")

suite "Traces JSON encoding":
  test "jsonEncodeSpan produces valid JSON with hex traceId/spanId":
    let s = makeFullSpan()
    let j = parseJson(jsonEncodeSpan(s))
    check j["traceId"].getStr() == "4bf92f3577b34da6a3ce929d0e0e4736"
    check j["traceId"].getStr().len == 32
    check j["spanId"].getStr() == "00f067aa0ba902b7"
    check j["parentSpanId"].getStr() == "aabbccdd11223344"
    check j["name"].getStr() == "POST /api/users"
    check j["kind"].getInt() == 2         # integer, not string "SERVER"
    check j["startTimeUnixNano"].kind == JString
    check j["flags"].getInt() == 1

  test "jsonEncodeSpan int attribute is quoted string":
    let s = makeFullSpan()
    let j = parseJson(jsonEncodeSpan(s))
    var found = false
    for attr in j["attributes"]:
      if attr["key"].getStr() == "http.status_code":
        check attr["value"]["intValue"].kind == JString
        check attr["value"]["intValue"].getStr() == "201"
        found = true
    check found

  test "jsonEncodeSpan bytes attribute is base64":
    let s = makeFullSpan()
    let j = parseJson(jsonEncodeSpan(s))
    var found = false
    for attr in j["attributes"]:
      if attr["key"].getStr() == "request.id":
        check attr["value"]["bytesValue"].getStr() == "AQIDBA=="
        found = true
    check found

  test "spanToJson produces ExportTraceServiceRequest structure":
    let s = makeFullSpan()
    let j = parseJson(spanToJson(Resource(attributes: initAttributeSet()),
                                 InstrumentationScope(attributes: initAttributeSet()),
                                 @[s]))
    check j.hasKey("resourceSpans")
    check j["resourceSpans"][0].hasKey("resource")
    check j["resourceSpans"][0]["scopeSpans"][0]["spans"][0]["name"].getStr() == "POST /api/users"

  test "root span omits parentSpanId":
    let s = Span(name: "root", traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
                 spanId: [0x01'u8, 0,0,0,0,0,0,0], attributes: initAttributeSet())
    let j = parseJson(jsonEncodeSpan(s))
    check not j.hasKey("parentSpanId")

  test "status with message but unset code omits code field":
    # Exercises the status branch where only a message is present (code stays 0).
    let s = Span(name: "s", traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
                 spanId: [0x01'u8, 0,0,0,0,0,0,0], attributes: initAttributeSet(),
                 status: SpanStatus(code: statusUnset, message: "boom"))
    let j = parseJson(jsonEncodeSpan(s))
    check j["status"]["message"].getStr() == "boom"
    check not j["status"].hasKey("code")   # statusUnset (0) omitted

  test "status with OK code emits code field":
    let s = Span(name: "s", traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
                 spanId: [0x01'u8, 0,0,0,0,0,0,0], attributes: initAttributeSet(),
                 status: SpanStatus(code: statusOk))
    let j = parseJson(jsonEncodeSpan(s))
    check j["status"]["code"].getInt() == 1

proc protoFieldNumbers(buf: seq[byte]): seq[uint32] =
  var r = ProtoReader(data: buf)
  while r.pos < buf.len:
    let (fn, wt) = r.readTag()
    result.add(fn)
    r.skipField(wt)

suite "Traces attribute limit enforcement":
  test "AttributeSet drops and counts excess attributes":
    var attrs = initAttributeSet()  # maxCount = 128
    for i in 0 ..< 130:
      attrs.add("k" & $i, AnyValue(kind: avString, strVal: "v"))
    check attrs.pairs.len == 128
    check attrs.dropped == 2'u32

  test "attribute limit — only 128 attrs in proto encoded span":
    var attrs = initAttributeSet()
    for i in 0 ..< 130:
      attrs.add("k" & $i, AnyValue(kind: avString, strVal: "v"))
    let span = Span(
      name: "limit-test",
      traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      spanId: [0x01'u8, 0,0,0,0,0,0,0],
      attributes: attrs,
      droppedAttributesCount: attrs.dropped,
    )
    var w: ProtoWriter
    protoEncodeSpan(w, span)
    let fields = protoFieldNumbers(w.buf)
    # field 9 = attributes (repeated), field 10 = droppedAttributesCount
    check fields.count(9'u32) == 128
    check 10'u32 in fields

  test "droppedAttributesCount emitted in JSON when set from attrs.dropped":
    var attrs = initAttributeSet()
    for i in 0 ..< 130:
      attrs.add("k" & $i, AnyValue(kind: avString, strVal: "v"))
    let span = Span(
      name: "limit-test",
      traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      spanId: [0x01'u8, 0,0,0,0,0,0,0],
      attributes: attrs,
      droppedAttributesCount: attrs.dropped,
    )
    let j = parseJson(jsonEncodeSpan(span))
    check j["attributes"].len == 128
    check j["droppedAttributesCount"].getInt() == 2

suite "Traces SpanEvent and SpanLink proto":
  test "SpanEvent proto encodes field 4 droppedAttributesCount when set":
    var evAttrs = initAttributeSet()
    for i in 0 ..< 130:
      evAttrs.add("ek" & $i, AnyValue(kind: avString, strVal: "x"))
    let ev = SpanEvent(
      timeUnixNano: 1_000_000'u64,
      name: "overflowed-event",
      attributes: evAttrs,
      droppedAttributesCount: evAttrs.dropped,
    )
    var w: ProtoWriter
    protoEncodeSpanEvent(w, ev)
    let fields = protoFieldNumbers(w.buf)
    check fields.count(3'u32) == 128   # attributes
    check 4'u32 in fields              # droppedAttributesCount

  test "SpanLink proto encodes traceState and field 5 droppedAttributesCount":
    var lkAttrs = initAttributeSet()
    for i in 0 ..< 130:
      lkAttrs.add("lk" & $i, AnyValue(kind: avString, strVal: "y"))
    let lk = SpanLink(
      traceId: [0xFF'u8, 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
                0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF],
      spanId: [0x11'u8, 0x22,0x33,0x44,0x55,0x66,0x77,0x88],
      traceState: "vendor=abc",
      attributes: lkAttrs,
      droppedAttributesCount: lkAttrs.dropped,
    )
    var w: ProtoWriter
    protoEncodeSpanLink(w, lk)
    let fields = protoFieldNumbers(w.buf)
    check 3'u32 in fields              # traceState
    check fields.count(4'u32) == 128   # attributes
    check 5'u32 in fields              # droppedAttributesCount

suite "Traces SpanStatus proto encoding":
  test "SpanStatus ERROR with message encodes both code and message":
    let span = Span(
      name: "error-span",
      traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      spanId: [0x01'u8, 0,0,0,0,0,0,0],
      attributes: initAttributeSet(),
      status: SpanStatus(code: statusError, message: "something went wrong"),
    )
    var w: ProtoWriter
    protoEncodeSpan(w, span)
    let fields = protoFieldNumbers(w.buf)
    check 15'u32 in fields   # status field present

  test "SpanStatus ERROR with message in JSON":
    let span = Span(
      name: "error-span",
      traceId: [0x01'u8, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
      spanId: [0x01'u8, 0,0,0,0,0,0,0],
      attributes: initAttributeSet(),
      status: SpanStatus(code: statusError, message: "something went wrong"),
    )
    let j = parseJson(jsonEncodeSpan(span))
    check j["status"]["code"].getInt() == 2
    check j["status"]["message"].getStr() == "something went wrong"
