import unittest
import std/math
import std/strutils
import ../src/observy/anyvalue
import ../src/observy/traces
import ../src/observy/json_encode

suite "hex encoding":
  test "hexEncodeTraceId produces 32 lowercase hex chars":
    var id: TraceId
    for i in 0 ..< 16: id[i] = byte(i)
    let s = hexEncodeTraceId(id)
    check s.len == 32
    check s == "000102030405060708090a0b0c0d0e0f"

  test "hexEncodeTraceId all-zero is 32 zeros":
    var id: TraceId
    check hexEncodeTraceId(id) == "0" & "0".repeat(31)

  test "hexEncodeTraceId all-ones (0xFF)":
    var id: TraceId
    for i in 0 ..< 16: id[i] = 0xFF'u8
    check hexEncodeTraceId(id) == "f".repeat(32)

  test "hexEncodeSpanId produces 16 lowercase hex chars":
    var id: SpanId
    for i in 0 ..< 8: id[i] = byte(i + 1)
    let s = hexEncodeSpanId(id)
    check s.len == 16
    check s == "0102030405060708"

  test "hexEncodeSpanId uses lowercase (not uppercase)":
    var id: SpanId
    id[0] = 0xAB'u8
    id[1] = 0xCD'u8
    let s = hexEncodeSpanId(id)
    check s[0..3] == "abcd"

suite "base64Encode":
  test "empty bytes produces empty string":
    check base64Encode(@[]) == ""

  test "known vector: [0x01, 0x02, 0x03] = AQID":
    check base64Encode(@[0x01'u8, 0x02, 0x03]) == "AQID"

  test "no line breaks in output":
    let data = newSeq[byte](60)
    check base64Encode(data).find('\n') < 0
    check base64Encode(data).find('\r') < 0

suite "jsonEncodeInt64 / jsonEncodeUint64":
  test "int64 positive is quoted string":
    check jsonEncodeInt64(42) == "\"42\""

  test "int64 negative is quoted string":
    check jsonEncodeInt64(-1) == "\"-1\""

  test "int64 min value":
    check jsonEncodeInt64(low(int64)) == "\"-9223372036854775808\""

  test "int64 max value":
    check jsonEncodeInt64(high(int64)) == "\"9223372036854775807\""

  test "uint64 large value is quoted":
    check jsonEncodeUint64(high(uint64)) == "\"18446744073709551615\""

  test "uint64 zero is quoted":
    check jsonEncodeUint64(0'u64) == "\"0\""

suite "jsonEncodeAnyValue":
  test "string value":
    let v = AnyValue(kind: avString, strVal: "hello")
    check jsonEncodeAnyValue(v) == "{\"stringValue\":\"hello\"}"

  test "bool true":
    let v = AnyValue(kind: avBool, boolVal: true)
    check jsonEncodeAnyValue(v) == "{\"boolValue\":true}"

  test "bool false":
    let v = AnyValue(kind: avBool, boolVal: false)
    check jsonEncodeAnyValue(v) == "{\"boolValue\":false}"

  test "int64 value is quoted string":
    let v = AnyValue(kind: avInt, intVal: 123'i64)
    check jsonEncodeAnyValue(v) == "{\"intValue\":\"123\"}"

  test "double finite":
    let v = AnyValue(kind: avDouble, dblVal: 3.14)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":3.14}"

  test "double NaN is string":
    let v = AnyValue(kind: avDouble, dblVal: NaN)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":\"NaN\"}"

  test "double Inf is string":
    let v = AnyValue(kind: avDouble, dblVal: Inf)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":\"Infinity\"}"

  test "double -Inf is string":
    let v = AnyValue(kind: avDouble, dblVal: NegInf)
    check jsonEncodeAnyValue(v) == "{\"doubleValue\":\"-Infinity\"}"

  test "bytes uses base64 (NOT hex)":
    let v = AnyValue(kind: avBytes, bytesVal: @[0x01'u8, 0x02, 0x03])
    let j = jsonEncodeAnyValue(v)
    check j.find("\"bytesValue\"") >= 0
    check j.find("AQID") >= 0  # base64 of [0x01, 0x02, 0x03]

  test "string value escapes double quote":
    let v = AnyValue(kind: avString, strVal: "say \"hi\"")
    check jsonEncodeAnyValue(v) == "{\"stringValue\":\"say \\\"hi\\\"\"}"

suite "jsonEncodeKVList":
  test "empty list is []":
    check jsonEncodeKVList(@[]) == "[]"

  test "single entry":
    let kvs = @[KeyValue(key: "k", value: AnyValue(kind: avString, strVal: "v"))]
    check jsonEncodeKVList(kvs) == "[{\"key\":\"k\",\"value\":{\"stringValue\":\"v\"}}]"

  test "two entries comma-separated":
    let kvs = @[
      KeyValue(key: "a", value: AnyValue(kind: avInt, intVal: 1)),
      KeyValue(key: "b", value: AnyValue(kind: avBool, boolVal: true)),
    ]
    let j = jsonEncodeKVList(kvs)
    check j.find(",") >= 0
    check j.find("\"a\"") >= 0
    check j.find("\"b\"") >= 0

suite "TraceId and SpanId not base64":
  test "hexEncodeTraceId output contains no = (base64 padding char)":
    var id: TraceId
    for i in 0 ..< 16: id[i] = 0xAB'u8
    check hexEncodeTraceId(id).find('=') < 0

  test "hexEncodeSpanId output contains no = (base64 padding char)":
    var id: SpanId
    for i in 0 ..< 8: id[i] = 0xCD'u8
    check hexEncodeSpanId(id).find('=') < 0
