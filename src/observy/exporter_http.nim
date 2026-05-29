# OTLP/HTTP exporter core
#
# Transport for OTLP over HTTP/1.1 using Nim's stdlib httpclient.
# - protobuf protocol  -> Content-Type: application/x-protobuf
# - JSON protocol      -> Content-Type: application/json
# TLS (https endpoints) works automatically when compiled with -d:ssl (OpenSSL);
# plaintext http needs no external dependencies. gRPC/HTTP2 is out of scope.
import std/httpclient
import std/httpcore
export httpcore   ## HttpCode / Http200 etc. are part of ExportResponse's surface
import std/json
import std/strutils
import ./config
import ./proto

const defaultTimeoutMs = 10_000   ## OTLP spec default per-request timeout

type
  WarnProc* = proc (msg: string) {.gcsafe.}
    ## Called when a 200 response reports rejected items or fails to decode.
    ## May run on a worker thread once the batch processor (observy-ef5) owns the
    ## exporter, so it must be gcsafe and must not capture shared mutable GC state.

  OtlpHttpExporter* = object
    ## Single-owner transport. Holds a `ref HttpClient`, so a copy shares the
    ## underlying socket and `close` on one copy invalidates the others — treat
    ## it as move-only / single-owner (one exporter per worker thread).
    config*: ExporterConfig
    client:  HttpClient      ## internal transport (ref); not part of the value-type surface
    warn*:   WarnProc        ## called on partial-success rejections; never silent

  ExportResponse* = object
    ## Result of a single HTTP export attempt. `body`/`contentType` are needed by
    ## the partial-success response decoder; `code` drives retry decisions;
    ## `retryAfter` carries the raw Retry-After header (seconds or HTTP-date) for
    ## the backoff layer.
    code*:        HttpCode
    contentType*: string
    body*:        string
    retryAfter*:  string

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
  # ---------------------------------------------------------------------------
  # Input validation at the system boundary — fail fast with a clear message
  # rather than silently sending malformed requests or allowing header injection.
  # ---------------------------------------------------------------------------

  # Endpoint URL scheme must be http or https. Empty strings are skipped
  # (they mean "signal not configured") — sendRequest already raises ValueError
  # on an empty URL at send time, providing the second line of defence.
  block:
    var eps = @[config.endpoint]
    for s in config.signalEndpoints: eps.add(s)
    for ep in eps:
      if ep.len > 0 and not (ep.startsWith("http://") or ep.startsWith("https://")):
        raise newException(ValueError,
          "endpoint URL must start with http:// or https://: '" & ep & "'")

  # Headers must not contain CR or LF characters (prevent HTTP header injection).
  for (k, v) in config.headers:
    if '\r' in k or '\n' in k:
      raise newException(ValueError,
        "header name contains CR or LF (potential HTTP header injection): '" & k & "'")
    if '\r' in v or '\n' in v:
      raise newException(ValueError,
        "header value contains CR or LF (potential HTTP header injection) for key '" & k & "'")

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
  result.retryAfter = resp.headers.getOrDefault("retry-after")

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

proc bodyToBytes(body: string): seq[byte] =
  ## Reinterpret an HTTP body string as raw bytes (mirror of bytesToBody).
  result = newSeq[byte](body.len)
  if body.len > 0:
    copyMem(addr result[0], unsafeAddr body[0], body.len)

proc decodeExportServiceResponseProto*(body: seq[byte]): PartialSuccess =
  ## Decode the protobuf Export*ServiceResponse partial_success. Empty/absent
  ## body → all-zero PartialSuccess (full acceptance). Raises ProtoError on a
  ## malformed/truncated body — callers that take untrusted wire data should use
  ## parsePartialSuccess / handleResponse, which degrade to empty instead.
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

proc decodeStrict(body: string; contentType: string): PartialSuccess =
  ## Single decode path, by Content-Type. RAISES on a malformed body (JSON parse
  ## error / ProtoError). Empty body or absent partial_success → all-zero.
  if body.len == 0: return
  if contentType.toLowerAscii().contains("application/json"):
    let j = parseJson(body)
    if j.kind != JObject or not j.hasKey("partialSuccess"): return
    let ps = j["partialSuccess"]
    if ps.kind != JObject: return
    # rejectedProfiles included for parity with the signal-agnostic proto path
    # (profiles is experimental; harmless to recognize here).
    for key in ["rejectedSpans", "rejectedDataPoints", "rejectedLogRecords",
                "rejectedProfiles"]:
      if ps.hasKey(key):
        let v = ps[key]
        result.rejectedCount =
          case v.kind
          of JString: (try: parseBiggestInt(v.getStr()) except ValueError: 0'i64)
          of JInt:    v.getBiggestInt()
          else:       0'i64
        break   # only one rejected_* key is valid per signal
    if ps.hasKey("errorMessage") and ps["errorMessage"].kind == JString:
      result.errorMessage = ps["errorMessage"].getStr()
  else:
    # default / x-protobuf
    result = decodeExportServiceResponseProto(bodyToBytes(body))

proc parsePartialSuccess*(body: string; contentType: string): PartialSuccess =
  ## Lenient router: never raises. A malformed/undecodable body degrades to an
  ## all-zero PartialSuccess. Use handleResponse if you also want a warning on a
  ## body that arrived but could not be decoded.
  try: decodeStrict(body, contentType)
  except CatchableError: PartialSuccess()

proc parsePartialSuccessJson*(body: string): PartialSuccess =
  ## Lenient JSON-only decode (never raises). Retained for direct callers/tests.
  try: decodeStrict(body, "application/json")
  except CatchableError: PartialSuccess()

proc handleResponse*(e: OtlpHttpExporter; resp: ExportResponse): PartialSuccess =
  ## ALWAYS call this on a 200 response. Decodes partial-success and warns (never
  ## silently discards) when items were rejected. A body that arrived but failed
  ## to decode also warns ("possible undetected partial success") rather than
  ## crashing (proto) or going silent (JSON). Returns the decoded PartialSuccess.
  ##
  ## NOTE: this is NOT yet wired into sendRequest/sendSignal — those are
  ## single-attempt primitives. The retry/batch orchestration layer (observy-05l,
  ## observy-ef5) MUST route each final 200 ExportResponse through handleResponse.
  ## Tracked by observy follow-up bead.
  if resp.body.len == 0:
    return PartialSuccess()        # empty body = unambiguous full acceptance
  try:
    result = decodeStrict(resp.body, resp.contentType)
  except CatchableError as ex:
    if e.warn != nil:
      e.warn("received HTTP 200 but failed to decode response body (" &
             ex.msg & ") — possible undetected partial success")
    return PartialSuccess()
  if result.rejectedCount != 0 or result.errorMessage.len > 0:
    if e.warn != nil:
      var msg = "partial success: rejected=" & $result.rejectedCount
      if result.errorMessage.len > 0:
        msg.add(" error=" & result.errorMessage)
      e.warn(msg)
