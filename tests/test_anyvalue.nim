import unittest
import ../src/observy/anyvalue

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
