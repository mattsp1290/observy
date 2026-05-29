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
    of avString: strVal*:   string
    of avBool:   boolVal*:  bool
    of avInt:    intVal*:   int64
    of avDouble: dblVal*:   float64
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
    dropped*:     uint32

proc initAttributeSet*(maxCount = DEFAULT_MAX_ATTRIBUTES;
                       maxValueLen = DEFAULT_MAX_VALUE_LEN): AttributeSet =
  AttributeSet(
    maxCount:    max(maxCount, 0),
    maxValueLen: max(maxValueLen, 0),
  )

proc truncateUtf8*(s: string; maxBytes: int): string =
  if maxBytes <= 0: return ""
  if s.len <= maxBytes: return s
  var i = 0
  while i < s.len and i < maxBytes:
    let b = byte(s[i])
    let charLen =
      if   (b and 0x80'u8) == 0'u8:    1
      elif (b and 0xE0'u8) == 0xC0'u8: 2
      elif (b and 0xF0'u8) == 0xE0'u8: 3
      elif (b and 0xF8'u8) == 0xF0'u8: 4
      else: -1  # stray continuation byte or invalid lead byte
    if charLen < 0: break
    if i + charLen > maxBytes: break
    # validate continuation bytes
    var valid = true
    for j in 1 ..< charLen:
      if i + j >= s.len or (byte(s[i + j]) and 0xC0'u8) != 0x80'u8:
        valid = false
        break
    if not valid: break
    i += charLen
  s[0 ..< i]

proc truncateValue*(v: AnyValue; maxValueLen: int): AnyValue =
  case v.kind
  of avString:
    AnyValue(kind: avString, strVal: truncateUtf8(v.strVal, maxValueLen))
  of avBytes:
    if v.bytesVal.len <= maxValueLen: v
    else: AnyValue(kind: avBytes, bytesVal: v.bytesVal[0 ..< maxValueLen])
  of avArray:
    var arr = newSeq[AnyValue](v.arrayVal.len)
    for i, elem in v.arrayVal: arr[i] = truncateValue(elem, maxValueLen)
    AnyValue(kind: avArray, arrayVal: arr)
  of avKvList:
    var kvl = newSeq[KeyValue](v.kvlistVal.len)
    for i, kv in v.kvlistVal:
      kvl[i] = KeyValue(key: kv.key, value: truncateValue(kv.value, maxValueLen))
    AnyValue(kind: avKvList, kvlistVal: kvl)
  else:
    v

proc add*(a: var AttributeSet; k: string; v: AnyValue) =
  if a.pairs.len >= a.maxCount:
    inc a.dropped
    return
  a.pairs.add(KeyValue(key: k, value: truncateValue(v, a.maxValueLen)))
