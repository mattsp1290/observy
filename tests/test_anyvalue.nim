import unittest
import std/math
import ../src/observy/anyvalue
import ../src/observy/proto

suite "AnyValue kinds":
  test "avString":
    let v = AnyValue(kind: avString, strVal: "hello")
    check v.kind == avString
    check v.strVal == "hello"

  test "avBool true":
    let v = AnyValue(kind: avBool, boolVal: true)
    check v.kind == avBool
    check v.boolVal == true

  test "avBool false":
    let v = AnyValue(kind: avBool, boolVal: false)
    check v.boolVal == false

  test "avInt":
    let v = AnyValue(kind: avInt, intVal: -42'i64)
    check v.kind == avInt
    check v.intVal == -42'i64

  test "avDouble":
    let v = AnyValue(kind: avDouble, dblVal: 3.14)
    check v.kind == avDouble
    check v.dblVal == 3.14

  test "avBytes":
    let v = AnyValue(kind: avBytes, bytesVal: @[0x01'u8, 0x02])
    check v.kind == avBytes
    check v.bytesVal == @[0x01'u8, 0x02]

  test "avArray":
    let v = AnyValue(kind: avArray, arrayVal: @[
      AnyValue(kind: avInt, intVal: 1),
      AnyValue(kind: avInt, intVal: 2),
    ])
    check v.kind == avArray
    check v.arrayVal.len == 2

  test "avKvList":
    let v = AnyValue(kind: avKvList, kvlistVal: @[
      KeyValue(key: "k", value: AnyValue(kind: avString, strVal: "v"))
    ])
    check v.kind == avKvList
    check v.kvlistVal[0].key == "k"

suite "AttributeSet add":
  test "add single attribute":
    var a = initAttributeSet()
    a.add("key", AnyValue(kind: avInt, intVal: 1))
    check a.pairs.len == 1
    check a.pairs[0].key == "key"

  test "count limit enforced":
    var a = initAttributeSet(maxCount = 3)
    for i in 0 ..< 5:
      a.add("k" & $i, AnyValue(kind: avInt, intVal: int64(i)))
    check a.pairs.len == 3

  test "string value truncated at maxValueLen":
    var a = initAttributeSet(maxValueLen = 5)
    a.add("k", AnyValue(kind: avString, strVal: "hello world"))
    check a.pairs[0].value.strVal == "hello"

  test "short string not truncated":
    var a = initAttributeSet(maxValueLen = 100)
    a.add("k", AnyValue(kind: avString, strVal: "hi"))
    check a.pairs[0].value.strVal == "hi"

  test "bytes truncated at maxValueLen":
    var a = initAttributeSet(maxValueLen = 3)
    a.add("k", AnyValue(kind: avBytes, bytesVal: @[0x01'u8, 0x02, 0x03, 0x04, 0x05]))
    check a.pairs[0].value.bytesVal.len == 3

  test "non-string values not affected by maxValueLen":
    var a = initAttributeSet(maxValueLen = 1)
    a.add("k", AnyValue(kind: avInt, intVal: 999))
    check a.pairs[0].value.intVal == 999

  test "default constants":
    check DEFAULT_MAX_ATTRIBUTES == 128
    check DEFAULT_MAX_VALUE_LEN == 4096

suite "UTF-8 safe truncation":
  test "ascii truncates at byte boundary":
    var a = initAttributeSet(maxValueLen = 3)
    a.add("k", AnyValue(kind: avString, strVal: "abcde"))
    check a.pairs[0].value.strVal == "abc"

  test "2-byte UTF-8 char not split":
    # é is 2 bytes (0xC3 0xA9)
    let s = "aé"  # 3 bytes total: 'a' + 2-byte é
    var a = initAttributeSet(maxValueLen = 2)
    a.add("k", AnyValue(kind: avString, strVal: s))
    # maxValueLen=2 fits 'a' + first byte of é? No — 'a'=1, é needs 2, so only 'a' fits
    check a.pairs[0].value.strVal == "a"

  test "3-byte UTF-8 char not split":
    # '€' is 3 bytes (0xE2 0x82 0xAC)
    let s = "a€b"  # 5 bytes
    var a = initAttributeSet(maxValueLen = 3)
    a.add("k", AnyValue(kind: avString, strVal: s))
    # maxValueLen=3: 'a'(1) + '€'(3) = 4 > 3, so only 'a' fits
    check a.pairs[0].value.strVal == "a"

  test "4-byte UTF-8 char not split":
    # U+1F600 GRINNING FACE is 4 bytes: 0xF0 0x9F 0x98 0x80
    let s = "\xF0\x9F\x98\x80abc"  # 7 bytes total
    var a = initAttributeSet(maxValueLen = 5)
    a.add("k", AnyValue(kind: avString, strVal: s))
    # 4-byte emoji fits in 5 bytes, then 'a' => 5 bytes total
    check a.pairs[0].value.strVal.len == 5

  test "maxValueLen = 0 truncates to empty":
    var a = initAttributeSet(maxValueLen = 0)
    a.add("k", AnyValue(kind: avString, strVal: "hello"))
    check a.pairs[0].value.strVal == ""

  test "negative maxValueLen clamped to 0":
    var a = initAttributeSet(maxValueLen = -5)
    check a.maxValueLen == 0
    a.add("k", AnyValue(kind: avString, strVal: "hello"))
    check a.pairs[0].value.strVal == ""

  test "negative maxCount clamped to 0":
    var a = initAttributeSet(maxCount = -1)
    check a.maxCount == 0
    a.add("k", AnyValue(kind: avInt, intVal: 1))
    check a.pairs.len == 0

  test "malformed UTF-8 stray continuation byte stopped before":
    # 0x80 is a stray continuation byte; truncation window includes it
    let s = "a\x80bcde"  # 6 bytes, limit=4 requires truncation; stray byte at pos 1
    var a = initAttributeSet(maxValueLen = 4)
    a.add("k", AnyValue(kind: avString, strVal: s))
    # stops before stray continuation byte at pos 1
    check a.pairs[0].value.strVal == "a"

  test "malformed UTF-8 invalid lead byte stopped before":
    # 0xFF is an invalid lead byte; truncation window includes it
    let s = "a\xFFbcde"  # 6 bytes, limit=4; invalid lead at pos 1
    var a = initAttributeSet(maxValueLen = 4)
    a.add("k", AnyValue(kind: avString, strVal: s))
    # stops before invalid lead byte at pos 1
    check a.pairs[0].value.strVal == "a"

suite "recursive truncation":
  test "avArray nested strings truncated":
    var a = initAttributeSet(maxValueLen = 3)
    let v = AnyValue(kind: avArray, arrayVal: @[
      AnyValue(kind: avString, strVal: "hello"),
      AnyValue(kind: avString, strVal: "world"),
    ])
    a.add("k", v)
    check a.pairs[0].value.arrayVal[0].strVal == "hel"
    check a.pairs[0].value.arrayVal[1].strVal == "wor"

  test "avKvList nested strings truncated":
    var a = initAttributeSet(maxValueLen = 2)
    let v = AnyValue(kind: avKvList, kvlistVal: @[
      KeyValue(key: "x", value: AnyValue(kind: avString, strVal: "abcde")),
    ])
    a.add("k", v)
    check a.pairs[0].value.kvlistVal[0].value.strVal == "ab"

  test "deeply nested non-string values unchanged":
    var a = initAttributeSet(maxValueLen = 1)
    let v = AnyValue(kind: avArray, arrayVal: @[
      AnyValue(kind: avInt, intVal: 12345'i64),
    ])
    a.add("k", v)
    check a.pairs[0].value.arrayVal[0].intVal == 12345'i64

suite "AnyValue edge values":
  test "empty string":
    let v = AnyValue(kind: avString, strVal: "")
    check v.strVal == ""
    check v.strVal.len == 0

  test "empty bytes":
    let v = AnyValue(kind: avBytes, bytesVal: @[])
    check v.bytesVal.len == 0

  test "zero int64":
    let v = AnyValue(kind: avInt, intVal: 0'i64)
    check v.intVal == 0'i64

  test "negative one int64":
    let v = AnyValue(kind: avInt, intVal: -1'i64)
    check v.intVal == -1'i64

  test "min int64":
    let v = AnyValue(kind: avInt, intVal: low(int64))
    check v.intVal == low(int64)

  test "max int64":
    let v = AnyValue(kind: avInt, intVal: high(int64))
    check v.intVal == high(int64)

  test "NaN double":
    let v = AnyValue(kind: avDouble, dblVal: NaN)
    check isNaN(v.dblVal)

  test "max float64":
    let v = AnyValue(kind: avDouble, dblVal: high(float64))
    check v.dblVal == high(float64)

  test "positive infinity":
    let v = AnyValue(kind: avDouble, dblVal: Inf)
    check classify(v.dblVal) == fcInf

suite "KeyValue proto round-trip":
  proc encodeKV(kv: KeyValue): seq[byte] =
    var w: ProtoWriter
    w.writeString(1, kv.key)
    var valW: ProtoWriter
    case kv.value.kind
    of avString: valW.writeString(1, kv.value.strVal)
    of avBool:   valW.writeBool(2, kv.value.boolVal)
    of avInt:    valW.writeInt64(3, kv.value.intVal)
    of avDouble: valW.writeDouble(4, kv.value.dblVal)
    of avBytes:  valW.writeBytes(7, kv.value.bytesVal)
    else: discard
    w.writeEmbedded(2, valW)
    w.buf

  test "string kv encodes key as field 1":
    let kv = KeyValue(key: "service.name", value: AnyValue(kind: avString, strVal: "my-svc"))
    let bytes = encodeKV(kv)
    check bytes.len > 0
    var found = false
    for i in 0 ..< bytes.len - 12:
      if bytes[i ..< i + 12] == cast[seq[byte]]("service.name"):
        found = true; break
    check found

  test "int kv preserves value":
    let kv = KeyValue(key: "count", value: AnyValue(kind: avInt, intVal: 42'i64))
    let bytes = encodeKV(kv)
    var r = ProtoReader(data: bytes)
    # field 1 = key
    discard r.readTag()
    check r.readString() == "count"
    # field 2 = value (embedded)
    discard r.readTag()
    let inner = r.readBytes()
    var vr = ProtoReader(data: inner)
    discard vr.readTag()  # field 3, varint
    check vr.readInt64() == 42'i64

  test "bool kv true":
    let kv = KeyValue(key: "ok", value: AnyValue(kind: avBool, boolVal: true))
    let bytes = encodeKV(kv)
    check bytes.len > 0

  test "empty key kv":
    let kv = KeyValue(key: "", value: AnyValue(kind: avString, strVal: "val"))
    let bytes = encodeKV(kv)
    # empty key → field 1 omitted (proto3 default suppression)
    check bytes.len > 0  # still has value field
