# proto3 wire-format encoder utilities

const
  WireVarint* = 0'u8
  Wire64*     = 1'u8
  WireLen*    = 2'u8
  Wire32*     = 5'u8

type ProtoError* = object of IOError

proc isAllZero*(bytes: openArray[byte]): bool =
  ## True when every byte is zero. Used to detect unset fixed-size ID fields
  ## (TraceId/SpanId/parentSpanId) so they can be omitted like proto3 empty bytes.
  for b in bytes:
    if b != 0: return false
  true

# ---------------------------------------------------------------------------
# ProtoWriter
# ---------------------------------------------------------------------------

type ProtoWriter* = object
  buf*: seq[byte]

proc writeVarint*(w: var ProtoWriter; v: uint64) =
  var x = v
  while x > 0x7F'u64:
    w.buf.add(byte((x and 0x7F) or 0x80))
    x = x shr 7
  w.buf.add(byte(x))

proc writeTag*(w: var ProtoWriter; fieldNumber: uint32; wireType: uint8) {.inline.} =
  if fieldNumber == 0:
    raise newException(ProtoError, "proto: field number 0 is invalid")
  w.writeVarint(uint64(fieldNumber shl 3) or uint64(wireType))

proc writeInt32*(w: var ProtoWriter; fieldNumber: uint32; v: int32) =
  if v == 0: return
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(cast[uint64](int64(v)))

proc writeInt64*(w: var ProtoWriter; fieldNumber: uint32; v: int64) =
  if v == 0: return
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(cast[uint64](v))

proc writeUint32*(w: var ProtoWriter; fieldNumber: uint32; v: uint32) =
  if v == 0: return
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(uint64(v))

proc writeUint64*(w: var ProtoWriter; fieldNumber: uint32; v: uint64) =
  if v == 0: return
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(v)

proc writeBool*(w: var ProtoWriter; fieldNumber: uint32; v: bool) =
  if not v: return
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(1'u64)

proc writeSint32*(w: var ProtoWriter; fieldNumber: uint32; v: int32) =
  if v == 0: return
  let encoded = uint64((uint32(v) shl 1) xor uint32(v shr 31))
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(encoded)

proc writeSint64*(w: var ProtoWriter; fieldNumber: uint32; v: int64) =
  if v == 0: return
  let encoded = (uint64(v) shl 1) xor uint64(v shr 63)
  w.writeTag(fieldNumber, WireVarint)
  w.writeVarint(encoded)

proc writeFixed32*(w: var ProtoWriter; fieldNumber: uint32; v: uint32) =
  if v == 0: return
  w.writeTag(fieldNumber, Wire32)
  w.buf.add(byte(v and 0xFF))
  w.buf.add(byte((v shr 8) and 0xFF))
  w.buf.add(byte((v shr 16) and 0xFF))
  w.buf.add(byte((v shr 24) and 0xFF))

proc writeFixed64*(w: var ProtoWriter; fieldNumber: uint32; v: uint64) =
  if v == 0: return
  w.writeTag(fieldNumber, Wire64)
  for i in 0 ..< 8:
    w.buf.add(byte((v shr (i * 8)) and 0xFF))

proc writeFloat*(w: var ProtoWriter; fieldNumber: uint32; v: float32) =
  let bits = cast[uint32](v)
  if bits == 0: return
  w.writeTag(fieldNumber, Wire32)
  w.buf.add(byte(bits and 0xFF))
  w.buf.add(byte((bits shr 8) and 0xFF))
  w.buf.add(byte((bits shr 16) and 0xFF))
  w.buf.add(byte((bits shr 24) and 0xFF))

proc writeDouble*(w: var ProtoWriter; fieldNumber: uint32; v: float64) =
  let bits = cast[uint64](v)
  if bits == 0: return
  w.writeTag(fieldNumber, Wire64)
  for i in 0 ..< 8:
    w.buf.add(byte((bits shr (i * 8)) and 0xFF))

proc writeDoubleForce*(w: var ProtoWriter; fieldNumber: uint32; v: float64) =
  ## Write a double even when its value is 0.0 — for proto3 `optional double`
  ## fields whose presence is explicit (e.g. HistogramDataPoint.sum/min/max).
  let bits = cast[uint64](v)
  w.writeTag(fieldNumber, Wire64)
  for i in 0 ..< 8:
    w.buf.add(byte((bits shr (i * 8)) and 0xFF))

proc writeFixed64Force*(w: var ProtoWriter; fieldNumber: uint32; v: uint64) =
  ## Write a fixed64 even when its value is 0 — for fields where 0 is meaningful
  ## and must not be suppressed.
  w.writeTag(fieldNumber, Wire64)
  for i in 0 ..< 8:
    w.buf.add(byte((v shr (i * 8)) and 0xFF))

proc writeBytes*(w: var ProtoWriter; fieldNumber: uint32; v: openArray[byte]) =
  if v.len == 0: return
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(v.len))
  for b in v: w.buf.add(b)

proc writeString*(w: var ProtoWriter; fieldNumber: uint32; v: string) =
  if v.len == 0: return
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(v.len))
  for c in v: w.buf.add(byte(c))

proc writeEmbedded*(w: var ProtoWriter; fieldNumber: uint32; inner: ProtoWriter) =
  if inner.buf.len == 0: return
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(inner.buf.len))
  for b in inner.buf: w.buf.add(b)

proc writePackedUint64*(w: var ProtoWriter; fieldNumber: uint32; vs: openArray[uint64]) =
  if vs.len == 0: return
  var tmp: ProtoWriter
  for v in vs: tmp.writeVarint(v)
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(tmp.buf.len))
  for b in tmp.buf: w.buf.add(b)

proc writePackedInt64*(w: var ProtoWriter; fieldNumber: uint32; vs: openArray[int64]) =
  if vs.len == 0: return
  var tmp: ProtoWriter
  for v in vs: tmp.writeVarint(cast[uint64](v))
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(tmp.buf.len))
  for b in tmp.buf: w.buf.add(b)

proc writePackedDouble*(w: var ProtoWriter; fieldNumber: uint32; vs: openArray[float64]) =
  if vs.len == 0: return
  var tmp: ProtoWriter
  for v in vs:
    let bits = cast[uint64](v)
    for i in 0 ..< 8: tmp.buf.add(byte((bits shr (i * 8)) and 0xFF))
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(tmp.buf.len))
  for b in tmp.buf: w.buf.add(b)

proc writePackedFixed64*(w: var ProtoWriter; fieldNumber: uint32; vs: openArray[uint64]) =
  ## Packed repeated fixed64 (8 bytes each) — e.g. HistogramDataPoint.bucket_counts.
  if vs.len == 0: return
  var tmp: ProtoWriter
  for v in vs:
    for i in 0 ..< 8: tmp.buf.add(byte((v shr (i * 8)) and 0xFF))
  w.writeTag(fieldNumber, WireLen)
  w.writeVarint(uint64(tmp.buf.len))
  for b in tmp.buf: w.buf.add(b)

# ---------------------------------------------------------------------------
# ProtoReader
# ---------------------------------------------------------------------------

type ProtoReader* = object
  data*: seq[byte]
  pos*:  int

proc readRawByte(r: var ProtoReader): byte =
  if r.pos >= r.data.len:
    raise newException(ProtoError, "proto: unexpected end of buffer")
  result = r.data[r.pos]
  inc r.pos

proc readVarint*(r: var ProtoReader): uint64 =
  var shift = 0
  result = 0
  while true:
    let b = r.readRawByte()
    result = result or (uint64(b and 0x7F) shl shift)
    if (b and 0x80) == 0: break
    inc(shift, 7)
    if shift >= 64:
      raise newException(ProtoError, "proto: varint overflow")

proc readTag*(r: var ProtoReader): (uint32, uint8) =
  let v = r.readVarint()
  let fieldNumber = uint32(v shr 3)
  if fieldNumber == 0:
    raise newException(ProtoError, "proto: invalid field number 0 in tag")
  result = (fieldNumber, uint8(v and 0x07))

proc readInt32*(r: var ProtoReader): int32 =
  let v = r.readVarint()
  # proto3 int32 is sign-extended from 32 bits when encoded as 64-bit varint
  cast[int32](uint32(v and 0xFFFF_FFFF'u64))

proc readInt64*(r: var ProtoReader): int64 =
  cast[int64](r.readVarint())

proc readUint32*(r: var ProtoReader): uint32 =
  let v = r.readVarint()
  if v > uint64(high(uint32)):
    raise newException(ProtoError, "proto: varint too large for uint32")
  uint32(v)

proc readUint64*(r: var ProtoReader): uint64 =
  r.readVarint()

proc readBool*(r: var ProtoReader): bool =
  r.readVarint() != 0

proc readSint32*(r: var ProtoReader): int32 =
  let v = r.readVarint()
  if v > uint64(high(uint32)):
    raise newException(ProtoError, "proto: varint too large for sint32")
  let z = uint32(v)
  cast[int32]((z shr 1) xor (0'u32 - (z and 1)))

proc readSint64*(r: var ProtoReader): int64 =
  let z = r.readVarint()
  cast[int64]((z shr 1) xor (0'u64 - (z and 1)))

proc readFixed32*(r: var ProtoReader): uint32 =
  let a = r.readRawByte()
  let b = r.readRawByte()
  let c = r.readRawByte()
  let d = r.readRawByte()
  uint32(a) or (uint32(b) shl 8) or (uint32(c) shl 16) or (uint32(d) shl 24)

proc readFixed64*(r: var ProtoReader): uint64 =
  result = 0
  for i in 0 ..< 8:
    result = result or (uint64(r.readRawByte()) shl (i * 8))

proc readFloat*(r: var ProtoReader): float32 =
  cast[float32](r.readFixed32())

proc readDouble*(r: var ProtoReader): float64 =
  cast[float64](r.readFixed64())

proc readBytes*(r: var ProtoReader): seq[byte] =
  let n64 = r.readVarint()
  let remaining = uint64(r.data.len - r.pos)
  if n64 > remaining:
    raise newException(ProtoError, "proto: length-delimited field exceeds buffer")
  if n64 > uint64(high(int)):
    raise newException(ProtoError, "proto: length-delimited field too large")
  let n = int(n64)
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = r.readRawByte()

proc readString*(r: var ProtoReader): string =
  let n64 = r.readVarint()
  let remaining = uint64(r.data.len - r.pos)
  if n64 > remaining:
    raise newException(ProtoError, "proto: string field exceeds buffer")
  if n64 > uint64(high(int)):
    raise newException(ProtoError, "proto: string field too large")
  let n = int(n64)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(r.readRawByte())

proc skipField*(r: var ProtoReader; wireType: uint8) =
  case wireType
  of WireVarint: discard r.readVarint()
  of Wire64:     discard r.readFixed64()
  of WireLen:
    let n64 = r.readVarint()
    let remaining = uint64(r.data.len - r.pos)
    if n64 > remaining:
      raise newException(ProtoError, "proto: skip: length-delimited field exceeds buffer")
    r.pos += int(n64)
  of Wire32:     discard r.readFixed32()
  else:
    raise newException(ProtoError, "proto: unknown wire type: " & $wireType)

# ---------------------------------------------------------------------------
# Zigzag helpers (exposed for testing)
# ---------------------------------------------------------------------------

proc zigzagEncode32*(v: int32): uint32 {.inline.} =
  (uint32(v) shl 1) xor uint32(v shr 31)

proc zigzagDecode32*(v: uint32): int32 {.inline.} =
  cast[int32]((v shr 1) xor (0'u32 - (v and 1)))

proc zigzagEncode64*(v: int64): uint64 {.inline.} =
  (uint64(v) shl 1) xor uint64(v shr 63)

proc zigzagDecode64*(v: uint64): int64 {.inline.} =
  cast[int64]((v shr 1) xor (0'u64 - (v and 1)))
