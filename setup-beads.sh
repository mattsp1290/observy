#!/bin/bash
# Project: observy
# Generated: 2026-05-28 (rev 2 — post dual-Opus review)
# OTLP exporter library for Nim — traces, metrics, logs, profiles

set -e

if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating observy task graph..."

# ========================================
# Phase 1: Setup & Infrastructure
# ========================================

SETUP_NIMBLE=$(bd create "Initialize Nimble package and repo structure" \
  -d "Create observy.nimble with name='observy', version='0.1.0', author, description, license='MIT', srcDir='src', backend='c'. Create src/observy/, tests/, examples/, tools/, tests/fixtures/proto/, tests/fixtures/json/, collector-output/ directories. Add .gitignore for *.o, *.a, nimcache/, nimbledeps/, collector-output/*.json. Add collector-output/.gitkeep. Done when: nimble check passes and directory tree matches spec." \
  -p 0 -l setup --silent)

SETUP_COMPILER_FLAGS=$(bd create "Add config.nims documenting required compiler flags" \
  -d "File: config.nims in repo root. Add: switch('mm', 'orc'); switch('threads', 'on'). Also add to README and observy.nimble's 'requires' section a note that consumers must compile with --mm:orc --threads:on. This is a library — we cannot force consumer flags, only document them. Done when: config.nims exists, compiles a trivial Nim file correctly, and README documents the requirement." \
  -p 1 -l setup --silent)
bd dep add $SETUP_COMPILER_FLAGS $SETUP_NIMBLE

SETUP_CI=$(bd create "Configure GitHub Actions CI" \
  -d "File: .github/workflows/ci.yml. Steps: (1) checkout; (2) install Nim via choosenim (latest stable); (3) run 'nimble test' with --mm:orc --threads:on for unit suite; (4) 'docker compose up -d'; (5) poll http://localhost:13133/ every 2s up to 30s until 200 before running integration suite; (6) run integration tests; (7) 'docker compose down -v'. Use ubuntu-latest runner. Done when: a push to main triggers the workflow with all steps succeeding." \
  -p 1 -l setup --silent)
bd dep add $SETUP_CI $SETUP_NIMBLE

SETUP_DOCKER=$(bd create "Create docker-compose.yml and collector-config.yml" \
  -d "docker-compose.yml: service 'otelcol' using image otel/opentelemetry-collector-contrib (NOT otel/opentelemetry-collector). Bind-mounts: ./collector-config.yml:/etc/otelcol-contrib/config.yaml:ro and ./collector-output:/collector-output. Expose ports 4317 (grpc), 4318 (http), 13133 (health-check). collector-config.yml: receivers: otlp (protocols: grpc port 4317, http port 4318); processors: batch; exporters: logging (verbosity: detailed) + file (path: /collector-output/signals.json, rotation: false); extensions: health_check (endpoint: 0.0.0.0:13133); service: pipelines: traces/metrics/logs use all three. Done when: docker compose up -d starts and curl localhost:13133 returns HTTP 200." \
  -p 0 -l setup --silent)
bd dep add $SETUP_DOCKER $SETUP_NIMBLE

SETUP_DIRS=$(bd create "Scaffold src/observy module stub files" \
  -d "Create minimal compilable stubs: src/observy.nim (umbrella, just a comment), src/observy/proto.nim, src/observy/anyvalue.nim, src/observy/resource.nim, src/observy/traces.nim, src/observy/metrics.nim, src/observy/logs.nim, src/observy/profiles.nim, src/observy/exporter_http.nim, src/observy/batch.nim, src/observy/config.nim. Each stub: one-line module comment only. Done when: 'nim c --mm:orc --threads:on src/observy.nim' compiles with no errors." \
  -p 0 -l setup --silent)
bd dep add $SETUP_DIRS $SETUP_NIMBLE

# ========================================
# Phase 2: Proto3 Wire-Format Encoder
# ========================================

PROTO_CORE=$(bd create "Implement proto3 wire-format encoder in pure Nim" \
  -d "File: src/observy/proto.nim. Implement ALL of: (1) varint encode/decode (base-128, MSB continuation bit); (2) zigzag encode/decode ONLY for sint32/sint64 — NOT int32/int64 which use plain varint; (3) fixed32 (wire type 5, little-endian uint32/float); (4) fixed64 (wire type 1, little-endian uint64/double); (5) length-delimited fields (wire type 2 — strings, bytes, embedded messages, packed repeated); (6) packed repeated numeric fields (wire type 2); (7) embedded message length-prefix framing. Field tag encoding: (field_number shl 3) or wire_type. CANONICAL ENCODING RULE: fields MUST be written in ascending field-number order. Proto3 default-valued scalars (0, 0.0, false, empty string, empty bytes) and empty repeated fields MUST be omitted. Public API: ProtoWriter = object(buf: seq[byte]) with write* procs; ProtoReader = object(data: seq[byte]; pos: int) with read* procs. No Nimble deps. Done when: testament tests pass for all wire types including varint edge cases (0, 1, 127, 128, 2^63-1, max uint64, negative sint64 zigzag)." \
  -p 0 -l core --silent)
bd dep add $PROTO_CORE $SETUP_DIRS

PROTO_GOLDEN_FIXTURES=$(bd create "Generate golden-byte proto3 fixtures from reference SDK" \
  -d "Write tools/gen_fixtures.py using the Python OTel SDK (opentelemetry-sdk, opentelemetry-exporter-otlp-proto-grpc). Generate binary fixture files in tests/fixtures/proto/: minimal_span.bin (required fields only), full_span.bin (all fields populated including events, links, attributes), counter_metric.bin (Sum, cumulative, one NumberDataPoint), histogram_metric.bin (one HistogramDataPoint with explicit bounds), exp_histogram_metric.bin (one ExponentialHistogramDataPoint with scale, positive/negative buckets), summary_metric.bin (one SummaryDataPoint), log_record.bin (all LogRecord fields). Commit all .bin files. Include a requirements.txt next to the generator. Done when: python tools/gen_fixtures.py runs and produces all .bin files with non-zero sizes matching expected field structure." \
  -p 0 -l testing --silent)
bd dep add $PROTO_GOLDEN_FIXTURES $PROTO_CORE

PROTO_TESTS=$(bd create "Write testament golden-byte tests for proto encoder" \
  -d "File: tests/test_proto.nim. CORRECT TEST METHODOLOGY: for each fixture, (1) CONSTRUCT a Nim model value with the same field values used in the fixture generator, (2) ENCODE it with ProtoWriter, (3) COMPARE the output bytes against the .bin fixture byte-for-byte. Do NOT decode the fixture then reencode — that tests mutual consistency, not correctness against the spec. Additionally, unit-test each encoding primitive in isolation: varint (0, 127, 128, 300, 2^63-1, -1 as uint64), zigzag (sint32/sint64 positive and negative), fixed32/fixed64, packed-repeated, embedded message framing. Done when: testament tests/test_proto.nim passes with all golden fixtures matching byte-for-byte." \
  -p 0 -l testing --silent)
bd dep add $PROTO_TESTS $PROTO_GOLDEN_FIXTURES

# ========================================
# Phase 3: Common OTel Data Model
# ========================================

MODEL_ANYVALUE=$(bd create "Implement AnyValue, KeyValue types and attribute limits" \
  -d "File: src/observy/anyvalue.nim. AnyValue MUST be a Nim variant object: 'AnyValue = object; case kind: AnyValueKind; of avString: strVal: string; of avBool: boolVal: bool; of avInt: intVal: int64; of avDouble: dblVal: float64; of avBytes: bytesVal: seq[byte]; of avArray: arrayVal: seq[AnyValue]; of avKvList: kvlistVal: seq[KeyValue]'. AnyValueKind is the discriminator enum. KeyValue = object(key: string; value: AnyValue). AttributeSet = object(pairs: seq[KeyValue]; maxCount: int; maxValueLen: int) with proc add(a: var AttributeSet; k: string; v: AnyValue) that: (1) silently drops if pairs.len >= maxCount; (2) truncates string values to maxValueLen bytes (UTF-8 safe). Constants: DEFAULT_MAX_ATTRIBUTES = 128; DEFAULT_MAX_VALUE_LEN = 4096. Done when: testament tests pass for all 7 AnyValue kinds, truncation, and count-limit enforcement." \
  -p 0 -l core --silent)
bd dep add $MODEL_ANYVALUE $PROTO_CORE

MODEL_ANYVALUE_TESTS=$(bd create "Write tests for AnyValue, KeyValue, and attribute limits" \
  -d "File: tests/test_anyvalue.nim. Test: all 7 AnyValue variant kinds; nested array and kvlist; AttributeSet.add truncates string to maxValueLen; add silently drops beyond maxCount; KeyValue proto encode/decode round-trip (construct → encode → decode → compare). Edge values: empty string, empty bytes, zero int64, -1 int64, NaN double, max float64. Done when: testament passes all cases." \
  -p 1 -l testing --silent)
bd dep add $MODEL_ANYVALUE_TESTS $MODEL_ANYVALUE

MODEL_RESOURCE=$(bd create "Implement Resource and InstrumentationScope types" \
  -d "File: src/observy/resource.nim. Resource = object(attributes: AttributeSet; droppedAttributesCount: int). InstrumentationScope = object(name: string; version: string; attributes: AttributeSet; droppedAttributesCount: int). Proto encode procs using ProtoWriter (field numbers from opentelemetry-proto v1.10.0 common/v1/common.proto and resource/v1/resource.proto). JSON encode procs: attributes as [{key, value: {stringValue/...}}] array; int64 fields as JSON strings. Done when: testament round-trip tests for both types against hand-crafted expected proto bytes pass." \
  -p 0 -l core --silent)
bd dep add $MODEL_RESOURCE $MODEL_ANYVALUE

# ========================================
# Phase 4: OTLP JSON Encoding Layer
# ========================================

JSON_CORE=$(bd create "Implement OTLP-compliant JSON encoder utilities" \
  -d "File: src/observy/json_encode.nim. Implement helper procs: (1) hexEncodeTraceId(id: array[16,byte]) -> string — lowercase hex, 32 chars, NO base64; (2) hexEncodeSpanId(id: array[8,byte]) -> string — lowercase hex, 16 chars; (3) base64Encode(data: seq[byte]) -> string — RFC 4648 standard encoding, no line breaks, for non-ID bytes fields; (4) jsonEncodeInt64(v: int64) -> string — returns a JSON string (quoted), NOT a number; (5) jsonEncodeUint64(v: uint64) -> string — same, quoted; (6) jsonEncodeAnyValue(v: AnyValue) -> string; (7) jsonEncodeKVList(pairs: seq[KeyValue]) -> string. These rules differ from standard proto3 JSON and MUST be tested with golden files. All pure Nim, no stdlib JSON module needed. Done when: golden-file tests pass for all rules." \
  -p 0 -l core --silent)
bd dep add $JSON_CORE $MODEL_RESOURCE

JSON_GOLDEN_FIXTURES=$(bd create "Create golden-file JSON fixtures for OTLP JSON encoding" \
  -d "Write golden .json files in tests/fixtures/json/ using the Python OTel SDK (same generator script as proto fixtures). Required fixtures: trace_id_hex.json — traceId must be a 32-char lowercase hex string like '4bf92f3577b34da6a3ce929d0e0e4736' (NOT base64); span_id_hex.json — spanId is a 16-char hex string; bytes_base64.json — a bytes attribute value is base64-encoded; int64_string.json — startTimeUnixNano field is a JSON string e.g. '1000000000000000000' not a number 1000000000000000000; full_span.json — complete span with all fields exercising all rules simultaneously. Done when: all fixture files committed and each fixture file's key field has the correct encoding type." \
  -p 0 -l testing --silent)
bd dep add $JSON_GOLDEN_FIXTURES $JSON_CORE

JSON_GOLDEN_TESTS=$(bd create "Write testament golden-file JSON encoding tests" \
  -d "File: tests/test_json_encode.nim. For each fixture: construct the Nim model, call the JSON encode proc, parse the output JSON, assert the specific field value matches the golden fixture. Tests must explicitly assert: traceId is a string of length 32 containing only [0-9a-f]; spanId length 16 same; a bytes attribute value is valid base64; startTimeUnixNano is a JSON string not a JSON number; AnyValue of each kind serialises to the correct proto JSON field name (stringValue, boolValue, intValue, doubleValue, bytesValue, arrayValue, kvlistValue). Done when: testament passes all JSON golden tests." \
  -p 0 -l testing --silent)
bd dep add $JSON_GOLDEN_TESTS $JSON_GOLDEN_FIXTURES

# ========================================
# Phase 5: Traces Signal
# ========================================

TRACES_MODEL=$(bd create "Implement Traces data model types" \
  -d "File: src/observy/traces.nim. Types: TraceId = array[16, byte]; SpanId = array[8, byte]; TraceFlags = uint8. SpanKind = enum(UNSPECIFIED=0, INTERNAL=1, SERVER=2, CLIENT=3, PRODUCER=4, CONSUMER=5). StatusCode = enum(UNSET=0, OK=1, ERROR=2). SpanStatus = object(code: StatusCode; message: string). SpanEvent = object(timeUnixNano: uint64; name: string; attributes: AttributeSet; droppedAttributesCount: int). SpanLink = object(traceId: TraceId; spanId: SpanId; traceState: string; attributes: AttributeSet; droppedAttributesCount: int; flags: uint32). Span = object(traceId: TraceId; spanId: SpanId; parentSpanId: SpanId; traceState: string; name: string; kind: SpanKind; startTimeUnixNano: uint64; endTimeUnixNano: uint64; attributes: AttributeSet; droppedAttributesCount: int; events: seq[SpanEvent]; droppedEventsCount: int; links: seq[SpanLink]; droppedLinksCount: int; status: SpanStatus; flags: uint32). Done when: Span compiles with --mm:orc --threads:on and can be fully constructed." \
  -p 0 -l feature-traces --silent)
bd dep add $TRACES_MODEL $MODEL_RESOURCE

TRACES_PROTO=$(bd create "Implement proto encoding for Traces signal" \
  -d "In src/observy/traces.nim: encodeSpan(w: var ProtoWriter; s: Span), encodeSpanEvent, encodeSpanLink, encodeSpanStatus. Field numbers from opentelemetry-proto v1.10.0 opentelemetry/proto/trace/v1/trace.proto. Nesting: ExportTraceServiceRequest > ResourceSpans > ScopeSpans > Span. CANONICAL ENCODING: ascending field-number order, omit proto3 defaults. traceId/spanId/parentSpanId encoded as raw bytes (wire type 2, length 16/8). traceState is string (length-delimited). Done when: 'nim c -r' test constructs the same Span used in the Python fixture generator and encodes it; the output bytes match tests/fixtures/proto/full_span.bin byte-for-byte." \
  -p 0 -l feature-traces --silent)
bd dep add $TRACES_PROTO $TRACES_MODEL
bd dep add $TRACES_PROTO $PROTO_TESTS

TRACES_JSON=$(bd create "Implement JSON encoding for Traces signal" \
  -d "In src/observy/traces.nim: spanToJson(resource: Resource; scope: InstrumentationScope; spans: seq[Span]) -> string. Output format: ExportTraceServiceRequest JSON structure with resourceSpans array. Use JSON_CORE helpers: hex trace/span IDs, base64 non-ID bytes, string uint64 nanos. Also implement decodeExportTraceServiceResponse(body: string; contentType: string) -> PartialSuccess where PartialSuccess = object(rejectedSpans: int64; errorMessage: string). For contentType 'application/json' parse JSON; for 'application/x-protobuf' delegate to proto response decoder. Done when: JSON golden fixture tests/fixtures/json/full_span.json matches output." \
  -p 0 -l feature-traces --silent)
bd dep add $TRACES_JSON $TRACES_MODEL
bd dep add $TRACES_JSON $JSON_GOLDEN_TESTS

TRACES_TESTS=$(bd create "Write traces signal unit tests" \
  -d "File: tests/test_traces.nim. Test: Span construction with all optional fields omitted (minimal); Span with all fields populated; proto encoding matches golden full_span.bin; JSON output traceId is 32-char hex; JSON output spanId is 16-char hex; SpanEvent proto encoding; SpanLink proto encoding with traceState; SpanStatus ERROR with message; attribute limit enforcement (add 130 attributes, assert only 128 in encoded output); droppedAttributesCount incremented correctly. Done when: testament passes all tests with --mm:orc --threads:on." \
  -p 1 -l testing --silent)
bd dep add $TRACES_TESTS $TRACES_PROTO
bd dep add $TRACES_TESTS $TRACES_JSON

# ========================================
# Phase 6: Metrics Signal
# ========================================

METRICS_MODEL=$(bd create "Implement Metrics data model with correct per-type structure" \
  -d "File: src/observy/metrics.nim. NOTE: the OTel proto has 5 wire data types (not 6 SDK instruments); Counter/ObservableCounter map to Sum(monotonic=true), UpDownCounter/ObservableUpDownCounter to Sum(monotonic=false), Gauge/ObservableGauge to Gauge. AggregationTemporality = enum(UNSPECIFIED=0, DELTA=1, CUMULATIVE=2). Exemplar = object(filteredAttributes: seq[KeyValue]; timeUnixNano: uint64; value: float64; spanId: SpanId; traceId: TraceId). NumberDataPoint = object(attributes: seq[KeyValue]; startTimeUnixNano,timeUnixNano: uint64; value: float64 | int64 (use variant); exemplars: seq[Exemplar]; flags: uint32). HistogramDataPoint = object(attributes,startTime,time,count: ...; sum: float64; bucketCounts: seq[uint64]; explicitBounds: seq[float64]; exemplars: seq[Exemplar]; flags: uint32; min,max: float64). ExponentialHistogramDataPoint = object(attributes,startTime,time,count; sum: float64; scale: int32; zeroCount: uint64; positive,negative: Buckets; flags: uint32; exemplars; min,max: float64; zeroThreshold: float64) where Buckets = object(offset: int32; bucketCounts: seq[uint64]). SummaryDataPoint = object(attributes,startTime,time,count; sum: float64; quantileValues: seq[ValueAtQuantile]; flags: uint32) where ValueAtQuantile = object(quantile,value: float64). MetricSum = object(dataPoints: seq[NumberDataPoint]; aggregationTemporality: AggregationTemporality; isMonotonic: bool). MetricGauge = object(dataPoints: seq[NumberDataPoint]). MetricHistogram = object(dataPoints: seq[HistogramDataPoint]; aggregationTemporality: AggregationTemporality). MetricExpHistogram = object(dataPoints: seq[ExponentialHistogramDataPoint]; aggregationTemporality: AggregationTemporality). MetricSummary = object(dataPoints: seq[SummaryDataPoint]). Metric = object(name,description,unit: string; case kind: MetricKind of mkSum: sum: MetricSum; of mkGauge: gauge: MetricGauge; of mkHistogram: histogram: MetricHistogram; of mkExpHistogram: expHistogram: MetricExpHistogram; of mkSummary: summary: MetricSummary). Done when: all types compile." \
  -p 0 -l feature-metrics --silent)
bd dep add $METRICS_MODEL $MODEL_RESOURCE

METRICS_TEMPORALITY=$(bd create "Implement aggregation temporality selector" \
  -d "In src/observy/metrics.nim: type AggregationTemporalitySelector = proc(kind: MetricKind): AggregationTemporality. IMPORTANT: temporality is only meaningful for mkSum, mkHistogram, mkExpHistogram — NOT mkGauge or mkSummary. The selector proc should return UNSPECIFIED for mkGauge and mkSummary (callers must not override). Provide: proc alwaysCumulative(): AggregationTemporalitySelector and proc alwaysDelta(): AggregationTemporalitySelector. ExporterConfig holds a selector field. The exporter applies the selector when building the request envelope. Done when: tests confirm alwaysDelta sets DELTA on Sum and Histogram, UNSPECIFIED on Gauge, and selector is not applied to Summary data points." \
  -p 1 -l feature-metrics --silent)
bd dep add $METRICS_TEMPORALITY $METRICS_MODEL

METRICS_PROTO=$(bd create "Implement proto encoding for Metrics signal" \
  -d "In src/observy/metrics.nim: per-type encode procs: encodeMetricSum, encodeMetricGauge, encodeMetricHistogram, encodeMetricExpHistogram, encodeMetricSummary; encodeNumberDataPoint, encodeHistogramDataPoint, encodeExpHistogramDataPoint (MUST include scale as sint32 zigzag, zeroCount as uint64 varint, zeroThreshold as double fixed64, Buckets.offset as sint32 zigzag, Buckets.bucketCounts as packed uint64), encodeSummaryDataPoint, encodeExemplar. Top-level: encodeMetric dispatches on kind. Wrap in ExportMetricsServiceRequest > ResourceMetrics > ScopeMetrics > Metric. Field numbers from opentelemetry-proto v1.10.0. CANONICAL ENCODING: ascending field order, omit defaults. Done when: proto golden fixture round-trips for all 5 data-point types byte-for-byte." \
  -p 0 -l feature-metrics --silent)
bd dep add $METRICS_PROTO $METRICS_MODEL
bd dep add $METRICS_PROTO $PROTO_TESTS

METRICS_JSON=$(bd create "Implement JSON encoding for Metrics signal" \
  -d "In src/observy/metrics.nim: metricToJson(resource, scope, metrics) -> string. Handle all 5 metric kinds. For ExponentialHistogramDataPoint: include scale (signed int as string), zeroCount, positive/negative Buckets with offset and bucketCounts. All uint64/int64 nano timestamps as JSON strings. decodeExportMetricsServiceResponse(body, contentType) -> PartialSuccess(rejectedDataPoints: int64, errorMessage: string). Done when: JSON golden fixtures for all 5 metric kinds match output." \
  -p 0 -l feature-metrics --silent)
bd dep add $METRICS_JSON $METRICS_MODEL
bd dep add $METRICS_JSON $JSON_GOLDEN_TESTS

METRICS_TESTS=$(bd create "Write metrics signal unit tests" \
  -d "File: tests/test_metrics.nim. Test: MetricSum with isMonotonic=true (Counter); MetricSum isMonotonic=false (UpDownCounter); MetricGauge; MetricHistogram with 5 buckets and exemplar; MetricExpHistogram with scale=2, zeroCount, positive and negative Buckets; MetricSummary with quantile values; temporality selector: alwaysDelta sets DELTA on Sum/Histogram, Gauge unaffected; proto golden round-trip for each data-point type; JSON encoding: all int64 nanos as strings; exemplar traceId is hex; attribute limits on NumberDataPoint. Done when: testament passes all with --mm:orc --threads:on." \
  -p 1 -l testing --silent)
bd dep add $METRICS_TESTS $METRICS_PROTO
bd dep add $METRICS_TESTS $METRICS_JSON
bd dep add $METRICS_TESTS $METRICS_TEMPORALITY

# ========================================
# Phase 7: Logs Signal
# ========================================

LOGS_MODEL=$(bd create "Implement Logs data model" \
  -d "File: src/observy/logs.nim. SeverityNumber = enum(SEVERITY_NUMBER_UNSPECIFIED=0, TRACE=1..TRACE4=4, DEBUG=5..DEBUG4=8, INFO=9..INFO4=12, WARN=13..WARN4=16, ERROR=17..ERROR4=20, FATAL=21..FATAL4=24). LogRecord = object(timeUnixNano: uint64; observedTimeUnixNano: uint64; severityNumber: SeverityNumber; severityText: string; body: AnyValue; attributes: AttributeSet; droppedAttributesCount: int; flags: uint32; traceId: TraceId; spanId: SpanId). Import TraceId/SpanId from traces.nim. Done when: LogRecord compiles with all spec fields populated." \
  -p 0 -l feature-logs --silent)
bd dep add $LOGS_MODEL $MODEL_RESOURCE

LOGS_PROTO=$(bd create "Implement proto encoding for Logs signal" \
  -d "In src/observy/logs.nim: encodeLogRecord(w: var ProtoWriter; l: LogRecord). Field numbers from opentelemetry-proto v1.10.0 opentelemetry/proto/logs/v1/logs.proto. Nesting: ExportLogsServiceRequest > ResourceLogs > ScopeLogs > LogRecord. traceId/spanId encoded as raw bytes. body encoded as AnyValue message. CANONICAL ENCODING: ascending field order, omit defaults. Also decodeExportLogsServiceResponse(body, contentType) -> PartialSuccess(rejectedLogRecords: int64, errorMessage: string). Done when: proto golden fixture tests/fixtures/proto/log_record.bin matches output byte-for-byte." \
  -p 0 -l feature-logs --silent)
bd dep add $LOGS_PROTO $LOGS_MODEL
bd dep add $LOGS_PROTO $PROTO_TESTS

LOGS_JSON=$(bd create "Implement JSON encoding for Logs signal" \
  -d "In src/observy/logs.nim: logRecordToJson(resource, scope, records) -> string. Hex traceId (32 chars), hex spanId (16 chars), base64 non-ID bytes attributes, all uint64 nano timestamps as JSON strings, body serialised as AnyValue JSON object. Done when: JSON golden fixtures match output and traceId appears as 32-char lowercase hex." \
  -p 0 -l feature-logs --silent)
bd dep add $LOGS_JSON $LOGS_MODEL
bd dep add $LOGS_JSON $JSON_GOLDEN_TESTS

LOGS_TESTS=$(bd create "Write logs signal unit tests" \
  -d "File: tests/test_logs.nim. Test: LogRecord with all 24 SeverityNumber values; body as each AnyValue kind; proto golden round-trip vs log_record.bin; JSON traceId 32-char hex; JSON spanId 16-char hex; attribute limits on LogRecord; observedTimeUnixNano defaults to 0 (omitted in proto) when not set; flags field encoding. Done when: testament passes all tests." \
  -p 1 -l testing --silent)
bd dep add $LOGS_TESTS $LOGS_PROTO
bd dep add $LOGS_TESTS $LOGS_JSON

# ========================================
# Phase 8: Profiles Signal (alpha)
# ========================================

PROFILES_MODEL=$(bd create "Implement Profiles data model (alpha, -d:observyProfiles)" \
  -d "File: src/observy/profiles.nim. ALL code in this file MUST be inside 'when defined(observyProfiles):'. Types from opentelemetry-proto-profile alpha: ValueType = object(type_: int64; unit: int64). Label = object(key,str,num,numUnit: int64). Mapping = object(id,memoryStart,memoryLimit,fileOffset: uint64; filename,buildId: int64; ...). Function = object(id: uint64; name,systemName,filename: int64; startLine: int64). Line = object(functionId: uint64; line,column: int64). Location = object(id: uint64; mappingId: uint64; address: uint64; lines: seq[Line]; isFolded: bool). Sample = object(locationIndex: seq[uint64]; value: seq[int64]; label: seq[Label]; attributes: seq[uint32]; ...). Profile = object(sampleType: seq[ValueType]; sample: seq[Sample]; mapping: seq[Mapping]; location: seq[Location]; function: seq[Function]; stringTable: seq[string]; ...). HTTP path: /v1development/profiles (NOT /v1/profiles). Done when: compiles with -d:observyProfiles and compiles cleanly (no Profiles types visible) without it." \
  -p 2 -l feature-profiles --silent)
bd dep add $PROFILES_MODEL $MODEL_RESOURCE

PROFILES_PROTO=$(bd create "Implement proto encoding for Profiles signal (alpha)" \
  -d "In src/observy/profiles.nim (inside 'when defined(observyProfiles):'): encodeProfile(w: var ProtoWriter; p: Profile). Field numbers from opentelemetry-proto-profile alpha repo. Nesting: ExportProfilesServiceRequest > ResourceProfiles > ScopeProfiles > ProfileContainer. HTTP POST path: /v1development/profiles. CANONICAL ENCODING. Done when: a Profile with sample data encodes without errors and the output is non-empty binary." \
  -p 2 -l feature-profiles --silent)
bd dep add $PROFILES_PROTO $PROFILES_MODEL
bd dep add $PROFILES_PROTO $PROTO_TESTS

PROFILES_JSON=$(bd create "Implement JSON encoding for Profiles signal (alpha)" \
  -d "In src/observy/profiles.nim (inside 'when defined(observyProfiles):'): profileToJson(resource, scope, profiles) -> string following OTLP JSON spec. int64 timestamps as JSON strings. Done when: a Profile serialises to valid JSON with timestamps as strings and the output is accepted by JSON parse." \
  -p 2 -l feature-profiles --silent)
bd dep add $PROFILES_JSON $PROFILES_MODEL
bd dep add $PROFILES_JSON $JSON_GOLDEN_TESTS

PROFILES_TESTS=$(bd create "Write profiles signal unit tests" \
  -d "File: tests/test_profiles.nim. ALL tests inside 'when defined(observyProfiles):'. Test: Profile construction with samples, locations, functions; proto encoding produces non-empty output; JSON encoding timestamps are strings; compilation WITHOUT -d:observyProfiles produces no errors and no Profile types in scope. Run as: testament --passNim:'-d:observyProfiles'. Done when: testament passes with flag and compiles cleanly without it." \
  -p 2 -l testing --silent)
bd dep add $PROFILES_TESTS $PROFILES_PROTO
bd dep add $PROFILES_TESTS $PROFILES_JSON

# ========================================
# Phase 9: Config & Env-Var Parser
# ========================================

CONFIG_CORE=$(bd create "Implement OTEL_* env-var configuration parser" \
  -d "File: src/observy/config.nim. ExporterConfig = object(endpoint: string; signalEndpoints: array[4, string]; headers: seq[(string,string)]; protocol: OtlpProtocol; serviceName: string; resourceAttributes: seq[(string,string)]; compression: CompressionType; maxRetryElapsed: int). OtlpProtocol = enum(otlpProtoHttp, otlpJsonHttp). CompressionType = enum(compNone, compGzip). Parse env-vars: OTEL_EXPORTER_OTLP_ENDPOINT (base URL — signal paths are APPENDED: base + '/v1/traces', '/v1/metrics', '/v1/logs', '/v1development/profiles'); per-signal OTEL_EXPORTER_OTLP_TRACES_ENDPOINT etc. (used VERBATIM, no path appended — these override the base); OTEL_EXPORTER_OTLP_HEADERS (comma-separated key=value pairs, values may be percent-encoded); OTEL_EXPORTER_OTLP_PROTOCOL ('http/protobuf' or 'http/json'); OTEL_SERVICE_NAME; OTEL_RESOURCE_ATTRIBUTES (comma-separated k=v). Precedence: programmatic field > env-var > default. Default endpoint: 'http://localhost:4318'. Done when: testament tests cover all env-vars, path-append behavior, verbatim signal endpoint, multi-header parsing, and precedence." \
  -p 0 -l core --silent)
bd dep add $CONFIG_CORE $SETUP_DIRS

CONFIG_TESTS=$(bd create "Write tests for OTEL_* env-var config parser" \
  -d "File: tests/test_config.nim. Set env-vars via putenv() before each test, clean up after. Test: base endpoint 'http://localhost:4318' appends '/v1/traces' for traces path; per-signal OTEL_EXPORTER_OTLP_TRACES_ENDPOINT used verbatim without appending; OTEL_EXPORTER_OTLP_HEADERS='k1=v1,k2=v2' produces two header pairs; OTEL_SERVICE_NAME sets service.name; OTEL_RESOURCE_ATTRIBUTES 'k1=v1,k2=v2'; protocol 'http/protobuf' vs 'http/json'; programmatic endpoint overrides env-var; missing env-vars fall back to defaults. Done when: testament passes all config tests." \
  -p 1 -l testing --silent)
bd dep add $CONFIG_TESTS $CONFIG_CORE

# ========================================
# Phase 10: HTTP Exporter
# ========================================

EXPORTER_HTTP_CORE=$(bd create "Implement OTLP/HTTP exporter core" \
  -d "File: src/observy/exporter_http.nim. OtlpHttpExporter = object(config: ExporterConfig; client: HttpClient). Core proc: sendRequest(e: var OtlpHttpExporter; path: string; payload: seq[byte]; contentType: string): HttpCode. Supports both protocols: if config.protocol == otlpProtoHttp send payload as-is with Content-Type 'application/x-protobuf'; if otlpJsonHttp send with 'application/json'. Signal-specific paths from config (base+append or verbatim). Inject all config.headers on every request. TLS: when defined(ssl) Nim stdlib httpclient uses OpenSSL; plaintext needs no external deps. Uses Nim stdlib httpclient (HTTP/1.1 only — gRPC/HTTP2 out of scope). Done when: unit test with local TCP mock asserts correct path, Content-Type header, custom headers injected, and both protocols send correct body bytes." \
  -p 0 -l core --silent)
bd dep add $EXPORTER_HTTP_CORE $CONFIG_CORE
bd dep add $EXPORTER_HTTP_CORE $TRACES_PROTO
bd dep add $EXPORTER_HTTP_CORE $TRACES_JSON
bd dep add $EXPORTER_HTTP_CORE $METRICS_PROTO
bd dep add $EXPORTER_HTTP_CORE $METRICS_JSON
bd dep add $EXPORTER_HTTP_CORE $LOGS_PROTO
bd dep add $EXPORTER_HTTP_CORE $LOGS_JSON

EXPORTER_PROTO_RESPONSE_DECODE=$(bd create "Implement proto response-body decoder for partial-success" \
  -d "File: src/observy/exporter_http.nim (or proto.nim). Implement decodeExportServiceResponseProto(body: seq[byte]) -> PartialSuccess. Parse the ExportTraceServiceResponse / ExportMetricsServiceResponse / ExportLogsServiceResponse protobuf (all three share the same structure: field 1 = partial_success message with fields: rejected_spans/rejected_data_points/rejected_log_records as int64, error_message as string). The partial_success field is field number 1, length-delimited. rejected_* is field 1 (varint int64), error_message is field 2 (string). Use ProtoReader for decode. This is REQUIRED for the default protocol (http/protobuf) — without it, partial rejections on protobuf responses are silently ignored. Done when: test decodes a hand-crafted partial-success protobuf response and asserts correct rejected count and message." \
  -p 0 -l core --silent)
bd dep add $EXPORTER_PROTO_RESPONSE_DECODE $EXPORTER_HTTP_CORE

EXPORTER_RETRY=$(bd create "Implement retry policy with exponential backoff" \
  -d "In src/observy/exporter_http.nim: proc retryWithBackoff(e: var OtlpHttpExporter; path, payload, contentType; config: ExporterConfig): ExportResult. Retry on HTTP 429, 502, 503, 504. Retry-After header: parse both integer-seconds and HTTP-date forms; if present, use as sleep delay (overrides computed backoff). Exponential backoff: initial delay 1s, multiplier 2.0, jitter ±10%, max single delay 30s. Max total elapsed time: config.maxRetryElapsed (default 300s). Non-retryable on all other 4xx (return error immediately). Drop oldest batch with a warning log when queue is full. Done when: tests using a mock HTTP server assert: 503 triggers retry; Retry-After: 5 causes ~5s delay (mock time); 400 returns immediately without retry; elapsed cap stops retries after maxRetryElapsed." \
  -p 0 -l core --silent)
bd dep add $EXPORTER_RETRY $EXPORTER_HTTP_CORE

EXPORTER_PARTIAL=$(bd create "Implement partial-success response handling" \
  -d "In src/observy/exporter_http.nim: on every HTTP 200 response, ALWAYS call parsePartialSuccess(body, contentType) -> PartialSuccess. Route: 'application/json' -> JSON parse (extract partial_success.rejected_spans etc.); 'application/x-protobuf' -> decodeExportServiceResponseProto(body). PartialSuccess = object(rejectedCount: int64; errorMessage: string). If rejectedCount > 0 OR errorMessage != '': emit a warning via a user-configurable warn proc (default: stderr.writeLine). Do NOT silently discard. Return PartialSuccess to caller. Done when: test with mock 200 response containing non-zero rejected_spans emits expected warning message." \
  -p 0 -l core --silent)
bd dep add $EXPORTER_PARTIAL $EXPORTER_HTTP_CORE
bd dep add $EXPORTER_PARTIAL $EXPORTER_PROTO_RESPONSE_DECODE

EXPORTER_GZIP=$(bd create "Implement optional gzip compression (-d:observyGzip)" \
  -d "In src/observy/exporter_http.nim. Gzip requires zlib — gate behind 'when defined(observyGzip):'. Use '{.passL: \"-lz\".}' pragma to link libz (a second system-level dependency, similar to OpenSSL for TLS — document this explicitly in README). proc gzipCompress(data: seq[byte]): seq[byte] using Nim's std/zlib (stdint wrapper around libz). If config.compression == compGzip and defined(observyGzip): compress payload and set Content-Encoding: gzip header. Default: no compression. Document in README: compile with '-d:observyGzip' requires zlib installed (brew install zlib / apt-get install zlib1g-dev). Done when: test compiles with -d:observyGzip, compresses a known payload, decompresses with zlib, asserts roundtrip equality and Content-Encoding header present." \
  -p 1 -l core --silent)
bd dep add $EXPORTER_GZIP $EXPORTER_HTTP_CORE

EXPORTER_TESTS=$(bd create "Write HTTP exporter unit tests" \
  -d "File: tests/test_exporter_http.nim. Use a local TCP test server (spawn with asyncdispatch or threads). Test: protobuf content-type on default protocol; JSON content-type when protocol=otlpJsonHttp; custom headers injected; retry on 503 (mock returns 503 twice then 200); Retry-After delay honored (mock time); no retry on 400 (returns immediately); partial-success warning emitted on 200 with rejected_spans=3; gzip roundtrip (when defined(observyGzip)); proto response decode partial-success. Done when: testament passes all tests without requiring a live collector." \
  -p 1 -l testing --silent)
bd dep add $EXPORTER_TESTS $EXPORTER_RETRY
bd dep add $EXPORTER_TESTS $EXPORTER_PARTIAL
bd dep add $EXPORTER_TESTS $EXPORTER_GZIP

# ========================================
# Phase 11: Batch Processor & Lifecycle
# ========================================

BATCH_CORE=$(bd create "Implement batch processor with channels and Isolated[T]" \
  -d "File: src/observy/batch.nim. Use STDLIB ONLY: 'import std/isolation' for Isolated[T] (NOT the threading nimble package); Channel[T] from the system module (builtin, no import needed) for cross-thread communication. BatchConfig = object(maxSize: int = 512; flushIntervalMs: int = 5000; maxQueueSize: int = 2048). BatchProcessor[T] = object(config: BatchConfig; chan: Channel[Isolated[T]]; thread: Thread[...]; running: bool). Worker thread proc receives items from chan, accumulates a batch, calls exporter when batch reaches maxSize or interval fires. Use Isolated[T] to transfer payload across thread boundary (ORC ownership rule: only one owner at a time). newBatchProcessor[T](exporter, config) spawns the worker thread. Done when: processor accumulates correct batch sizes verified by test counting exporter calls." \
  -p 0 -l core --silent)
bd dep add $BATCH_CORE $EXPORTER_HTTP_CORE

BATCH_LIFECYCLE=$(bd create "Implement forceFlush() and shutdown() on BatchProcessor" \
  -d "In src/observy/batch.nim: proc forceFlush[T](p: var BatchProcessor[T]) — sends a sentinel value through the channel to trigger immediate flush, then blocks until worker confirms flush complete (use a second Channel[bool] as a flush-ack channel). proc shutdown[T](p: var BatchProcessor[T]) — sets p.running=false, closes the input channel, joins the worker thread (blocking until drained). Both are required for correctness in short-lived programs and serverless environments. Done when: test spawns processor, enqueues 10 items, calls shutdown(), asserts all 10 were exported before proc returns." \
  -p 0 -l core --silent)
bd dep add $BATCH_LIFECYCLE $BATCH_CORE

BATCH_TESTS=$(bd create "Write batch processor unit tests" \
  -d "File: tests/test_batch.nim. Compile with --mm:orc --threads:on. Test: (1) batch flushes at maxSize (send maxSize+1 items, assert exporter called at least once mid-way); (2) batch flushes at interval (send 1 item, sleep 2×flushInterval, assert exported); (3) forceFlush() drains all pending before returning; (4) shutdown() stops worker and drains — no items lost; (5) drop-with-warning when queue full: slow consumer + 3000 items with maxQueueSize=100, assert warning emitted; (6) concurrent producers: 4 threads each sending 100 items, assert all 400 exported. Done when: testament passes all with --mm:orc --threads:on." \
  -p 1 -l testing --silent)
bd dep add $BATCH_TESTS $BATCH_LIFECYCLE

# ========================================
# Phase 12: Public API (Umbrella Module)
# ========================================

API_UMBRELLA=$(bd create "Implement public umbrella module src/observy.nim" \
  -d "File: src/observy.nim. Re-export all public types. IMPORTANT: DO NOT name any public proc 'export' — that is a Nim keyword. Use 'record' as the primary emit proc name. Public procs: newOtlpExporter(config: ExporterConfig): OtlpHttpExporter; newBatchProcessor[T](exporter: OtlpHttpExporter; config: BatchConfig): BatchProcessor[T]; forceFlush[T](p: var BatchProcessor[T]); shutdown[T](p: var BatchProcessor[T]). zippy/puppy style: no object hierarchies deeper than 2 levels; value types (object, not ref); small API surface. A user should be able to 'import observy' and use all signals without importing sub-modules. Done when: 'import observy' exposes all needed types and procs and 'nim c --mm:orc --threads:on src/observy.nim' succeeds." \
  -p 0 -l core --silent)
bd dep add $API_UMBRELLA $BATCH_LIFECYCLE
bd dep add $API_UMBRELLA $TRACES_PROTO
bd dep add $API_UMBRELLA $TRACES_JSON
bd dep add $API_UMBRELLA $METRICS_PROTO
bd dep add $API_UMBRELLA $METRICS_JSON
bd dep add $API_UMBRELLA $LOGS_PROTO
bd dep add $API_UMBRELLA $LOGS_JSON
bd dep add $API_UMBRELLA $CONFIG_CORE

API_RECORD_TRACES=$(bd create "Implement record() for traces on BatchProcessor and exporter" \
  -d "In src/observy/traces.nim or src/observy.nim: proc record(p: var BatchProcessor[Span]; span: Span) — isolate span and send to channel. proc record(e: var OtlpHttpExporter; resource: Resource; scope: InstrumentationScope; spans: seq[Span]) — direct synchronous send (no batch). The proc is named 'record' NOT 'export' (Nim keyword). Done when: examples/traces.nim calls record() and compiles with --mm:orc --threads:on." \
  -p 0 -l feature-traces --silent)
bd dep add $API_RECORD_TRACES $API_UMBRELLA

API_RECORD_METRICS=$(bd create "Implement record() for metrics on BatchProcessor and exporter" \
  -d "In src/observy/metrics.nim or src/observy.nim: proc record(p: var BatchProcessor[Metric]; metric: Metric). proc record(e: var OtlpHttpExporter; resource, scope, metrics). Applies temporality selector before encoding. Named 'record' NOT 'export'. Done when: examples/metrics.nim calls record() and compiles." \
  -p 0 -l feature-metrics --silent)
bd dep add $API_RECORD_METRICS $API_UMBRELLA

API_RECORD_LOGS=$(bd create "Implement record() for logs on BatchProcessor and exporter" \
  -d "In src/observy/logs.nim or src/observy.nim: proc record(p: var BatchProcessor[LogRecord]; log: LogRecord). proc record(e: var OtlpHttpExporter; resource, scope, logs). Named 'record' NOT 'export'. Done when: examples/logs.nim calls record() and compiles." \
  -p 0 -l feature-logs --silent)
bd dep add $API_RECORD_LOGS $API_UMBRELLA

API_RECORD_PROFILES=$(bd create "Implement record() for profiles on exporter (alpha)" \
  -d "In src/observy/profiles.nim (inside 'when defined(observyProfiles):'): proc record(e: var OtlpHttpExporter; resource, scope, profiles). No BatchProcessor variant for profiles in v1.0 (alpha). Named 'record' NOT 'export'. Done when: compiles with -d:observyProfiles." \
  -p 2 -l feature-profiles --silent)
bd dep add $API_RECORD_PROFILES $API_UMBRELLA
bd dep add $API_RECORD_PROFILES $PROFILES_JSON

# ========================================
# Phase 13: Examples
# ========================================

EXAMPLES_TRACES=$(bd create "Write examples/traces.nim" \
  -d "File: examples/traces.nim. Self-contained runnable example. Steps: (1) read OTEL_EXPORTER_OTLP_ENDPOINT (default http://localhost:4318) and OTEL_SERVICE_NAME (default 'observy-example') from env; (2) build Resource with service.name; (3) build an InstrumentationScope; (4) create two spans: a server span (SpanKind=SERVER) with one SpanEvent, one SpanLink, Status=OK, 3 string attributes; a child span (SpanKind=INTERNAL) referencing parent; (5) var e = newOtlpExporter(config); (6) record(e, resource, scope, @[parentSpan, childSpan]); (7) forceFlush(e); (8) shutdown(e). Compile instructions in examples/nim.cfg: --mm:orc --threads:on. Done when: 'nim c -r examples/traces.nim' with collector running shows 2 spans in 'docker compose logs otelcol'." \
  -p 1 -l docs --silent)
bd dep add $EXAMPLES_TRACES $API_RECORD_TRACES
bd dep add $EXAMPLES_TRACES $SETUP_DOCKER

EXAMPLES_METRICS=$(bd create "Write examples/metrics.nim" \
  -d "File: examples/metrics.nim. Demonstrate all 5 metric wire types: (1) MetricSum(isMonotonic=true) — http.requests.total counter with 3 data points at different times; (2) MetricGauge — system.memory.used gauge; (3) MetricHistogram — http.request.duration with 5 buckets (0.005, 0.01, 0.025, 0.05, 0.1); (4) MetricExpHistogram with scale=2; (5) MetricSummary. Use alwaysCumulative() selector. record(e, resource, scope, metrics); forceFlush(e); shutdown(e). Done when: 'nim c -r examples/metrics.nim' with collector running shows all 5 metric names in collector output." \
  -p 1 -l docs --silent)
bd dep add $EXAMPLES_METRICS $API_RECORD_METRICS
bd dep add $EXAMPLES_METRICS $SETUP_DOCKER

EXAMPLES_LOGS=$(bd create "Write examples/logs.nim" \
  -d "File: examples/logs.nim. Demonstrate: (1) INFO LogRecord with string body, 2 attributes; (2) ERROR LogRecord with kvlist body, traceId and spanId populated, SeverityText='ERROR'; (3) WARN LogRecord with bytes body (base64 in JSON). record(e, resource, scope, logs); forceFlush(e); shutdown(e). Done when: 'nim c -r examples/logs.nim' with collector running shows 3 log records in collector output." \
  -p 1 -l docs --silent)
bd dep add $EXAMPLES_LOGS $API_RECORD_LOGS
bd dep add $EXAMPLES_LOGS $SETUP_DOCKER

EXAMPLES_README=$(bd create "Write examples/README.md" \
  -d "File: examples/README.md. Sections: Prerequisites (Nim, Docker Desktop or Docker Engine); Quick Start (numbered steps): (1) 'docker compose up -d' from repo root; (2) 'curl http://localhost:13133/' — expect 200 OK; (3) 'nim c -r examples/traces.nim'; (4) 'docker compose logs otelcol | grep span' to see spans; (5) 'cat collector-output/signals.json | head -100' for raw output; repeat for metrics and logs. Teardown: 'docker compose down -v'. Compiler flags note: all examples require --mm:orc --threads:on (supplied by examples/nim.cfg). gzip note: add -d:observyGzip for compression (requires zlib). TLS note: add -d:ssl for HTTPS (requires OpenSSL). Done when: a new contributor with only Nim and Docker installed can follow the README and see spans in under 5 minutes." \
  -p 1 -l docs --silent)
bd dep add $EXAMPLES_README $EXAMPLES_TRACES
bd dep add $EXAMPLES_README $EXAMPLES_METRICS
bd dep add $EXAMPLES_README $EXAMPLES_LOGS

# ========================================
# Phase 14: Integration Tests
# ========================================

INTEGRATION_HARNESS=$(bd create "Implement integration test harness with collector health-check" \
  -d "File: tests/integration/harness.nim. proc waitForCollector(timeoutMs: int = 30000) — polls http://localhost:13133/ every 500ms; raises if timeout exceeded. proc readCollectorOutput(): string — reads ./collector-output/signals.json. proc clearCollectorOutput() — truncates ./collector-output/signals.json to empty. Assertion helpers: proc assertServiceName(json, name: string), proc assertSpanCount(json: string; n: int), proc assertMetricName(json, name: string), proc assertLogBody(json, body: string), proc assertTraceIdHex(json, traceId: string) — asserts the value is a 32-char hex string. Done when: harness compiles and waitForCollector correctly returns when collector is up." \
  -p 0 -l testing --silent)
bd dep add $INTEGRATION_HARNESS $SETUP_DOCKER
bd dep add $INTEGRATION_HARNESS $API_UMBRELLA

INTEGRATION_TRACES=$(bd create "Write integration tests for Traces against collector output" \
  -d "File: tests/integration/test_integration_traces.nim. (1) waitForCollector(); (2) clearCollectorOutput(); (3) construct Span with serviceName='observy-test', spanName='integration-test', known traceId; (4) record and forceFlush; (5) sleep 500ms for collector to write; (6) json = readCollectorOutput(); (7) assert: assertServiceName(json, 'observy-test'); assertSpanCount(json, 1); assertTraceIdHex(json, hex(traceId)); json contains 'integration-test'. Fail correctly: test expects failure when serviceName is wrong. Done when: passes end-to-end in CI Docker environment." \
  -p 0 -l testing --silent)
bd dep add $INTEGRATION_TRACES $INTEGRATION_HARNESS
bd dep add $INTEGRATION_TRACES $TRACES_TESTS

INTEGRATION_METRICS=$(bd create "Write integration tests for Metrics against collector output" \
  -d "File: tests/integration/test_integration_metrics.nim. Send a counter metric named 'observy.test.counter' with value 42 and a histogram named 'observy.test.latency'. After forceFlush + sleep: assertMetricName(json, 'observy.test.counter'); assert the dataPoint value equals 42; assert temporality matches alwaysCumulative selector; assert 'observy.test.latency' present with histogram buckets. Done when: passes in CI." \
  -p 0 -l testing --silent)
bd dep add $INTEGRATION_METRICS $INTEGRATION_HARNESS
bd dep add $INTEGRATION_METRICS $METRICS_TESTS

INTEGRATION_LOGS=$(bd create "Write integration tests for Logs against collector output" \
  -d "File: tests/integration/test_integration_logs.nim. Send a LogRecord with body 'integration-log-body', severityNumber=INFO (9), known traceId. After forceFlush + sleep: assertLogBody(json, 'integration-log-body'); assertTraceIdHex(json, hex(traceId)); assert severityNumber=9 in output. Done when: passes in CI." \
  -p 0 -l testing --silent)
bd dep add $INTEGRATION_LOGS $INTEGRATION_HARNESS
bd dep add $INTEGRATION_LOGS $LOGS_TESTS

# ========================================
# Phase 15: Security & Edge Cases
# ========================================

SECURITY_INPUT=$(bd create "Verify and test input validation and security hardening" \
  -d "This bead AUDITS and PATCHES the implementations already written — do not re-implement attribute limits (done in MODEL_ANYVALUE). Check and add tests for: (1) TraceId exactly 16 bytes — if wrong size, raise ValueError not silently corrupt data; (2) SpanId exactly 8 bytes — same; (3) ExporterConfig.endpoint URL scheme must be 'http' or 'https' — raise on other schemes; (4) Header key/value strings: scan for CR (\\r) or LF (\\n) characters and raise ValueError (prevent HTTP header injection); (5) attribute string values: truncation uses rune-safe substring (don't cut a multi-byte UTF-8 sequence). Do NOT duplicate attribute count/length enforcement already in AttributeSet.add. Done when: testament tests confirm all 5 validation points." \
  -p 1 -l core --silent)
bd dep add $SECURITY_INPUT $MODEL_ANYVALUE_TESTS
bd dep add $SECURITY_INPUT $CONFIG_TESTS
bd dep add $SECURITY_INPUT $TRACES_MODEL

# ========================================
# Phase 16: Documentation & Publishing
# ========================================

DOCS_README=$(bd create "Write main README.md with quick-start for each signal" \
  -d "File: README.md. Sections: (1) About — exporter only, not a full OTel SDK, no TracerProvider/Tracer/sampling; (2) Installation — 'nimble install observy'; compiler flags '--mm:orc --threads:on' required; (3) Quick Start Traces — 10-line example using record() (NOT export()); (4) Quick Start Metrics — counter + histogram; (5) Quick Start Logs — INFO and ERROR records; (6) Configuration — ExporterConfig fields table + OTEL_* env-var table with path-append behavior documented; (7) Batch Export — BatchProcessor with forceFlush/shutdown; (8) Retry Policy — HTTP codes, Retry-After, elapsed cap; (9) TLS — '-d:ssl' requires OpenSSL; (10) gzip — '-d:observyGzip' requires zlib; (11) Profiles — '-d:observyProfiles', alpha, HTTP path /v1development/profiles; (12) Signals JSON path — /v1/traces, /v1/metrics, /v1/logs. Each code example is compilable. Done when: a Nim developer with no OTel knowledge can send their first span within 5 minutes." \
  -p 1 -l docs --silent)
bd dep add $DOCS_README $EXAMPLES_README
bd dep add $DOCS_README $API_UMBRELLA

DOCS_NIMBLE_PUBLISH=$(bd create "Prepare observy for nimble.directory publication" \
  -d "Update observy.nimble: correct name, version, description ('OTLP exporter for Nim — traces, metrics, logs, profiles'), homepage URL (GitHub), license MIT, tags @['opentelemetry', 'otlp', 'observability', 'tracing', 'metrics', 'logging']. Verify 'nimble check' passes. Create CHANGELOG.md with v0.1.0 entry listing all features. Tag git v0.1.0. Submit to nimble.directory via the web form (or nim-packages PR). Done when: 'nimble install observy' works from the published package." \
  -p 2 -l deploy --silent)
bd dep add $DOCS_NIMBLE_PUBLISH $DOCS_README
bd dep add $DOCS_NIMBLE_PUBLISH $INTEGRATION_TRACES
bd dep add $DOCS_NIMBLE_PUBLISH $INTEGRATION_METRICS
bd dep add $DOCS_NIMBLE_PUBLISH $INTEGRATION_LOGS

# ========================================
# Summary
# ========================================

echo ""
echo "Bead graph created (rev 2 — post dual-Opus review)!"
echo ""
echo "Key changes from rev 1:"
echo "  - API procs renamed 'record' (was 'export' — Nim keyword)"
echo "  - Proto encoder: canonical field order + omit-defaults rule added"
echo "  - Proto test methodology: model→encode→golden (not decode→reencode)"
echo "  - Metrics model: per-type structs, ExponentialHistogram missing fields added"
echo "  - Channel/Isolated: stdlib Channel[T]+std/isolation (not threading nimble pkg)"
echo "  - CONFIG_CORE: OTLP endpoint path-append rule documented"
echo "  - EXPORTER_HTTP_CORE: JSON dep edges wired in"
echo "  - gzip: libz system dep, -d:observyGzip flag (like -d:ssl for OpenSSL)"
echo "  - New: EXPORTER_PROTO_RESPONSE_DECODE bead (partial-success on protobuf)"
echo "  - New: PROFILES_JSON + API_RECORD_PROFILES beads"
echo "  - New: SETUP_COMPILER_FLAGS bead (config.nims)"
echo ""
echo "  bd ready              # Show tasks with no blocking dependencies"
echo "  bd graph              # Visualize dependency tree"
echo "  bd dep cycles         # Verify no cycles"
