# Logs signal data model and OTLP encoding
import ./anyvalue
import ./traces
import ./proto
import ./resource
import ./json_encode

# opentelemetry-proto v1.10.0 field numbers
# logs/v1/logs.proto
#   LogRecord: time_unix_nano=1, severity_number=2, severity_text=3, body=5,
#              attributes=6, dropped_attributes_count=7, flags=8, trace_id=9,
#              span_id=10, observed_time_unix_nano=11, event_name=12

type
  SeverityNumber* = enum
    severityUnspecified = 0
    severityTrace       = 1
    severityTrace2      = 2
    severityTrace3      = 3
    severityTrace4      = 4
    severityDebug       = 5
    severityDebug2      = 6
    severityDebug3      = 7
    severityDebug4      = 8
    severityInfo        = 9
    severityInfo2       = 10
    severityInfo3       = 11
    severityInfo4       = 12
    severityWarn        = 13
    severityWarn2       = 14
    severityWarn3       = 15
    severityWarn4       = 16
    severityError       = 17
    severityError2      = 18
    severityError3      = 19
    severityError4      = 20
    severityFatal       = 21
    severityFatal2      = 22
    severityFatal3      = 23
    severityFatal4      = 24

  LogRecord* = object
    timeUnixNano*:           uint64
    observedTimeUnixNano*:   uint64
    severityNumber*:         SeverityNumber
    severityText*:           string
    body*:                   AnyValue
    attributes*:             AttributeSet
    ## Must be set explicitly from attributes.dropped; the encoder does not
    ## auto-populate it. E.g.: droppedAttributesCount: attrs.dropped
    droppedAttributesCount*: uint32
    flags*:                  uint32
    traceId*:                TraceId
    spanId*:                 SpanId
    eventName*:              string

# ---------------------------------------------------------------------------
# Proto encoding
# ---------------------------------------------------------------------------

proc protoEncodeLogRecord*(w: var ProtoWriter; l: LogRecord) =
  w.writeFixed64(1, l.timeUnixNano)
  w.writeInt32(2, int32(l.severityNumber))
  w.writeString(3, l.severityText)
  # Omit body at field 5 when it is the default empty-string AnyValue, matching
  # the JSON encoder (logs.nim jsonEncodeLogRecord body guard). A LogRecord with
  # no body set uses the default AnyValue zero value (avString ""); emitting an
  # empty AnyValue oneof there would be misleading.
  if l.body.kind != avString or l.body.strVal.len > 0:
    var bodyW: ProtoWriter
    protoEncodeAnyValue(bodyW, l.body)
    w.writeEmbeddedForce(5, bodyW)
  protoEncodeKeyValues(w, 6, l.attributes.pairs)
  w.writeUint32(7, l.droppedAttributesCount)
  w.writeFixed32(8, l.flags)      # flags is fixed32 in LogRecord
  # traceId/spanId are fixed-size arrays (len never 0), so writeBytes can't
  # auto-suppress them. Omit explicitly for context-less logs to match the
  # proto3 empty-bytes default (and the JSON encoder below).
  if not isAllZero(l.traceId):
    w.writeBytes(9, l.traceId)
  if not isAllZero(l.spanId):
    w.writeBytes(10, l.spanId)
  w.writeFixed64(11, l.observedTimeUnixNano)
  w.writeString(12, l.eventName)

# ---------------------------------------------------------------------------
# JSON encoding
# ---------------------------------------------------------------------------

proc jsonEncodeLogRecord*(l: LogRecord): string =
  result = "{\"timeUnixNano\":" & jsonEncodeUint64(l.timeUnixNano)
  if l.severityNumber != severityUnspecified:
    result.add(",\"severityNumber\":" & $int(l.severityNumber))
  if l.severityText.len > 0:
    result.add(",\"severityText\":" & jsonEscape(l.severityText))
  # Omit body when it's the default empty-string AnyValue, matching the proto
  # encoder (which suppresses the empty embedded message at field 5).
  if l.body.kind != avString or l.body.strVal.len > 0:
    result.add(",\"body\":" & jsonEncodeAnyValue(l.body))
  if l.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(l.attributes.pairs))
  if l.droppedAttributesCount != 0:
    result.add(",\"droppedAttributesCount\":" & $l.droppedAttributesCount)
  if l.flags != 0:
    result.add(",\"flags\":" & $l.flags)
  if not isAllZero(l.traceId):
    result.add(",\"traceId\":\"" & hexEncodeTraceId(l.traceId) & "\"")
  if not isAllZero(l.spanId):
    result.add(",\"spanId\":\"" & hexEncodeSpanId(l.spanId) & "\"")
  if l.observedTimeUnixNano != 0:
    result.add(",\"observedTimeUnixNano\":" & jsonEncodeUint64(l.observedTimeUnixNano))
  if l.eventName.len > 0:
    result.add(",\"eventName\":" & jsonEscape(l.eventName))
  result.add("}")

proc logRecordsToJson*(res: Resource; scope: InstrumentationScope;
                       records: seq[LogRecord]): string =
  ## Encode log records as an OTLP ExportLogsServiceRequest JSON body.
  var logsArr = "["
  for i, l in records:
    if i > 0: logsArr.add(",")
    logsArr.add(jsonEncodeLogRecord(l))
  logsArr.add("]")
  let scopeLogs = "{\"scope\":" & jsonEncode(scope) & ",\"logRecords\":" & logsArr & "}"
  let resourceLogs = "{\"resource\":" & jsonEncode(res) & ",\"scopeLogs\":[" & scopeLogs & "]}"
  "{\"resourceLogs\":[" & resourceLogs & "]}"
