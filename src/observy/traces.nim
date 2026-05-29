# Traces signal data model and OTLP encoding
import ./anyvalue
import ./proto
import ./resource
import ./json_encode

# opentelemetry-proto v1.10.0 field numbers
# trace/v1/trace.proto
#   Span: trace_id=1, span_id=2, trace_state=3, parent_span_id=4, name=5,
#         kind=6, start_time_unix_nano=7, end_time_unix_nano=8, attributes=9,
#         dropped_attributes_count=10, events=11, dropped_events_count=12,
#         links=13, dropped_links_count=14, status=15, flags=16
#   Span.Event: time_unix_nano=1, name=2, attributes=3, dropped_attributes_count=4
#   Span.Link: trace_id=1, span_id=2, trace_state=3, attributes=4,
#              dropped_attributes_count=5, flags=6
#   Status: message=2, code=3

type
  TraceId* = array[16, byte]
  SpanId*  = array[8, byte]

  SpanKind* = enum
    skUnspecified = 0
    skInternal    = 1
    skServer      = 2
    skClient      = 3
    skProducer    = 4
    skConsumer    = 5

  StatusCode* = enum
    statusUnset  = 0
    statusOk     = 1
    statusError  = 2

  SpanStatus* = object
    code*:    StatusCode
    message*: string

  SpanEvent* = object
    timeUnixNano*:           uint64
    name*:                   string
    attributes*:             AttributeSet
    ## Must be set explicitly from attributes.dropped; the encoder does not
    ## auto-populate it. E.g.: droppedAttributesCount: attrs.dropped
    droppedAttributesCount*: uint32

  SpanLink* = object
    traceId*:                TraceId
    spanId*:                 SpanId
    traceState*:             string
    attributes*:             AttributeSet
    ## Must be set explicitly from attributes.dropped; the encoder does not
    ## auto-populate it. E.g.: droppedAttributesCount: attrs.dropped
    droppedAttributesCount*: uint32
    flags*:                  uint32

  Span* = object
    traceId*:                TraceId
    spanId*:                 SpanId
    parentSpanId*:           SpanId
    traceState*:             string
    name*:                   string
    kind*:                   SpanKind
    startTimeUnixNano*:      uint64
    endTimeUnixNano*:        uint64
    attributes*:             AttributeSet
    ## Must be set explicitly from attributes.dropped; the encoder does not
    ## auto-populate it. E.g.: droppedAttributesCount: attrs.dropped
    droppedAttributesCount*: uint32
    events*:                 seq[SpanEvent]
    droppedEventsCount*:     uint32
    links*:                  seq[SpanLink]
    droppedLinksCount*:      uint32
    status*:                 SpanStatus
    flags*:                  uint32

# ---------------------------------------------------------------------------
# Proto encoding
# ---------------------------------------------------------------------------

proc protoEncodeSpanEvent*(w: var ProtoWriter; e: SpanEvent) =
  w.writeFixed64(1, e.timeUnixNano)
  w.writeString(2, e.name)
  protoEncodeKeyValues(w, 3, e.attributes.pairs)
  w.writeUint32(4, e.droppedAttributesCount)

proc protoEncodeSpanLink*(w: var ProtoWriter; l: SpanLink) =
  w.writeBytes(1, l.traceId)
  w.writeBytes(2, l.spanId)
  w.writeString(3, l.traceState)
  protoEncodeKeyValues(w, 4, l.attributes.pairs)
  w.writeUint32(5, l.droppedAttributesCount)
  w.writeFixed32(6, l.flags)

proc protoEncodeSpanStatus*(w: var ProtoWriter; st: SpanStatus) =
  w.writeString(2, st.message)   # field 2 (no field 1 in Status)
  w.writeInt32(3, int32(st.code))

proc protoEncodeSpan*(w: var ProtoWriter; s: Span) =
  w.writeBytes(1, s.traceId)
  w.writeBytes(2, s.spanId)
  w.writeString(3, s.traceState)
  # parentSpanId: omit when all-zero (root span); proto3 bytes default is empty
  if not isAllZero(s.parentSpanId):
    w.writeBytes(4, s.parentSpanId)
  w.writeString(5, s.name)
  w.writeInt32(6, int32(s.kind))
  w.writeFixed64(7, s.startTimeUnixNano)
  w.writeFixed64(8, s.endTimeUnixNano)
  protoEncodeKeyValues(w, 9, s.attributes.pairs)
  w.writeUint32(10, s.droppedAttributesCount)
  for ev in s.events:
    var evW: ProtoWriter
    protoEncodeSpanEvent(evW, ev)
    w.writeEmbedded(11, evW)
  w.writeUint32(12, s.droppedEventsCount)
  for lk in s.links:
    var lkW: ProtoWriter
    protoEncodeSpanLink(lkW, lk)
    w.writeEmbedded(13, lkW)
  w.writeUint32(14, s.droppedLinksCount)
  var stW: ProtoWriter
  protoEncodeSpanStatus(stW, s.status)
  w.writeEmbedded(15, stW)
  w.writeFixed32(16, s.flags)

# ---------------------------------------------------------------------------
# JSON encoding
# ---------------------------------------------------------------------------

proc jsonEncodeSpanEvent(e: SpanEvent): string =
  result = "{\"timeUnixNano\":" & jsonEncodeUint64(e.timeUnixNano)
  result.add(",\"name\":" & jsonEscape(e.name))
  if e.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(e.attributes.pairs))
  if e.droppedAttributesCount != 0:
    result.add(",\"droppedAttributesCount\":" & $e.droppedAttributesCount)
  result.add("}")

proc jsonEncodeSpanLink(l: SpanLink): string =
  result = "{\"traceId\":\"" & hexEncodeTraceId(l.traceId) & "\""
  result.add(",\"spanId\":\"" & hexEncodeSpanId(l.spanId) & "\"")
  if l.traceState.len > 0:
    result.add(",\"traceState\":" & jsonEscape(l.traceState))
  if l.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(l.attributes.pairs))
  if l.droppedAttributesCount != 0:
    result.add(",\"droppedAttributesCount\":" & $l.droppedAttributesCount)
  if l.flags != 0:
    result.add(",\"flags\":" & $l.flags)
  result.add("}")

proc jsonEncodeSpan*(s: Span): string =
  result = "{\"traceId\":\"" & hexEncodeTraceId(s.traceId) & "\""
  result.add(",\"spanId\":\"" & hexEncodeSpanId(s.spanId) & "\"")
  if not isAllZero(s.parentSpanId):
    result.add(",\"parentSpanId\":\"" & hexEncodeSpanId(s.parentSpanId) & "\"")
  if s.traceState.len > 0:
    result.add(",\"traceState\":" & jsonEscape(s.traceState))
  # name/startTimeUnixNano/endTimeUnixNano are always emitted in JSON (unlike
  # proto's zero-suppression) — they are required, non-omittable span fields.
  result.add(",\"name\":" & jsonEscape(s.name))
  if s.kind != skUnspecified:
    result.add(",\"kind\":" & $int(s.kind))
  result.add(",\"startTimeUnixNano\":" & jsonEncodeUint64(s.startTimeUnixNano))
  result.add(",\"endTimeUnixNano\":" & jsonEncodeUint64(s.endTimeUnixNano))
  if s.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(s.attributes.pairs))
  if s.droppedAttributesCount != 0:
    result.add(",\"droppedAttributesCount\":" & $s.droppedAttributesCount)
  if s.events.len > 0:
    var evs = "["
    for i, ev in s.events:
      if i > 0: evs.add(",")
      evs.add(jsonEncodeSpanEvent(ev))
    evs.add("]")
    result.add(",\"events\":" & evs)
  if s.droppedEventsCount != 0:
    result.add(",\"droppedEventsCount\":" & $s.droppedEventsCount)
  if s.links.len > 0:
    var lks = "["
    for i, lk in s.links:
      if i > 0: lks.add(",")
      lks.add(jsonEncodeSpanLink(lk))
    lks.add("]")
    result.add(",\"links\":" & lks)
  if s.droppedLinksCount != 0:
    result.add(",\"droppedLinksCount\":" & $s.droppedLinksCount)
  if s.status.code != statusUnset or s.status.message.len > 0:
    result.add(",\"status\":{")
    var statusFields = 0
    if s.status.code != statusUnset:
      result.add("\"code\":" & $int(s.status.code))
      inc statusFields
    if s.status.message.len > 0:
      if statusFields > 0: result.add(",")
      result.add("\"message\":" & jsonEscape(s.status.message))
    result.add("}")
  if s.flags != 0:
    result.add(",\"flags\":" & $s.flags)
  result.add("}")

proc spanToJson*(res: Resource; scope: InstrumentationScope;
                 spans: seq[Span]): string =
  ## Encode spans as an OTLP ExportTraceServiceRequest JSON body.
  var spansArr = "["
  for i, s in spans:
    if i > 0: spansArr.add(",")
    spansArr.add(jsonEncodeSpan(s))
  spansArr.add("]")
  let scopeSpans = "{\"scope\":" & jsonEncode(scope) & ",\"spans\":" & spansArr & "}"
  let resourceSpans = "{\"resource\":" & jsonEncode(res) & ",\"scopeSpans\":[" & scopeSpans & "]}"
  "{\"resourceSpans\":[" & resourceSpans & "]}"
