import unittest
import ../src/observy/anyvalue
import ../src/observy/traces

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
