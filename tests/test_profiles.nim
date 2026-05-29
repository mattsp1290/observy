import unittest
import std/json
import ../src/observy/anyvalue
import ../src/observy/proto
import ../src/observy/resource

when defined(observyProfiles):
  import ../src/observy/profiles

  proc sampleProfile(): Profile =
    Profile(
      sampleType: @[ValueType(typ: 1, unit: 2)],
      sample: @[Sample(
        locationIndex: @[0'u64, 1'u64],
        value: @[100'i64, 200'i64],
        label: @[Label(key: 3, str: 4)],
        timestampsUnixNano: @[1_700_000_000_000_000_000'u64])],
      mapping: @[Mapping(id: 1'u64, memoryStart: 0x1000'u64,
                         memoryLimit: 0x2000'u64, filename: 5)],
      location: @[Location(id: 1'u64, mappingId: 1'u64, address: 0x1234'u64,
                           lines: @[Line(functionId: 1'u64, line: 42)])],
      function: @[Function(id: 1'u64, name: 6, startLine: 10)],
      stringTable: @["", "cpu", "nanoseconds", "thread", "main", "app.bin", "doWork"],
      timeNanos: 1_700_000_000_000_000_000'i64,
      durationNanos: 1_000_000_000'i64,
      period: 10_000_000'i64,
      periodType: ValueType(typ: 1, unit: 2))

  suite "Profiles data model (alpha)":
    test "Profile construction holds all fields":
      let p = sampleProfile()
      check p.sampleType.len == 1
      check p.sample.len == 1
      check p.sample[0].value == @[100'i64, 200'i64]
      check p.mapping.len == 1
      check p.location.len == 1
      check p.location[0].lines[0].line == 42
      check p.function.len == 1
      check p.stringTable.len == 7

  suite "Profiles proto encoding (alpha)":
    test "encodeProfile produces non-empty binary":
      var w: ProtoWriter
      encodeProfile(w, sampleProfile())
      check w.buf.len > 0

    test "protoEncodeProfilesRequest wraps in ExportProfilesServiceRequest":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let bytes = protoEncodeProfilesRequest(res, scope, @[sampleProfile()])
      check bytes.len > 0
      # Top-level field 1 = ResourceProfiles, wire type 2 (length-delimited) → tag 0x0a
      check bytes[0] == 0x0a'u8

    test "packed locationIndex round-trips a zero-valued element":
      # Regression: a per-element zero-suppressing writer would drop the 0 here,
      # decoding @[0, 1] back to @[1]. Packed encoding must preserve both.
      # Encode via the public encodeProfile, then decode Profile.sample (field 2,
      # embedded) → Sample.locationIndex (field 1, packed varints).
      let p = Profile(sample: @[Sample(
        locationIndex: @[0'u64, 1'u64], value: @[5'i64])])
      var w: ProtoWriter
      encodeProfile(w, p)
      var r = ProtoReader(data: w.buf)
      var sampleBytes: seq[byte]
      while r.pos < w.buf.len:
        let (fn, wt) = r.readTag()
        if fn == 2'u32:
          sampleBytes = r.readBytes()
        else:
          r.skipField(wt)
      check sampleBytes.len > 0
      var sr = ProtoReader(data: sampleBytes)
      var decoded: seq[uint64]
      while sr.pos < sampleBytes.len:
        let (fn, wt) = sr.readTag()
        if fn == 1'u32:                 # locationIndex (packed → length-delimited)
          let packed = sr.readBytes()
          var pr = ProtoReader(data: packed)
          while pr.pos < packed.len:
            decoded.add(pr.readVarint())
        else:
          sr.skipField(wt)
      check decoded == @[0'u64, 1'u64]

    test "all-default profile encodes to empty (period_type default suppressed)":
      var w: ProtoWriter
      encodeProfile(w, Profile())
      # Every field is its zero value; the embedded period_type (ValueType(0,0))
      # is itself empty and suppressed → the whole message is empty.
      check w.buf.len == 0

  suite "Profiles JSON encoding (alpha)":
    test "profileToJson produces valid ExportProfilesServiceRequest JSON":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[sampleProfile()]))
      check j.hasKey("resourceProfiles")
      check j["resourceProfiles"][0].hasKey("resource")
      check j["resourceProfiles"][0]["scopeProfiles"][0].hasKey("profiles")

    test "timeNanos and durationNanos are JSON strings":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[sampleProfile()]))
      let p = j["resourceProfiles"][0]["scopeProfiles"][0]["profiles"][0]
      check p["timeNanos"].kind == JString
      check p["timeNanos"].getStr() == "1700000000000000000"
      check p["durationNanos"].getStr() == "1000000000"

    test "sample timestampsUnixNano are JSON strings":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[sampleProfile()]))
      let s = j["resourceProfiles"][0]["scopeProfiles"][0]["profiles"][0]["sample"][0]
      check s["timestampsUnixNano"][0].kind == JString
      check s["timestampsUnixNano"][0].getStr() == "1700000000000000000"

    test "sampleType and stringTable present in JSON":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[sampleProfile()]))
      let p = j["resourceProfiles"][0]["scopeProfiles"][0]["profiles"][0]
      check p["sampleType"].len == 1
      # proto3-JSON: int64 fields are strings, not numbers.
      check p["sampleType"][0]["type"].kind == JString
      check p["sampleType"][0]["type"].getStr() == "1"
      check p["stringTable"].len == 7

else:
  suite "Profiles (skipped — no -d:observyProfiles)":
    test "skipped: compile with -d:observyProfiles to exercise profiles":
      skip()
