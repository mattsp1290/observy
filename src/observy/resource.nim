# Resource type (labeled key-value attributes for a telemetry source)
import std/base64
import ./anyvalue
import ./proto

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
    droppedAttributesCount*:  int

  InstrumentationScope* = object
    name*:                    string
    version*:                 string
    attributes*:              AttributeSet
    droppedAttributesCount*:  int

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
  case v.kind
  of avString: w.writeString(1, v.strVal)
  of avBool:   w.writeBool(2, v.boolVal)
  of avInt:    w.writeInt64(3, v.intVal)
  of avDouble: w.writeDouble(4, v.dblVal)
  of avArray:
    var arr: ProtoWriter
    for elem in v.arrayVal:
      var elemW: ProtoWriter
      protoEncodeAnyValue(elemW, elem)
      arr.writeEmbedded(1, elemW)
    w.writeEmbedded(5, arr)
  of avKvList:
    var kvl: ProtoWriter
    protoEncodeKeyValues(kvl, 1, v.kvlistVal)
    w.writeEmbedded(6, kvl)
  of avBytes:  w.writeBytes(7, v.bytesVal)

proc protoEncode*(r: Resource): seq[byte] =
  var w: ProtoWriter
  protoEncodeKeyValues(w, 1, r.attributes.pairs)
  w.writeUint32(2, uint32(r.droppedAttributesCount))
  w.buf

proc protoEncode*(s: InstrumentationScope): seq[byte] =
  var w: ProtoWriter
  w.writeString(1, s.name)
  w.writeString(2, s.version)
  protoEncodeKeyValues(w, 3, s.attributes.pairs)
  w.writeUint32(4, uint32(s.droppedAttributesCount))
  w.buf

# ---------------------------------------------------------------------------
# JSON encode
# ---------------------------------------------------------------------------

proc jsonEncodeAnyValue*(v: AnyValue): string

proc jsonEncodeKeyValue*(kv: KeyValue): string =
  "{\"key\":\"" & kv.key & "\",\"value\":" & jsonEncodeAnyValue(kv.value) & "}"

proc jsonEncodeAnyValue*(v: AnyValue): string =
  case v.kind
  of avString:
    "{\"stringValue\":\"" & v.strVal & "\"}"
  of avBool:
    if v.boolVal: "{\"boolValue\":true}" else: "{\"boolValue\":false}"
  of avInt:
    "{\"intValue\":\"" & $v.intVal & "\"}"
  of avDouble:
    "{\"doubleValue\":" & $v.dblVal & "}"
  of avBytes:
    "{\"bytesValue\":\"" & encode(v.bytesVal) & "\"}"
  of avArray:
    var elems = "["
    for i, elem in v.arrayVal:
      if i > 0: elems.add(",")
      elems.add(jsonEncodeAnyValue(elem))
    elems.add("]")
    "{\"arrayValue\":{\"values\":" & elems & "}}"
  of avKvList:
    var kvs = "["
    for i, kv in v.kvlistVal:
      if i > 0: kvs.add(",")
      kvs.add(jsonEncodeKeyValue(kv))
    kvs.add("]")
    "{\"kvlistValue\":{\"values\":" & kvs & "}}"

proc jsonEncodeAttributes(pairs: openArray[KeyValue]): string =
  result = "["
  for i, kv in pairs:
    if i > 0: result.add(",")
    result.add(jsonEncodeKeyValue(kv))
  result.add("]")

proc jsonEncode*(r: Resource): string =
  result = "{\"attributes\":" & jsonEncodeAttributes(r.attributes.pairs)
  if r.droppedAttributesCount > 0:
    result.add(",\"droppedAttributesCount\":" & $r.droppedAttributesCount)
  result.add("}")

proc jsonEncode*(s: InstrumentationScope): string =
  result = "{\"name\":\"" & s.name & "\""
  if s.version.len > 0:
    result.add(",\"version\":\"" & s.version & "\"")
  result.add(",\"attributes\":" & jsonEncodeAttributes(s.attributes.pairs))
  if s.droppedAttributesCount > 0:
    result.add(",\"droppedAttributesCount\":" & $s.droppedAttributesCount)
  result.add("}")
