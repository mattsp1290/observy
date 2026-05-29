# Logs signal data model
import ./anyvalue
import ./traces

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
    droppedAttributesCount*: uint32
    flags*:                  uint32
    traceId*:                TraceId
    spanId*:                 SpanId
    eventName*:              string
