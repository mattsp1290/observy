# AnyValue and KeyValue types for OTLP attributes

const
  DEFAULT_MAX_ATTRIBUTES* = 128
  DEFAULT_MAX_VALUE_LEN*  = 4096

type
  AnyValueKind* = enum
    avString
    avBool
    avInt
    avDouble
    avBytes
    avArray
    avKvList

  AnyValue* = object
    case kind*: AnyValueKind
    of avString: strVal*:  string
    of avBool:   boolVal*: bool
    of avInt:    intVal*:  int64
    of avDouble: dblVal*:  float64
    of avBytes:  bytesVal*: seq[byte]
    of avArray:  arrayVal*: seq[AnyValue]
    of avKvList: kvlistVal*: seq[KeyValue]

  KeyValue* = object
    key*:   string
    value*: AnyValue

  AttributeSet* = object
    pairs*:       seq[KeyValue]
    maxCount*:    int
    maxValueLen*: int

proc initAttributeSet*(maxCount = DEFAULT_MAX_ATTRIBUTES;
                       maxValueLen = DEFAULT_MAX_VALUE_LEN): AttributeSet =
  AttributeSet(maxCount: maxCount, maxValueLen: maxValueLen)

proc truncateUtf8(s: string; maxBytes: int): string =
  if s.len <= maxBytes: return s
  var i = 0
  while i < maxBytes:
    let b = byte(s[i])
    let charLen =
      if   (b and 0x80'u8) == 0'u8:    1
      elif (b and 0xE0'u8) == 0xC0'u8: 2
      elif (b and 0xF0'u8) == 0xE0'u8: 3
      else:                             4
    if i + charLen > maxBytes: break
    i += charLen
  s[0 ..< i]

proc truncateValue(v: AnyValue; maxValueLen: int): AnyValue =
  case v.kind
  of avString:
    AnyValue(kind: avString, strVal: truncateUtf8(v.strVal, maxValueLen))
  of avBytes:
    if v.bytesVal.len <= maxValueLen: v
    else: AnyValue(kind: avBytes, bytesVal: v.bytesVal[0 ..< maxValueLen])
  else:
    v

proc add*(a: var AttributeSet; k: string; v: AnyValue) =
  if a.pairs.len >= a.maxCount: return
  a.pairs.add(KeyValue(key: k, value: truncateValue(v, a.maxValueLen)))
