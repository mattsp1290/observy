# OTLP/HTTP exporter core
#
# Transport for OTLP over HTTP/1.1 using Nim's stdlib httpclient.
# - protobuf protocol  -> Content-Type: application/x-protobuf
# - JSON protocol      -> Content-Type: application/json
# TLS (https endpoints) works automatically when compiled with -d:ssl (OpenSSL);
# plaintext http needs no external dependencies. gRPC/HTTP2 is out of scope.
import std/httpclient
import std/json
import std/strutils
import ./config
import ./proto

const defaultTimeoutMs = 10_000   ## OTLP spec default per-request timeout

type
  WarnProc* = proc (msg: string) {.gcsafe.}

  OtlpHttpExporter* = object
    ## Single-owner transport. Holds a `ref HttpClient`, so a copy shares the
    ## underlying socket and `close` on one copy invalidates the others — treat
    ## it as move-only / single-owner (one exporter per worker thread).
    config*: ExporterConfig
    client*: HttpClient
    warn*:   WarnProc        ## called on partial-success rejections; never silent

  ExportResponse* = object
    ## Result of a single HTTP export attempt. `body`/`contentType` are needed by
    ## the partial-success response decoder; `code` drives retry decisions.
    code*:        HttpCode
    contentType*: string
    body*:        string

  PartialSuccess* = object
    ## Decoded OTLP partial-success: how many items the collector rejected and
    ## an optional human-readable explanation. All-zero means full acceptance.
    rejectedCount*: int64
    errorMessage*:  string

proc defaultContentType*(p: OtlpProtocol): string =
  ## The OTLP/HTTP Content-Type implied by the configured protocol.
  case p
  of otlpProtoHttp: "application/x-protobuf"
  of otlpJsonHttp:  "application/json"

proc newOtlpHttpExporter*(config: ExporterConfig): OtlpHttpExporter =
  if config.compression == compGzip:
    # gzip support is gated behind -d:observyGzip (observy-5a9) and not yet wired.
    # Fail fast rather than silently shipping uncompressed bytes the collector
    # would reject for a mismatched Content-Encoding.
    raise newException(ValueError,
      "gzip compression is configured but not yet implemented; unset " &
      "OTEL_EXPORTER_OTLP_COMPRESSION (or config.compression) until observy-5a9 lands")
  result.config = config
  let timeout = if config.timeoutMs > 0: config.timeoutMs else: defaultTimeoutMs
  result.client = newHttpClient(timeout = timeout)
  result.warn = proc (msg: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      stderr.writeLine("observy: " & msg)

proc close*(e: var OtlpHttpExporter) =
  ## Release the underlying HTTP client (and its socket).
  if e.client != nil:
    e.client.close()
    e.client = nil

proc bytesToBody(payload: seq[byte]): string =
  ## Reinterpret raw bytes as an HTTP body string without re-encoding.
  result = newString(payload.len)
  if payload.len > 0:
    copyMem(addr result[0], unsafeAddr payload[0], payload.len)

proc sendRequest*(e: var OtlpHttpExporter; url: string; payload: seq[byte];
                  contentType: string): ExportResponse =
  ## POST `payload` to `url` with the given Content-Type, injecting every
  ## configured header, and return the status code plus the response body and
  ## Content-Type. `url` is the full signal endpoint (see signalEndpoints).
  ## Raises if the exporter is closed, the URL is empty, or the request fails
  ## at the transport level (connection refused, timeout, TLS) — the retry
  ## layer (observy-05l) is responsible for catching and re-attempting.
  if e.client == nil:
    raise newException(ValueError, "exporter is closed")
  if url.len == 0:
    raise newException(ValueError, "empty endpoint URL")
  var headers = newHttpHeaders()
  # Inject configured headers first, then set the protocol Content-Type LAST so a
  # stray user-supplied "content-type" header cannot override the wire protocol.
  for (k, v) in e.config.headers:
    headers[k] = v
  headers["Content-Type"] = contentType
  e.client.headers = headers
  let resp = e.client.request(url, httpMethod = HttpPost,
                              body = bytesToBody(payload))
  result.code = resp.code
  result.contentType = resp.headers.getOrDefault("content-type")
  result.body = resp.body

proc sendSignal*(e: var OtlpHttpExporter; signal: SignalIndex;
                 payload: seq[byte]): ExportResponse =
  ## Send an encoded payload to the configured endpoint for `signal`
  ## (SigTraces / SigMetrics / SigLogs / SigProfiles), using the Content-Type
  ## implied by the configured protocol.
  e.sendRequest(e.config.signalEndpoints[signal], payload,
                defaultContentType(e.config.protocol))

# ---------------------------------------------------------------------------
# Partial-success response handling
#
# Every OTLP 200 response MAY carry a partial_success message indicating the
# collector rejected some items. Silently dropping it hides data loss, so the
# exporter always decodes it and warns on any rejection.
#
# Export{Trace,Metrics,Logs}ServiceResponse share one shape:
#   field 1 = partial_success (message) { field 1 = rejected_* int64 (varint),
#                                          field 2 = error_message string }
# ---------------------------------------------------------------------------

proc decodeExportServiceResponseProto*(body: seq[byte]): PartialSuccess =
  ## Decode the protobuf Export*ServiceResponse partial_success. Empty/absent
  ## body → all-zero PartialSuccess (full acceptance).
  if body.len == 0: return
  var r = ProtoReader(data: body)
  while r.pos < body.len:
    let (fn, wt) = r.readTag()
    if fn == 1 and wt == WireLen:
      let psBytes = r.readBytes()
      var pr = ProtoReader(data: psBytes)
      while pr.pos < psBytes.len:
        let (pfn, pwt) = pr.readTag()
        if pfn == 1 and pwt == WireVarint:
          result.rejectedCount = pr.readInt64()
        elif pfn == 2 and pwt == WireLen:
          result.errorMessage = pr.readString()
        else:
          pr.skipField(pwt)
    else:
      r.skipField(wt)

proc parsePartialSuccessJson*(body: string): PartialSuccess =
  ## Extract partialSuccess.{rejectedSpans|rejectedDataPoints|rejectedLogRecords,
  ## errorMessage} from an OTLP/JSON response. int64 counts arrive as JSON
  ## strings per the OTLP JSON mapping, but tolerate a JSON number too.
  if body.strip().len == 0: return
  let j =
    try: parseJson(body)
    except CatchableError: return
  if j.kind != JObject or not j.hasKey("partialSuccess"): return
  let ps = j["partialSuccess"]
  if ps.kind != JObject: return
  for key in ["rejectedSpans", "rejectedDataPoints", "rejectedLogRecords"]:
    if ps.hasKey(key):
      let v = ps[key]
      result.rejectedCount =
        case v.kind
        of JString: (try: parseBiggestInt(v.getStr()) except ValueError: 0'i64)
        of JInt:    v.getBiggestInt()
        else:       0'i64
  if ps.hasKey("errorMessage") and ps["errorMessage"].kind == JString:
    result.errorMessage = ps["errorMessage"].getStr()

proc parsePartialSuccess*(body: string; contentType: string): PartialSuccess =
  ## Route a 200 response body to the JSON or protobuf decoder by Content-Type.
  ## Defaults to protobuf (the default protocol) for anything non-JSON.
  if contentType.toLowerAscii().contains("application/json"):
    parsePartialSuccessJson(body)
  else:
    var bytes = newSeq[byte](body.len)
    for i, c in body: bytes[i] = byte(c)
    decodeExportServiceResponseProto(bytes)

proc handleResponse*(e: OtlpHttpExporter; resp: ExportResponse): PartialSuccess =
  ## ALWAYS call this on a 200 response. Decodes partial-success and, if anything
  ## was rejected or an error message is present, emits a warning (never silently
  ## discards). Returns the decoded PartialSuccess to the caller.
  result = parsePartialSuccess(resp.body, resp.contentType)
  if result.rejectedCount > 0 or result.errorMessage.len > 0:
    if e.warn != nil:
      var msg = "partial success: rejected=" & $result.rejectedCount
      if result.errorMessage.len > 0:
        msg.add(" error=" & result.errorMessage)
      e.warn(msg)
