# Profiles signal data model (alpha).
# Gate ALL code behind -d:observyProfiles — this signal is experimental and
# the proto path (/v1development/profiles) is not stable.
when defined(observyProfiles):
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
  #               function=5, string_table=6, ...

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
      stringTable*:       seq[string]
      dropFrames*:        int64
      keepFrames*:        int64
      timeNanos*:         int64
      durationNanos*:     int64
      period*:            int64
      periodType*:        ValueType
      comment*:           seq[int64]
      defaultSampleType*: int64
