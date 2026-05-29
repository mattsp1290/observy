import unittest
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
