# OTLP/HTTP exporter core
#
# Transport for OTLP over HTTP/1.1 using Nim's stdlib httpclient.
# - protobuf protocol  -> Content-Type: application/x-protobuf
# - JSON protocol      -> Content-Type: application/json
# TLS (https endpoints) works automatically when compiled with -d:ssl (OpenSSL);
# plaintext http needs no external dependencies. gRPC/HTTP2 is out of scope.
import std/httpclient
import ./config

const defaultTimeoutMs = 10_000   ## OTLP spec default per-request timeout

type
  OtlpHttpExporter* = object
    ## Single-owner transport. Holds a `ref HttpClient`, so a copy shares the
    ## underlying socket and `close` on one copy invalidates the others — treat
    ## it as move-only / single-owner (one exporter per worker thread).
    config*: ExporterConfig
    client*: HttpClient

  ExportResponse* = object
    ## Result of a single HTTP export attempt. `body`/`contentType` are needed by
    ## the partial-success response decoder; `code` drives retry decisions.
    code*:        HttpCode
    contentType*: string
    body*:        string

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
