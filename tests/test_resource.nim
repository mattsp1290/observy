import unittest
import std/math
import std/strutils
import ../src/observy/anyvalue
import ../src/observy/resource
import ../src/observy/proto

proc decodeString(r: var ProtoReader): string =
  let n = int(r.readVarint())
  result = newString(n)
  for i in 0 ..< n:
    if r.pos >= r.data.len:
      raise newException(ProtoError, "truncated string")
    result[i] = char(r.data[r.pos])
    inc r.pos

suite "Resource proto encode":
  test "empty resource encodes as empty bytes":
    let r = Resource(attributes: initAttributeSet())
    check protoEncode(r).len == 0

  test "resource with one string attribute":
    var attrs = initAttributeSet()
    attrs.add("service.name", AnyValue(kind: avString, strVal: "my-service"))
    let r = Resource(attributes: attrs)
    let bytes = protoEncode(r)
    check bytes.len > 0
    var found = false
    for i in 0 ..< bytes.len - 12:
      if bytes[i ..< i + 12] == cast[seq[byte]]("service.name"):
        found = true
        break
    check found

  test "resource with droppedAttributesCount":
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 5'u32)
    let bytes = protoEncode(r)
    check bytes.len >= 2
    check bytes[0] == 0x10'u8  # field 2, varint
    check bytes[1] == 5'u8

  test "resource round-trip: string attribute key":
    var attrs = initAttributeSet()
    attrs.add("host.name", AnyValue(kind: avString, strVal: "localhost"))
    let r = Resource(attributes: attrs)
    let bytes = protoEncode(r)
    var reader = ProtoReader(data: bytes)
    let (fn, wt) = reader.readTag()
    check fn == 1
    check wt == WireLen
    let kvBytes = reader.readBytes()
    var kvReader = ProtoReader(data: kvBytes)
    let (kfn, _) = kvReader.readTag()
    check kfn == 1
    check decodeString(kvReader) == "host.name"

  test "resource zero droppedCount omitted from wire":
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 0'u32)
    check protoEncode(r).len == 0

suite "InstrumentationScope proto encode":
  test "empty scope encodes to empty bytes":
    let s = InstrumentationScope(attributes: initAttributeSet())
    check protoEncode(s).len == 0

  test "scope with name":
    let s = InstrumentationScope(name: "my.library",
                                  attributes: initAttributeSet())
    let bytes = protoEncode(s)
    var r = ProtoReader(data: bytes)
    let (fn, _) = r.readTag()
    check fn == 1
    check decodeString(r) == "my.library"

  test "scope with name and version":
    let s = InstrumentationScope(name: "lib", version: "1.0.0",
                                  attributes: initAttributeSet())
    let bytes = protoEncode(s)
    var r = ProtoReader(data: bytes)
    discard r.readTag()
    check decodeString(r) == "lib"
    discard r.readTag()
    check decodeString(r) == "1.0.0"

  test "scope with droppedAttributesCount encodes field 4":
    let s = InstrumentationScope(name: "lib",
                                  attributes: initAttributeSet(),
                                  droppedAttributesCount: 3'u32)
    let bytes = protoEncode(s)
    var r = ProtoReader(data: bytes)
    # skip name (field 1)
    let (f1, _) = r.readTag(); check f1 == 1; discard decodeString(r)
    # dropped = field 4 varint
    let (f4, w4) = r.readTag()
    check f4 == 4
    check w4 == WireVarint
    check r.readVarint() == 3

suite "Resource JSON encode":
  test "empty resource":
    let r = Resource(attributes: initAttributeSet())
    check jsonEncode(r) == "{\"attributes\":[]}"

  test "resource with string attribute":
    var attrs = initAttributeSet()
    attrs.add("k", AnyValue(kind: avString, strVal: "v"))
    let r = Resource(attributes: attrs)
    check jsonEncode(r) == "{\"attributes\":[{\"key\":\"k\",\"value\":{\"stringValue\":\"v\"}}]}"

  test "resource with droppedAttributesCount":
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 2'u32)
    check jsonEncode(r) == "{\"attributes\":[],\"droppedAttributesCount\":2}"

  test "zero droppedAttributesCount omitted":
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 0'u32)
    check jsonEncode(r) == "{\"attributes\":[]}"

suite "InstrumentationScope JSON encode":
  test "scope with name only":
    let s = InstrumentationScope(name: "mylib", attributes: initAttributeSet())
    check jsonEncode(s) == "{\"name\":\"mylib\",\"attributes\":[]}"

  test "scope with name and version":
    let s = InstrumentationScope(name: "lib", version: "2.0",
                                  attributes: initAttributeSet())
    check jsonEncode(s) == "{\"name\":\"lib\",\"version\":\"2.0\",\"attributes\":[]}"

  test "empty version omitted":
    let s = InstrumentationScope(name: "lib", version: "",
                                  attributes: initAttributeSet())
    check jsonEncode(s) == "{\"name\":\"lib\",\"attributes\":[]}"

  test "scope droppedAttributesCount zero omitted":
    let s = InstrumentationScope(name: "lib", attributes: initAttributeSet(),
                                  droppedAttributesCount: 0'u32)
    check jsonEncode(s) == "{\"name\":\"lib\",\"attributes\":[]}"

  test "scope droppedAttributesCount non-zero present":
    let s = InstrumentationScope(name: "lib", attributes: initAttributeSet(),
                                  droppedAttributesCount: 7'u32)
    check jsonEncode(s) == "{\"name\":\"lib\",\"attributes\":[],\"droppedAttributesCount\":7}"

suite "JSON escaping":
  test "key with quote escaped":
    var attrs = initAttributeSet()
    attrs.add("a\"b", AnyValue(kind: avString, strVal: "x"))
    let r = Resource(attributes: attrs)
    let j = jsonEncode(r)
    check j.find("a\\\"b") >= 0

  test "string value with backslash escaped":
    let v = AnyValue(kind: avString, strVal: "C:\\tmp")
    check jsonEncodeAnyValue(v) == "{\"stringValue\":\"C:\\\\tmp\"}"

  test "string value with newline escaped":
    let v = AnyValue(kind: avString, strVal: "line1\nline2")
    check jsonEncodeAnyValue(v) == "{\"stringValue\":\"line1\\nline2\"}"

  test "scope name with quote escaped":
    let s = InstrumentationScope(name: "lib\"x", attributes: initAttributeSet())
    let j = jsonEncode(s)
    check j.find("lib\\\"x") >= 0

suite "AnyValue JSON encoding":
  test "stringValue":
    let v = AnyValue(kind: avString, strVal: "hello")
    check jsonEncodeAnyValue(v) == "{\"stringValue\":\"hello\"}"

  test "boolValue true":
    let v = AnyValue(kind: avBool, boolVal: true)
    check jsonEncodeAnyValue(v) == "{\"boolValue\":true}"

  test "boolValue false":
    let v = AnyValue(kind: avBool, boolVal: false)
    check jsonEncodeAnyValue(v) == "{\"boolValue\":false}"

  test "intValue as JSON string":
    let v = AnyValue(kind: avInt, intVal: 42'i64)
    check jsonEncodeAnyValue(v) == "{\"intValue\":\"42\"}"

  test "negative intValue as JSON string":
    let v = AnyValue(kind: avInt, intVal: low(int64))
    check jsonEncodeAnyValue(v) == "{\"intValue\":\"-9223372036854775808\"}"

  test "doubleValue finite":
    let v = AnyValue(kind: avDouble, dblVal: 1.5)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":1.5}"

  test "doubleValue NaN encodes as string":
    let v = AnyValue(kind: avDouble, dblVal: NaN)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":\"NaN\"}"

  test "doubleValue Inf encodes as string":
    let v = AnyValue(kind: avDouble, dblVal: Inf)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":\"Infinity\"}"

  test "doubleValue -Inf encodes as string":
    let v = AnyValue(kind: avDouble, dblVal: NegInf)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":\"-Infinity\"}"

  test "bytesValue base64":
    let v = AnyValue(kind: avBytes, bytesVal: @[0x01'u8, 0x02, 0x03])
    let j = jsonEncodeAnyValue(v)
    check j.find("\"bytesValue\"") >= 0
    check j.find("AQID") >= 0  # base64 of [0x01, 0x02, 0x03]

  test "bytesValue empty":
    let v = AnyValue(kind: avBytes, bytesVal: @[])
    let j = jsonEncodeAnyValue(v)
    check j == "{\"bytesValue\":\"\"}"

  test "arrayValue":
    let v = AnyValue(kind: avArray, arrayVal: @[
      AnyValue(kind: avInt, intVal: 1),
      AnyValue(kind: avString, strVal: "x"),
    ])
    let j = jsonEncodeAnyValue(v)
    check j.find("\"arrayValue\"") >= 0
    check j.find("\"intValue\":\"1\"") >= 0
    check j.find("\"stringValue\":\"x\"") >= 0

  test "kvlistValue":
    let v = AnyValue(kind: avKvList, kvlistVal: @[
      KeyValue(key: "env", value: AnyValue(kind: avString, strVal: "prod")),
    ])
    let j = jsonEncodeAnyValue(v)
    check j.find("\"kvlistValue\"") >= 0
    check j.find("\"env\"") >= 0
    check j.find("\"prod\"") >= 0
