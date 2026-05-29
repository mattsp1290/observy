# Profiles signal data model, proto encoding, and JSON encoding (alpha).
# Gate ALL code behind -d:observyProfiles — this signal is experimental and
# the proto path (/v1development/profiles) is not stable.
#
# SCHEMA PINNING: this encoder targets the opentelemetry-proto profiles ALPHA
# schema as described in beads observy-45b/w7a, which nests
#   ExportProfilesServiceRequest > ResourceProfiles > ScopeProfiles >
#   ProfileContainer{profile}. Newer proto revisions have reshaped this (the
#   ProfileContainer wrapper was removed at one point). Because the signal is
#   alpha and unstable, treat this as best-effort and re-verify against the
#   collector's pinned proto before relying on it in production.
#
# JSON COVERAGE: profileToJson emits a documented SUBSET (sampleType, sample,
# stringTable, timeNanos, durationNanos) sufficient for the alpha smoke path.
# The proto encoder (encodeProfile) emits the full message. This asymmetry is
# intentional for alpha; bring JSON to parity before GA.
when defined(observyProfiles):
  import ./proto
  import ./resource
  import ./json_encode

  # opentelemetry-proto profile alpha field numbers
  # profiles/v1development/profiles.proto
  #   ValueType:  type=1, unit=2
  #   Label:      key=1, str=2, num=3, numUnit=4
  #   Mapping:    id=1, memory_start=2, memory_limit=3, file_offset=4,
  #               filename=5, build_id=6, has_functions=7, has_filenames=8,
  #               has_line_numbers=9, has_inline_frames=10
  #   Function:   id=1, name=2, system_name=3, filename=4, start_line=5
  #   Line:       function_id=1, line=2, column=3
  #   Location:   id=1, mapping_id=2, address=3, lines=4, is_folded=5
  #   Sample:     location_index=1, value=2, label=3, attributes=4,
  #               link=5, timestamps_unix_nano=6
  #   Profile:    sample_type=1, sample=2, mapping=3, location=4,
  #               function=5, string_table=6, drop_frames=7, keep_frames=8,
  #               time_nanos=9, duration_nanos=10, period=11, period_type=12,
  #               comment=13, default_sample_type=14
  #
  # ExportProfilesServiceRequest > ResourceProfiles (field 1) >
  #   ScopeProfiles (field 2) > ProfileContainer (field 2)
  #   profile = field 1 in ProfileContainer
  #   ResourceProfiles: resource=1, scope_profiles=2
  #   ScopeProfiles:    scope=1, profiles=2

  type
    ValueType* = object
      typ*: int64   ## proto field: type (renamed to avoid Nim keyword)
      unit*: int64

    Label* = object
      key*:     int64
      str*:     int64
      num*:     int64
      numUnit*: int64

    Mapping* = object
      id*:              uint64
      memoryStart*:     uint64
      memoryLimit*:     uint64
      fileOffset*:      uint64
      filename*:        int64
      buildId*:         int64
      hasFunctions*:    bool
      hasFilenames*:    bool
      hasLineNumbers*:  bool
      hasInlineFrames*: bool

    Function* = object
      id*:         uint64
      name*:       int64
      systemName*: int64
      filename*:   int64
      startLine*:  int64

    Line* = object
      functionId*: uint64
      line*:       int64
      column*:     int64

    Location* = object
      id*:        uint64
      mappingId*: uint64
      address*:   uint64
      lines*:     seq[Line]
      isFolded*:  bool

    Sample* = object
      locationIndex*:      seq[uint64]
      value*:              seq[int64]
      label*:              seq[Label]
      attributes*:         seq[uint32]
      link*:               uint64
      timestampsUnixNano*: seq[uint64]

    Profile* = object
      sampleType*:        seq[ValueType]
      sample*:            seq[Sample]
      mapping*:           seq[Mapping]
      location*:          seq[Location]
      function*:          seq[Function]
      ## Per the profiles spec, stringTable[0] MUST be the empty string ""; all
      ## other string fields are int64 indices into this table. Callers are
      ## responsible for this convention (not enforced here).
      stringTable*:       seq[string]
      dropFrames*:        int64
      keepFrames*:        int64
      timeNanos*:         int64
      durationNanos*:     int64
      period*:            int64
      periodType*:        ValueType
      comment*:           seq[int64]
      defaultSampleType*: int64

  # ---------------------------------------------------------------------------
  # Proto encoding
  # ---------------------------------------------------------------------------

  proc encodeValueType(w: var ProtoWriter; vt: ValueType) =
    w.writeInt64(1, vt.typ)
    w.writeInt64(2, vt.unit)

  proc encodeLabel(w: var ProtoWriter; l: Label) =
    w.writeInt64(1, l.key)
    w.writeInt64(2, l.str)
    w.writeInt64(3, l.num)
    w.writeInt64(4, l.numUnit)

  proc encodeLine(w: var ProtoWriter; ln: Line) =
    w.writeUint64(1, ln.functionId)
    w.writeInt64(2, ln.line)
    w.writeInt64(3, ln.column)

  proc encodeLocation(w: var ProtoWriter; loc: Location) =
    w.writeUint64(1, loc.id)
    w.writeUint64(2, loc.mappingId)
    w.writeUint64(3, loc.address)
    for ln in loc.lines:
      var lw: ProtoWriter
      encodeLine(lw, ln)
      w.writeEmbedded(4, lw)
    if loc.isFolded: w.writeBool(5, loc.isFolded)

  proc encodeMapping(w: var ProtoWriter; m: Mapping) =
    w.writeUint64(1, m.id)
    w.writeUint64(2, m.memoryStart)
    w.writeUint64(3, m.memoryLimit)
    w.writeUint64(4, m.fileOffset)
    w.writeInt64(5, m.filename)
    w.writeInt64(6, m.buildId)
    if m.hasFunctions:    w.writeBool(7, m.hasFunctions)
    if m.hasFilenames:    w.writeBool(8, m.hasFilenames)
    if m.hasLineNumbers:  w.writeBool(9, m.hasLineNumbers)
    if m.hasInlineFrames: w.writeBool(10, m.hasInlineFrames)

  proc encodeFunction(w: var ProtoWriter; f: Function) =
    w.writeUint64(1, f.id)
    w.writeInt64(2, f.name)
    w.writeInt64(3, f.systemName)
    w.writeInt64(4, f.filename)
    w.writeInt64(5, f.startLine)

  proc encodeSample(w: var ProtoWriter; s: Sample) =
    # Repeated scalar fields use PACKED encoding. A per-element loop with the
    # zero-suppressing writeUint64/writeInt64/writeUint32 would silently drop any
    # zero-valued element (e.g. locationIndex 0 is a valid location-table index),
    # corrupting array length. Packed writers emit every element verbatim.
    w.writePackedUint64(1, s.locationIndex)
    w.writePackedInt64(2, s.value)
    for l in s.label:
      var lw: ProtoWriter
      encodeLabel(lw, l)
      w.writeEmbedded(3, lw)
    w.writePackedUint32(4, s.attributes)
    w.writeUint64(5, s.link)
    w.writePackedUint64(6, s.timestampsUnixNano)

  proc encodeProfile*(w: var ProtoWriter; p: Profile) =
    ## Encode a Profile message per the opentelemetry-proto-profile alpha schema.
    for vt in p.sampleType:
      var vtW: ProtoWriter; encodeValueType(vtW, vt); w.writeEmbedded(1, vtW)
    for s in p.sample:
      var sw: ProtoWriter; encodeSample(sw, s); w.writeEmbedded(2, sw)
    for m in p.mapping:
      var mw: ProtoWriter; encodeMapping(mw, m); w.writeEmbedded(3, mw)
    for loc in p.location:
      var lw: ProtoWriter; encodeLocation(lw, loc); w.writeEmbedded(4, lw)
    for f in p.function:
      var fw: ProtoWriter; encodeFunction(fw, f); w.writeEmbedded(5, fw)
    for s in p.stringTable:
      w.writeString(6, s)
    w.writeInt64(7, p.dropFrames)
    w.writeInt64(8, p.keepFrames)
    w.writeInt64(9, p.timeNanos)
    w.writeInt64(10, p.durationNanos)
    w.writeInt64(11, p.period)
    var ptW: ProtoWriter; encodeValueType(ptW, p.periodType); w.writeEmbedded(12, ptW)
    w.writePackedInt64(13, p.comment)   # packed: don't drop zero-valued string-table indices
    w.writeInt64(14, p.defaultSampleType)

  proc protoEncodeProfilesRequest*(res: Resource; scope: InstrumentationScope;
                                    profiles: seq[Profile]): seq[byte] =
    ## Encode as ExportProfilesServiceRequest proto. HTTP path: /v1development/profiles.
    ## Nesting: ExportProfilesServiceRequest{1=ResourceProfiles{1=resource,
    ## 2=ScopeProfiles{1=scope, 2=ProfileContainer{1=profile}}}}.
    var scopeProfiles: ProtoWriter
    scopeProfiles.writeBytes(1, protoEncode(scope))   # scope (empty → omitted)
    for p in profiles:
      var pw: ProtoWriter
      encodeProfile(pw, p)
      var container: ProtoWriter
      container.writeEmbedded(1, pw)
      scopeProfiles.writeEmbedded(2, container)       # ProfileContainer
    var resProfiles: ProtoWriter
    resProfiles.writeBytes(1, protoEncode(res))        # resource (empty → omitted)
    resProfiles.writeEmbedded(2, scopeProfiles)
    var req: ProtoWriter
    req.writeEmbedded(1, resProfiles)
    req.buf

  # ---------------------------------------------------------------------------
  # JSON encoding
  # ---------------------------------------------------------------------------

  # proto3-JSON: int64/uint64 fields serialize as strings (the codebase's
  # jsonEncodeInt64/jsonEncodeUint64 helpers quote them). All ValueType/Label
  # fields and Sample.locationIndex are 64-bit, so they are stringified.
  proc jsonEncodeValueType(vt: ValueType): string =
    "{\"type\":" & jsonEncodeInt64(vt.typ) & ",\"unit\":" & jsonEncodeInt64(vt.unit) & "}"

  proc jsonEncodeLabel(l: Label): string =
    result = "{\"key\":" & jsonEncodeInt64(l.key)
    if l.str  != 0: result.add(",\"str\":"     & jsonEncodeInt64(l.str))
    if l.num  != 0: result.add(",\"num\":"     & jsonEncodeInt64(l.num))
    if l.numUnit != 0: result.add(",\"numUnit\":" & jsonEncodeInt64(l.numUnit))
    result.add("}")

  proc jsonEncodeSample(s: Sample): string =
    result = "{\"locationIndex\":["
    for i, idx in s.locationIndex:
      if i > 0: result.add(",")
      result.add(jsonEncodeUint64(idx))
    result.add("],\"value\":[")
    for i, v in s.value:
      if i > 0: result.add(",")
      result.add(jsonEncodeInt64(v))
    result.add("]")
    if s.label.len > 0:
      result.add(",\"label\":[")
      for i, l in s.label:
        if i > 0: result.add(",")
        result.add(jsonEncodeLabel(l))
      result.add("]")
    if s.timestampsUnixNano.len > 0:
      result.add(",\"timestampsUnixNano\":[")
      for i, ts in s.timestampsUnixNano:
        if i > 0: result.add(",")
        result.add("\"" & $ts & "\"")   # int64 nanos as string per OTLP JSON
      result.add("]")
    result.add("}")

  proc profileToJson*(res: Resource; scope: InstrumentationScope;
                       profiles: seq[Profile]): string =
    ## Encode profiles as ExportProfilesServiceRequest JSON body.
    var profilesArr = "["
    for i, p in profiles:
      if i > 0: profilesArr.add(",")
      var obj = "{\"sampleType\":["
      for j, vt in p.sampleType:
        if j > 0: obj.add(",")
        obj.add(jsonEncodeValueType(vt))
      obj.add("],\"sample\":[")
      for j, s in p.sample:
        if j > 0: obj.add(",")
        obj.add(jsonEncodeSample(s))
      obj.add("],\"stringTable\":[")
      for j, st in p.stringTable:
        if j > 0: obj.add(",")
        obj.add(jsonEscape(st))
      obj.add("]")
      if p.timeNanos != 0:
        obj.add(",\"timeNanos\":\"" & $p.timeNanos & "\"")
      if p.durationNanos != 0:
        obj.add(",\"durationNanos\":\"" & $p.durationNanos & "\"")
      obj.add("}")
      profilesArr.add(obj)
    profilesArr.add("]")
    let scopeProfiles = "{\"scope\":" & jsonEncode(scope) &
                        ",\"profiles\":" & profilesArr & "}"
    let resProfiles = "{\"resource\":" & jsonEncode(res) &
                      ",\"scopeProfiles\":[" & scopeProfiles & "]}"
    "{\"resourceProfiles\":[" & resProfiles & "]}"
