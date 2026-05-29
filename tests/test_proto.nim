import unittest
import std/os
import ../src/observy/anyvalue
import ../src/observy/proto

# ---------------------------------------------------------------------------
# Varint encode/decode
# ---------------------------------------------------------------------------

suite "varint":
  test "zero encodes as single byte 0x00":
    var w: ProtoWriter
    w.writeVarint(0'u64)
    check w.buf == @[0x00'u8]

  test "1 encodes as single byte":
    var w: ProtoWriter
    w.writeVarint(1'u64)
    check w.buf == @[0x01'u8]

  test "127 encodes as single byte":
    var w: ProtoWriter
    w.writeVarint(127'u64)
    check w.buf == @[0x7F'u8]

  test "128 requires two bytes":
    var w: ProtoWriter
    w.writeVarint(128'u64)
    check w.buf == @[0x80'u8, 0x01'u8]

  test "300 encodes correctly":
    var w: ProtoWriter
    w.writeVarint(300'u64)
    check w.buf == @[0xAC'u8, 0x02'u8]

  test "max uint64":
    var w: ProtoWriter
    w.writeVarint(high(uint64))
    var r = ProtoReader(data: w.buf)
    check r.readVarint() == high(uint64)

  test "2^63-1 roundtrip":
    let v = uint64(high(int64))
    var w: ProtoWriter
    w.writeVarint(v)
    var r = ProtoReader(data: w.buf)
    check r.readVarint() == v

  test "roundtrip assorted values":
    for v in [0'u64, 1, 127, 128, 255, 256, 16383, 16384, 2097151, 2097152,
              268435455'u64, 268435456'u64, high(uint64)]:
      var w: ProtoWriter
      w.writeVarint(v)
      var r = ProtoReader(data: w.buf)
      check r.readVarint() == v

# ---------------------------------------------------------------------------
# Zigzag encode/decode
# ---------------------------------------------------------------------------

suite "zigzag":
  test "zigzag32 canonical pairs":
    check zigzagEncode32(0'i32)  == 0'u32
    check zigzagEncode32(-1'i32) == 1'u32
    check zigzagEncode32(1'i32)  == 2'u32
    check zigzagEncode32(-2'i32) == 3'u32
    check zigzagEncode32(high(int32)) == uint32(high(int32)) * 2
    check zigzagEncode32(low(int32))  == high(uint32)

  test "zigzag32 decode inverts encode":
    for v in [0'i32, 1, -1, 127, -128, high(int32), low(int32)]:
      check zigzagDecode32(zigzagEncode32(v)) == v

  test "zigzag64 canonical pairs":
    check zigzagEncode64(0'i64)  == 0'u64
    check zigzagEncode64(-1'i64) == 1'u64
    check zigzagEncode64(1'i64)  == 2'u64
    check zigzagEncode64(-2'i64) == 3'u64

  test "negative sint64 zigzag roundtrip":
    for v in [0'i64, 1, -1, -128, 127, high(int64), low(int64),
              -9223372036854775807'i64]:
      check zigzagDecode64(zigzagEncode64(v)) == v

  test "sint32 field write/read roundtrip":
    for v in [0'i32, 1, -1, 127, -128, high(int32), low(int32)]:
      var w: ProtoWriter
      w.writeSint32(1, v)
      if v == 0:
        check w.buf.len == 0
      else:
        var r = ProtoReader(data: w.buf)
        let (fn, wt) = r.readTag()
        check fn == 1
        check wt == WireVarint
        check r.readSint32() == v

  test "sint64 field write/read roundtrip":
    for v in [0'i64, 1, -1, high(int64), low(int64)]:
      var w: ProtoWriter
      w.writeSint64(2, v)
      if v == 0:
        check w.buf.len == 0
      else:
        var r = ProtoReader(data: w.buf)
        let (fn, wt) = r.readTag()
        check fn == 2
        check wt == WireVarint
        check r.readSint64() == v

# ---------------------------------------------------------------------------
# Fixed-width types
# ---------------------------------------------------------------------------

suite "fixed width":
  test "fixed32 little-endian":
    var w: ProtoWriter
    w.writeFixed32(1, 0x01020304'u32)
    check w.buf[1 ..< 5] == @[0x04'u8, 0x03, 0x02, 0x01]
    var r = ProtoReader(data: w.buf)
    let (_, _) = r.readTag()
    check r.readFixed32() == 0x01020304'u32

  test "fixed64 little-endian roundtrip":
    let v = 0x0102030405060708'u64
    var w: ProtoWriter
    w.writeFixed64(1, v)
    var r = ProtoReader(data: w.buf)
    let (_, _) = r.readTag()
    check r.readFixed64() == v

  test "float roundtrip":
    for v in [1.0'f32, -1.0'f32, 3.14'f32]:
      var w: ProtoWriter
      w.writeFloat(1, v)
      var r = ProtoReader(data: w.buf)
      let (_, _) = r.readTag()
      check r.readFloat() == v

  test "double roundtrip":
    for v in [1.0'f64, -1.0'f64, 3.141592653589793'f64]:
      var w: ProtoWriter
      w.writeDouble(1, v)
      var r = ProtoReader(data: w.buf)
      let (_, _) = r.readTag()
      check r.readDouble() == v

# ---------------------------------------------------------------------------
# Length-delimited fields
# ---------------------------------------------------------------------------

suite "length-delimited":
  test "string roundtrip":
    var w: ProtoWriter
    w.writeString(1, "hello")
    var r = ProtoReader(data: w.buf)
    let (fn, wt) = r.readTag()
    check fn == 1
    check wt == WireLen
    check r.readString() == "hello"

  test "bytes roundtrip":
    let payload = @[0x01'u8, 0x02, 0x03]
    var w: ProtoWriter
    w.writeBytes(1, payload)
    var r = ProtoReader(data: w.buf)
    let (_, _) = r.readTag()
    check r.readBytes() == payload

  test "empty string omitted":
    var w: ProtoWriter
    w.writeString(1, "")
    check w.buf.len == 0

  test "empty bytes omitted":
    var w: ProtoWriter
    w.writeBytes(1, @[])
    check w.buf.len == 0

# ---------------------------------------------------------------------------
# Embedded messages
# ---------------------------------------------------------------------------

suite "embedded messages":
  test "nested message roundtrip":
    var inner: ProtoWriter
    inner.writeUint64(1, 42)
    var outer: ProtoWriter
    outer.writeEmbedded(3, inner)
    var r = ProtoReader(data: outer.buf)
    let (fn, wt) = r.readTag()
    check fn == 3
    check wt == WireLen
    let nested = r.readBytes()
    var nr = ProtoReader(data: nested)
    let (ifn, _) = nr.readTag()
    check ifn == 1
    check nr.readUint64() == 42

  test "empty embedded message omitted":
    var inner: ProtoWriter
    var outer: ProtoWriter
    outer.writeEmbedded(1, inner)
    check outer.buf.len == 0

# ---------------------------------------------------------------------------
# Packed repeated fields
# ---------------------------------------------------------------------------

suite "packed repeated":
  test "packed uint64 roundtrip":
    let vs = @[1'u64, 128, 16384, high(uint64)]
    var w: ProtoWriter
    w.writePackedUint64(1, vs)
    var r = ProtoReader(data: w.buf)
    let (fn, wt) = r.readTag()
    check fn == 1
    check wt == WireLen
    let raw = r.readBytes()
    var pr = ProtoReader(data: raw)
    var got: seq[uint64]
    while pr.pos < pr.data.len:
      got.add(pr.readVarint())
    check got == vs

  test "empty packed field omitted":
    var w: ProtoWriter
    w.writePackedUint64(1, @[])
    check w.buf.len == 0

# ---------------------------------------------------------------------------
# Proto3 default-omission
# ---------------------------------------------------------------------------

suite "proto3 defaults omitted":
  test "int32 zero omitted":
    var w: ProtoWriter
    w.writeInt32(1, 0)
    check w.buf.len == 0

  test "int64 zero omitted":
    var w: ProtoWriter
    w.writeInt64(1, 0)
    check w.buf.len == 0

  test "uint32 zero omitted":
    var w: ProtoWriter
    w.writeUint32(1, 0)
    check w.buf.len == 0

  test "uint64 zero omitted":
    var w: ProtoWriter
    w.writeUint64(1, 0)
    check w.buf.len == 0

  test "bool false omitted":
    var w: ProtoWriter
    w.writeBool(1, false)
    check w.buf.len == 0

  test "float zero omitted":
    var w: ProtoWriter
    w.writeFloat(1, 0.0'f32)
    check w.buf.len == 0

  test "double zero omitted":
    var w: ProtoWriter
    w.writeDouble(1, 0.0'f64)
    check w.buf.len == 0

# ---------------------------------------------------------------------------
# Tag encoding
# ---------------------------------------------------------------------------

suite "tag encoding":
  test "field 1 varint tag = 0x08":
    var w: ProtoWriter
    w.writeTag(1, WireVarint)
    check w.buf == @[0x08'u8]

  test "field 2 length-delimited tag = 0x12":
    var w: ProtoWriter
    w.writeTag(2, WireLen)
    check w.buf == @[0x12'u8]

  test "field 1 fixed32 tag = 0x0D":
    var w: ProtoWriter
    w.writeTag(1, Wire32)
    check w.buf == @[0x0D'u8]

  test "field 1 fixed64 tag = 0x09":
    var w: ProtoWriter
    w.writeTag(1, Wire64)
    check w.buf == @[0x09'u8]

# ---------------------------------------------------------------------------
# Validation and error handling
# ---------------------------------------------------------------------------

suite "validation":
  test "writeTag field 0 raises ProtoError":
    var w: ProtoWriter
    expect ProtoError: w.writeTag(0, WireVarint)

  test "readTag field 0 raises ProtoError":
    var w: ProtoWriter
    w.writeVarint(0'u64)  # encodes tag with field=0, wire=0
    var r = ProtoReader(data: w.buf)
    expect ProtoError: discard r.readTag()

  test "readBytes truncated raises ProtoError":
    # declare length 10 but provide only 3 bytes
    var w: ProtoWriter
    w.writeTag(1, WireLen)
    w.writeVarint(10'u64)
    w.buf.add(0x01'u8); w.buf.add(0x02'u8); w.buf.add(0x03'u8)
    var r = ProtoReader(data: w.buf)
    discard r.readTag()
    expect ProtoError: discard r.readBytes()

  test "readString truncated raises ProtoError":
    var w: ProtoWriter
    w.writeTag(1, WireLen)
    w.writeVarint(5'u64)
    w.buf.add(byte('a'))
    var r = ProtoReader(data: w.buf)
    discard r.readTag()
    expect ProtoError: discard r.readString()

  test "readUint32 overflow raises ProtoError":
    var w: ProtoWriter
    w.writeVarint(uint64(high(uint32)) + 1)
    var r = ProtoReader(data: w.buf)
    expect ProtoError: discard r.readUint32()

  test "readSint32 overflow raises ProtoError":
    var w: ProtoWriter
    w.writeVarint(uint64(high(uint32)) + 1)
    var r = ProtoReader(data: w.buf)
    expect ProtoError: discard r.readSint32()

  test "skipField varint":
    var w: ProtoWriter
    w.writeVarint(300'u64)
    w.writeVarint(42'u64)
    var r = ProtoReader(data: w.buf)
    r.skipField(WireVarint)
    check r.readVarint() == 42

  test "skipField length-delimited":
    var w: ProtoWriter
    w.writeVarint(3'u64)
    w.buf.add(0x01'u8); w.buf.add(0x02'u8); w.buf.add(0x03'u8)
    w.writeVarint(99'u64)
    var r = ProtoReader(data: w.buf)
    r.skipField(WireLen)
    check r.readVarint() == 99

  test "skipField unknown wire type raises ProtoError":
    var r = ProtoReader(data: @[0x00'u8])
    expect ProtoError: r.skipField(3'u8)

# ---------------------------------------------------------------------------
# Golden-byte fixture tests
# Construct the same Nim model used in tools/gen_fixtures.py, encode with
# ProtoWriter, compare output byte-for-byte against the Python-SDK-generated .bin
# ---------------------------------------------------------------------------

proc readBin(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc encodeAnyValue(w: var ProtoWriter; v: AnyValue) =
  # avArray/avKvList intentionally not handled here — none of the current fixtures
  # exercise them. A missing AnyValue kind produces an empty embedded message which
  # writeEmbedded skips, so a golden-byte test would fail loudly rather than silently pass.
  case v.kind
  of avString: w.writeString(1, v.strVal)
  of avBool:   w.writeBool(2, v.boolVal)
  of avInt:    w.writeInt64(3, v.intVal)
  of avDouble: w.writeDouble(4, v.dblVal)
  of avBytes:  w.writeBytes(7, v.bytesVal)
  else: discard

proc encodeKVs(w: var ProtoWriter; fieldNo: uint32; kvs: openArray[KeyValue]) =
  for kv in kvs:
    var inner: ProtoWriter
    inner.writeString(1, kv.key)
    var valW: ProtoWriter
    encodeAnyValue(valW, kv.value)
    inner.writeEmbedded(2, valW)
    w.writeEmbedded(fieldNo, inner)

suite "golden-byte proto fixtures":
  # Fixture paths relative to the project root (testament runs from there)
  const
    TID = [0x4b'u8,0xf9,0x2f,0x35,0x77,0xb3,0x4d,0xa6,
           0xa3,0xce,0x92,0x9d,0x0e,0x0e,0x47,0x36]
    SID = [0x00'u8,0xf0,0x67,0xaa,0x0b,0xa9,0x02,0xb7]

  test "minimal_span.bin — trace_id, span_id, name, kind, fixed64 timestamps":
    # Reproduces the minimal_span constructed in gen_fixtures.py:
    #   trace_id=TID, span_id=SID, name="GET /api/users",
    #   kind=SPAN_KIND_SERVER(2), start=10^18 ns, end=10^18+10^9 ns
    var w: ProtoWriter
    w.writeBytes(1, TID)                            # trace_id  field 1
    w.writeBytes(2, SID)                            # span_id   field 2
    w.writeString(5, "GET /api/users")              # name      field 5
    w.writeInt32(6, 2'i32)                          # kind      field 6 (SERVER)
    w.writeFixed64(7, 1_000_000_000_000_000_000'u64) # start   field 7 (fixed64)
    w.writeFixed64(8, 1_000_000_001_000_000_000'u64) # end     field 8 (fixed64)
    check w.buf == readBin("tests/fixtures/proto/minimal_span.bin")

  test "counter_metric.bin — Sum metric, sfixed64 as_int, varint flags, kv attrs":
    # counter: name, desc, unit, sum{ dp{start,time,as_int=42,attrs}, temp=CUMULATIVE, monotonic=true }
    var dpW: ProtoWriter
    dpW.writeFixed64(2, 1_000_000_000_000_000_000'u64)     # start_time_unix_nano
    dpW.writeFixed64(3, 1_001_000_000_000_000_000'u64)     # time_unix_nano
    dpW.writeFixed64(6, cast[uint64](42'i64))               # as_int (sfixed64 wire1)
    encodeKVs(dpW, 7, [                                     # attributes field 7
      KeyValue(key: "http.method",
               value: AnyValue(kind: avString, strVal: "GET")),
    ])
    # flags=0 suppressed
    var sumW: ProtoWriter
    sumW.writeEmbedded(1, dpW)      # data_points
    sumW.writeInt32(2, 2'i32)       # AGGREGATION_TEMPORALITY_CUMULATIVE
    sumW.writeBool(3, true)         # is_monotonic
    var w: ProtoWriter
    w.writeString(1, "http.requests.total")
    w.writeString(2, "Total HTTP requests")
    w.writeString(3, "{request}")
    w.writeEmbedded(7, sumW)        # sum (Metric.sum = field 7)
    check w.buf == readBin("tests/fixtures/proto/counter_metric.bin")

  test "log_record.bin — fixed64 times, severity, body AnyValue, fixed32 flags, trace/span ids":
    # log: time=10^18, observed=10^18+10^8, severity=INFO(9), text="INFO",
    #      body=string("user login succeeded"), 3 attrs, flags=1 (fixed32),
    #      trace_id=TID, span_id=SID, observed at field 11
    var bodyW: ProtoWriter
    bodyW.writeString(1, "user login succeeded")  # AnyValue string_value

    var w: ProtoWriter
    w.writeFixed64(1, 1_000_000_000_000_000_000'u64)   # time_unix_nano     field 1
    w.writeInt32(2, 9'i32)                              # severity_number    field 2 (INFO=9)
    w.writeString(3, "INFO")                            # severity_text      field 3
    w.writeEmbedded(5, bodyW)                           # body               field 5
    encodeKVs(w, 6, [                                   # attributes         field 6
      KeyValue(key: "user.id", value: AnyValue(kind: avString, strVal: "u-99999")),
      KeyValue(key: "ip",      value: AnyValue(kind: avString, strVal: "192.168.1.1")),
      KeyValue(key: "attempt", value: AnyValue(kind: avInt,    intVal: 1'i64)),
    ])
    w.writeFixed32(8, 1'u32)                            # flags (fixed32!)   field 8
    w.writeBytes(9, TID)                                # trace_id           field 9
    w.writeBytes(10, SID)                               # span_id            field 10
    w.writeFixed64(11, 1_000_000_000_100_000_000'u64)  # observed_time      field 11
    check w.buf == readBin("tests/fixtures/proto/log_record.bin")
