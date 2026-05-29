# Traces signal data model
import ./anyvalue

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
  TraceFlags* = uint8

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
    droppedAttributesCount*: uint32

  SpanLink* = object
    traceId*:                TraceId
    spanId*:                 SpanId
    traceState*:             string
    attributes*:             AttributeSet
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
    droppedAttributesCount*: uint32
    events*:                 seq[SpanEvent]
    droppedEventsCount*:     uint32
    links*:                  seq[SpanLink]
    droppedLinksCount*:      uint32
    status*:                 SpanStatus
    flags*:                  uint32
