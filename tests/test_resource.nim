import unittest
import ../src/observy/anyvalue
import ../src/observy/resource
import ../src/observy/proto

# ---------------------------------------------------------------------------
# Proto round-trip helpers
# ---------------------------------------------------------------------------

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
    # verify we can find the key "service.name" and value "my-service" in the encoded bytes
    var found = false
    for i in 0 ..< bytes.len - 12:
      if bytes[i ..< i + 12] == cast[seq[byte]]("service.name"):
        found = true
        break
    check found

  test "resource with droppedAttributesCount":
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 5)
    let bytes = protoEncode(r)
    # field 2, varint wire type: tag = (2 shl 3) | 0 = 0x10
    check bytes.len >= 2
    check bytes[0] == 0x10'u8
    check bytes[1] == 5'u8

  test "resource round-trip: string attribute":
    var attrs = initAttributeSet()
    attrs.add("host.name", AnyValue(kind: avString, strVal: "localhost"))
    let r = Resource(attributes: attrs, droppedAttributesCount: 0)
    let bytes = protoEncode(r)
    var reader = ProtoReader(data: bytes)
    let (fn, wt) = reader.readTag()
    check fn == 1  # attributes field
    check wt == WireLen
    let kvBytes = reader.readBytes()
    var kvReader = ProtoReader(data: kvBytes)
    let (kfn, _) = kvReader.readTag()
    check kfn == 1  # key field
    let key = decodeString(kvReader)
    check key == "host.name"

suite "InstrumentationScope proto encode":
  test "empty scope encodes to empty bytes":
    let s = InstrumentationScope(attributes: initAttributeSet())
    check protoEncode(s).len == 0

  test "scope with name":
    let s = InstrumentationScope(name: "my.library",
                                  attributes: initAttributeSet())
    let bytes = protoEncode(s)
    check bytes.len > 0
    var r = ProtoReader(data: bytes)
    let (fn, _) = r.readTag()
    check fn == 1  # name field
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

  test "scope with droppedAttributesCount":
    let s = InstrumentationScope(name: "lib",
                                  attributes: initAttributeSet(),
                                  droppedAttributesCount: 3)
    let bytes = protoEncode(s)
    var r = ProtoReader(data: bytes)
    discard r.readTag()           # name
    discard decodeString(r)
    discard r.readTag()           # droppedAttributesCount = field 4
    let (fn, _) = (4'u32, 0'u8)  # check by advancing to last field
    let dropped = r.readVarint()
    check dropped == 3

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
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 2)
    check jsonEncode(r) == "{\"attributes\":[],\"droppedAttributesCount\":2}"

  test "zero droppedAttributesCount omitted":
    let r = Resource(attributes: initAttributeSet(), droppedAttributesCount: 0)
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
    let v = AnyValue(kind: avInt, intVal: -9223372036854775808'i64)
    check jsonEncodeAnyValue(v) == "{\"intValue\":\"-9223372036854775808\"}"

  test "doubleValue":
    let v = AnyValue(kind: avDouble, dblVal: 1.5)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":1.5}"
