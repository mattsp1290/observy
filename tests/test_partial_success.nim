import unittest
import std/strutils
import std/httpcore
import ../src/observy/config
import ../src/observy/exporter_http

proc hexToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(s[i*2 ..< i*2+2]))

# Golden proto bytes from the Python SDK:
#   ExportTraceServiceResponse(partial_success=
#     ExportTracePartialSuccess(rejected_spans=5, error_message="quota exceeded"))
const partialProtoHex = "0a120805120e71756f7461206578636565646564"

suite "decodeExportServiceResponseProto":
  test "decodes rejected count and error message":
    let ps = decodeExportServiceResponseProto(hexToBytes(partialProtoHex))
    check ps.rejectedCount == 5
    check ps.errorMessage == "quota exceeded"

  test "empty body is full acceptance":
    let ps = decodeExportServiceResponseProto(@[])
    check ps.rejectedCount == 0
    check ps.errorMessage == ""

  test "rejected count only (no message)":
    # partial_success { rejected_spans = 3 }  ->  0a02 0803
    let ps = decodeExportServiceResponseProto(hexToBytes("0a020803"))
    check ps.rejectedCount == 3
    check ps.errorMessage == ""

  test "message only (rejected = 0, suppressed)":
    # partial_success { error_message = "warn" }  ->  0a06 1204 77 61 72 6e
    let ps = decodeExportServiceResponseProto(hexToBytes("0a0612047761726e"))
    check ps.rejectedCount == 0
    check ps.errorMessage == "warn"

  test "unknown trailing fields are skipped":
    # field 1 partial_success {rejected=5}, plus an unknown field 2 varint
    let ps = decodeExportServiceResponseProto(hexToBytes("0a0208051001"))
    check ps.rejectedCount == 5

suite "parsePartialSuccessJson":
  test "rejectedSpans as JSON string":
    let ps = parsePartialSuccessJson(
      "{\"partialSuccess\":{\"rejectedSpans\":\"7\",\"errorMessage\":\"bad\"}}")
    check ps.rejectedCount == 7
    check ps.errorMessage == "bad"

  test "rejectedDataPoints key":
    let ps = parsePartialSuccessJson(
      "{\"partialSuccess\":{\"rejectedDataPoints\":\"2\"}}")
    check ps.rejectedCount == 2

  test "rejectedLogRecords key":
    let ps = parsePartialSuccessJson(
      "{\"partialSuccess\":{\"rejectedLogRecords\":\"9\"}}")
    check ps.rejectedCount == 9

  test "tolerates a JSON number count":
    let ps = parsePartialSuccessJson(
      "{\"partialSuccess\":{\"rejectedSpans\":4}}")
    check ps.rejectedCount == 4

  test "empty body is full acceptance":
    check parsePartialSuccessJson("").rejectedCount == 0

  test "no partialSuccess key is full acceptance":
    check parsePartialSuccessJson("{}").rejectedCount == 0

  test "malformed JSON does not crash":
    let ps = parsePartialSuccessJson("{not json")
    check ps.rejectedCount == 0
    check ps.errorMessage == ""

suite "parsePartialSuccess routing":
  test "application/json routes to JSON parser":
    let ps = parsePartialSuccess(
      "{\"partialSuccess\":{\"rejectedSpans\":\"1\"}}", "application/json")
    check ps.rejectedCount == 1

  test "application/x-protobuf routes to proto parser":
    let body = newString(hexToBytes(partialProtoHex).len)
    var s = ""
    for b in hexToBytes(partialProtoHex): s.add(char(b))
    let ps = parsePartialSuccess(s, "application/x-protobuf")
    check ps.rejectedCount == 5
    check ps.errorMessage == "quota exceeded"

  test "content-type with charset suffix still routes to JSON":
    let ps = parsePartialSuccess(
      "{\"partialSuccess\":{\"rejectedSpans\":\"1\"}}",
      "application/json; charset=utf-8")
    check ps.rejectedCount == 1

suite "handleResponse warning":
  proc cfg(): ExporterConfig =
    result.protocol = otlpProtoHttp

  test "warns when items are rejected; warning carries count and message":
    var captured: seq[string]
    var e = newOtlpHttpExporter(cfg())
    e.warn = proc (msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: captured.add(msg)
    var s = ""
    for b in hexToBytes(partialProtoHex): s.add(char(b))
    let resp = ExportResponse(code: Http200, contentType: "application/x-protobuf", body: s)
    let ps = e.handleResponse(resp)
    e.close()
    check ps.rejectedCount == 5
    check captured.len == 1
    check captured[0].contains("rejected=5")
    check captured[0].contains("quota exceeded")

  test "does not warn on full acceptance (empty body)":
    var captured: seq[string]
    var e = newOtlpHttpExporter(cfg())
    e.warn = proc (msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: captured.add(msg)
    let resp = ExportResponse(code: Http200, contentType: "application/x-protobuf", body: "")
    let ps = e.handleResponse(resp)
    e.close()
    check ps.rejectedCount == 0
    check captured.len == 0

  test "warns on JSON partial success":
    var captured: seq[string]
    var e = newOtlpHttpExporter(cfg())
    e.warn = proc (msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: captured.add(msg)
    let resp = ExportResponse(code: Http200, contentType: "application/json",
      body: "{\"partialSuccess\":{\"rejectedSpans\":\"3\",\"errorMessage\":\"throttled\"}}")
    discard e.handleResponse(resp)
    e.close()
    check captured.len == 1
    check captured[0].contains("rejected=3")
    check captured[0].contains("throttled")

  test "truncated protobuf body warns (not crash) and returns empty":
    var captured: seq[string]
    var e = newOtlpHttpExporter(cfg())
    e.warn = proc (msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: captured.add(msg)
    # field 1 length-delimited claiming 18 bytes but truncated → ProtoError
    var s = ""
    for b in hexToBytes("0a12080512"): s.add(char(b))
    let resp = ExportResponse(code: Http200, contentType: "application/x-protobuf", body: s)
    let ps = e.handleResponse(resp)
    e.close()
    check ps.rejectedCount == 0
    check captured.len == 1
    check captured[0].contains("could not")  or captured[0].contains("failed to decode")

  test "malformed JSON body warns (not silent)":
    var captured: seq[string]
    var e = newOtlpHttpExporter(cfg())
    e.warn = proc (msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: captured.add(msg)
    let resp = ExportResponse(code: Http200, contentType: "application/json",
      body: "{not valid json")
    discard e.handleResponse(resp)
    e.close()
    check captured.len == 1
    check captured[0].contains("failed to decode")

  test "rejectedProfiles JSON key is recognized":
    let ps = parsePartialSuccessJson(
      "{\"partialSuccess\":{\"rejectedProfiles\":\"6\"}}")
    check ps.rejectedCount == 6
