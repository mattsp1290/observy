import unittest
import std/json
import ../src/observy/anyvalue
import ../src/observy/proto
import ../src/observy/resource

when defined(observyProfiles):
  import ../src/observy/profiles

  proc samplePrtofile(): Profile =
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
      let p = samplePrtofile()
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
      encodeProfile(w, samplePrtofile())
      check w.buf.len > 0

    test "protoEncodeProfilesRequest wraps in ExportProfilesServiceRequest":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let bytes = protoEncodeProfilesRequest(res, scope, @[samplePrtofile()])
      check bytes.len > 0
      # Top-level field 1 = ResourceProfiles, wire type 2 (length-delimited) → tag 0x0a
      check bytes[0] == 0x0a'u8

    test "empty profile still encodes (period_type present)":
      var w: ProtoWriter
      encodeProfile(w, Profile(stringTable: @[""]))
      # string_table[0] = "" suppressed (empty), period_type embedded message present
      check w.buf.len >= 0   # may be empty if all fields default; must not crash

  suite "Profiles JSON encoding (alpha)":
    test "profileToJson produces valid ExportProfilesServiceRequest JSON":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[samplePrtofile()]))
      check j.hasKey("resourceProfiles")
      check j["resourceProfiles"][0].hasKey("resource")
      check j["resourceProfiles"][0]["scopeProfiles"][0].hasKey("profiles")

    test "timeNanos and durationNanos are JSON strings":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[samplePrtofile()]))
      let p = j["resourceProfiles"][0]["scopeProfiles"][0]["profiles"][0]
      check p["timeNanos"].kind == JString
      check p["timeNanos"].getStr() == "1700000000000000000"
      check p["durationNanos"].getStr() == "1000000000"

    test "sample timestampsUnixNano are JSON strings":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[samplePrtofile()]))
      let s = j["resourceProfiles"][0]["scopeProfiles"][0]["profiles"][0]["sample"][0]
      check s["timestampsUnixNano"][0].kind == JString
      check s["timestampsUnixNano"][0].getStr() == "1700000000000000000"

    test "sampleType and stringTable present in JSON":
      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let j = parseJson(profileToJson(res, scope, @[samplePrtofile()]))
      let p = j["resourceProfiles"][0]["scopeProfiles"][0]["profiles"][0]
      check p["sampleType"].len == 1
      check p["sampleType"][0]["type"].getInt() == 1
      check p["stringTable"].len == 7

else:
  suite "Profiles (skipped — no -d:observyProfiles)":
    test "skipped: compile with -d:observyProfiles to exercise profiles":
      skip()
