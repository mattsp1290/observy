# OTLP-compliant JSON encoding utilities
#
# Key encoding rules that differ from standard proto3 JSON mapping:
#   - TraceId/SpanId: 32/16-char lowercase hex (NOT base64)
#   - int64/uint64:   JSON string, not number (e.g. "42")
#   - bytes fields:   RFC 4648 standard base64, no line breaks
#   - NaN/Inf/NegInf: JSON strings "NaN", "Infinity", "-Infinity"

import std/base64
import std/math
import ./anyvalue
import ./traces

proc hexEncodeTraceId*(id: TraceId): string =
  const h = "0123456789abcdef"
  result = newString(32)
  for i in 0 ..< 16:
    result[i * 2]     = h[int(id[i] shr 4)]
    result[i * 2 + 1] = h[int(id[i] and 0xF)]

proc hexEncodeSpanId*(id: SpanId): string =
  const h = "0123456789abcdef"
  result = newString(16)
  for i in 0 ..< 8:
    result[i * 2]     = h[int(id[i] shr 4)]
    result[i * 2 + 1] = h[int(id[i] and 0xF)]

proc base64Encode*(data: seq[byte]): string =
  encode(data)

proc jsonEncodeInt64*(v: int64): string =
  "\"" & $v & "\""

proc jsonEncodeUint64*(v: uint64): string =
  "\"" & $v & "\""

proc jsonEscape*(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"':  result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ord(c) < 0x20:
        result.add("\\u00")
        let hi = ord(c) shr 4
        let lo = ord(c) and 0xF
        result.add(chr(if hi < 10: ord('0') + hi else: ord('a') + hi - 10))
        result.add(chr(if lo < 10: ord('0') + lo else: ord('a') + lo - 10))
      else:
        result.add(c)
  result.add("\"")

proc jsonEncodeDouble*(v: float64): string =
  if isNaN(v): return "\"NaN\""
  case classify(v)
  of fcInf:    return "\"Infinity\""
  of fcNegInf: return "\"-Infinity\""
  else:        $v

proc jsonEncodeAnyValue*(v: AnyValue): string

proc jsonEncodeKeyValue*(kv: KeyValue): string =
  "{\"key\":" & jsonEscape(kv.key) & ",\"value\":" & jsonEncodeAnyValue(kv.value) & "}"

proc jsonEncodeAnyValue*(v: AnyValue): string =
  case v.kind
  of avString:
    "{\"stringValue\":" & jsonEscape(v.strVal) & "}"
  of avBool:
    if v.boolVal: "{\"boolValue\":true}" else: "{\"boolValue\":false}"
  of avInt:
    "{\"intValue\":\"" & $v.intVal & "\"}"
  of avDouble:
    "{\"doubleValue\":" & jsonEncodeDouble(v.dblVal) & "}"
  of avBytes:
    "{\"bytesValue\":" & jsonEscape(encode(v.bytesVal)) & "}"
  of avArray:
    var elems = "["
    for i, elem in v.arrayVal:
      if i > 0: elems.add(",")
      elems.add(jsonEncodeAnyValue(elem))
    elems.add("]")
    "{\"arrayValue\":{\"values\":" & elems & "}}"
  of avKvList:
    var kvs = "["
    for i, kv in v.kvlistVal:
      if i > 0: kvs.add(",")
      kvs.add(jsonEncodeKeyValue(kv))
    kvs.add("]")
    "{\"kvlistValue\":{\"values\":" & kvs & "}}"

proc jsonEncodeKVList*(pairs: openArray[KeyValue]): string =
  result = "["
  for i, kv in pairs:
    if i > 0: result.add(",")
    result.add(jsonEncodeKeyValue(kv))
  result.add("]")
