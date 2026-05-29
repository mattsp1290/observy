# Resource type (labeled key-value attributes for a telemetry source)
import ./anyvalue
import ./proto
import ./json_encode
export json_encode

# opentelemetry-proto v1.10.0 field numbers
# common/v1/common.proto
#   AnyValue:            string_value=1, bool_value=2, int_value=3, double_value=4,
#                        array_value=5, kvlist_value=6, bytes_value=7
#   ArrayValue:          values=1
#   KeyValueList:        values=1
#   KeyValue:            key=1, value=2
#   InstrumentationScope: name=1, version=2, attributes=3, dropped_attributes_count=4
# resource/v1/resource.proto
#   Resource:            attributes=1, dropped_attributes_count=2

type
  Resource* = object
    attributes*:              AttributeSet
    droppedAttributesCount*:  uint32

  InstrumentationScope* = object
    name*:                    string
    version*:                 string
    attributes*:              AttributeSet
    droppedAttributesCount*:  uint32

# ---------------------------------------------------------------------------
# Proto encode
# ---------------------------------------------------------------------------

proc protoEncodeAnyValue*(w: var ProtoWriter; v: AnyValue)

proc protoEncodeKeyValues*(w: var ProtoWriter; fieldNumber: uint32;
                            kvs: openArray[KeyValue]) =
  for kv in kvs:
    var inner: ProtoWriter
    inner.writeString(1, kv.key)
    var valW: ProtoWriter
    protoEncodeAnyValue(valW, kv.value)
    inner.writeEmbedded(2, valW)
    w.writeEmbedded(fieldNumber, inner)

proc protoEncodeAnyValue*(w: var ProtoWriter; v: AnyValue) =
  # AnyValue.value is a proto3 oneof: the SET case must always be emitted even
  # when the value is the type's default (empty string, false, 0, 0.0, empty
  # bytes). Use *Force variants to bypass zero-suppression for scalar cases.
  case v.kind
  of avString: w.writeStringForce(1, v.strVal)
  of avBool:   w.writeBoolForce(2, v.boolVal)
  of avInt:    w.writeInt64Force(3, v.intVal)
  of avDouble: w.writeDoubleForce(4, v.dblVal)
  of avArray:
    var arr: ProtoWriter
    for elem in v.arrayVal:
      var elemW: ProtoWriter
      protoEncodeAnyValue(elemW, elem)
      arr.writeEmbeddedForce(1, elemW)
    w.writeEmbeddedForce(5, arr)
  of avKvList:
    var kvl: ProtoWriter
    protoEncodeKeyValues(kvl, 1, v.kvlistVal)
    w.writeEmbeddedForce(6, kvl)
  of avBytes:  w.writeBytesForce(7, v.bytesVal)

proc protoEncode*(r: Resource): seq[byte] =
  var w: ProtoWriter
  protoEncodeKeyValues(w, 1, r.attributes.pairs)
  if r.droppedAttributesCount != 0:
    w.writeUint32(2, r.droppedAttributesCount)
  w.buf

proc protoEncode*(s: InstrumentationScope): seq[byte] =
  var w: ProtoWriter
  w.writeString(1, s.name)
  w.writeString(2, s.version)
  protoEncodeKeyValues(w, 3, s.attributes.pairs)
  if s.droppedAttributesCount != 0:
    w.writeUint32(4, s.droppedAttributesCount)
  w.buf

# ---------------------------------------------------------------------------
# JSON encode (jsonEscape / jsonEncodeAnyValue / jsonEncodeKeyValue from json_encode)
# ---------------------------------------------------------------------------

proc jsonEncodeAttributes(pairs: openArray[KeyValue]): string =
  result = "["
  for i, kv in pairs:
    if i > 0: result.add(",")
    result.add(jsonEncodeKeyValue(kv))
  result.add("]")

proc jsonEncode*(r: Resource): string =
  result = "{\"attributes\":" & jsonEncodeAttributes(r.attributes.pairs)
  if r.droppedAttributesCount != 0:
    result.add(",\"droppedAttributesCount\":" & $r.droppedAttributesCount)
  result.add("}")

proc jsonEncode*(s: InstrumentationScope): string =
  result = "{\"name\":" & jsonEscape(s.name)
  if s.version.len > 0:
    result.add(",\"version\":" & jsonEscape(s.version))
  result.add(",\"attributes\":" & jsonEncodeAttributes(s.attributes.pairs))
  if s.droppedAttributesCount != 0:
    result.add(",\"droppedAttributesCount\":" & $s.droppedAttributesCount)
  result.add("}")
