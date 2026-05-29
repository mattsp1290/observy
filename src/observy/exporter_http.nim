# OTLP/HTTP exporter core
#
# Transport for OTLP over HTTP/1.1 using Nim's stdlib httpclient.
# - protobuf protocol  -> Content-Type: application/x-protobuf
# - JSON protocol      -> Content-Type: application/json
# TLS (https endpoints) works automatically when compiled with -d:ssl (OpenSSL);
# plaintext http needs no external dependencies. gRPC/HTTP2 is out of scope.
import std/httpclient
import ./config

type
  OtlpHttpExporter* = object
    config*: ExporterConfig
    client*: HttpClient

proc defaultContentType*(p: OtlpProtocol): string =
  ## The OTLP/HTTP Content-Type implied by the configured protocol.
  case p
  of otlpProtoHttp: "application/x-protobuf"
  of otlpJsonHttp:  "application/json"

proc newOtlpHttpExporter*(config: ExporterConfig): OtlpHttpExporter =
  result.config = config
  result.client = newHttpClient()

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
                  contentType: string): HttpCode =
  ## POST `payload` to `url` with the given Content-Type, injecting every
  ## configured header. Returns the HTTP status code. `url` is the full
  ## signal endpoint (see ExporterConfig.signalEndpoints).
  var headers = newHttpHeaders()
  headers["Content-Type"] = contentType
  for (k, v) in e.config.headers:
    headers[k] = v
  e.client.headers = headers
  let resp = e.client.request(url, httpMethod = HttpPost,
                              body = bytesToBody(payload))
  result = resp.code

proc sendSignal*(e: var OtlpHttpExporter; signal: int;
                 payload: seq[byte]): HttpCode =
  ## Send an encoded payload to the configured endpoint for `signal`
  ## (SigTraces / SigMetrics / SigLogs / SigProfiles), using the Content-Type
  ## implied by the configured protocol.
  e.sendRequest(e.config.signalEndpoints[signal], payload,
                defaultContentType(e.config.protocol))
