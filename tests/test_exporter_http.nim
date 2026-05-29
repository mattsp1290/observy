import unittest
import std/net
import std/strutils
import std/httpcore
import std/times
import ../src/observy/config
import ../src/observy/exporter_http
import ../src/observy/retry
import ../src/observy/anyvalue
import ../src/observy/traces

# ---------------------------------------------------------------------------
# Local TCP mock server
#
# A background thread binds to an OS-assigned port (port 0), reports the actual
# port back over `portChan`, accepts one connection, reads the full HTTP request
# (headers + Content-Length body), captures it on `reqChan`, and returns 200 OK.
# Binding before reporting the port removes the bind/connect race entirely — no
# sleeps, no hardcoded ports (so no CI port collisions).
# ---------------------------------------------------------------------------

var reqChan: Channel[string]
var portChan: Channel[int]

proc recvRequest(client: Socket): string =
  # Nim's socket readLine yields the literal "\r\L" for a blank line (not ""),
  # which is how we detect the header terminator; then read Content-Length body.
  var headers = ""
  while true:
    var line = ""
    client.readLine(line, timeout = 3000)
    if line == "\r\L" or line.len == 0: break
    headers.add(line & "\r\n")
  var contentLen = 0
  for line in headers.split("\r\n"):
    if line.toLowerAscii.startsWith("content-length:"):
      contentLen = parseInt(line.split(":", 1)[1].strip())
  var body = ""
  if contentLen > 0:
    body = client.recv(contentLen, timeout = 3000)
  headers & "\r\n" & body

proc runMock() {.thread.} =
  var server = newSocket()
  var portSent = false
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0))             # OS picks a free port
    server.listen()
    portChan.send(int(server.getLocalAddr()[1]))
    portSent = true
    var client: Socket
    server.accept(client)
    let req = recvRequest(client)
    client.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    client.close()
    reqChan.send(req)
  except CatchableError as ex:
    if not portSent: portChan.send(-1)
    reqChan.send("ERROR: " & ex.msg)
  finally:
    server.close()

proc capture(body: proc (port: int)): string =
  ## Start the mock, wait until it has bound (via portChan — no sleep race),
  ## run `body(port)` to perform the export, then return the raw request.
  reqChan.open()
  portChan.open()
  var t: Thread[void]
  createThread(t, runMock)
  let port = portChan.recv()
  doAssert port > 0, "mock failed to bind"
  body(port)
  joinThread(t)
  result = reqChan.recv()
  reqChan.close()
  portChan.close()

proc baseConfig(): ExporterConfig =
  result.endpoint = "http://127.0.0.1"
  result.protocol = otlpProtoHttp

suite "OtlpHttpExporter sendRequest":
  test "protobuf protocol: correct path, method, and Content-Type":
    let payload = @[0x0a'u8, 0x01, 0x62]
    let req = capture(proc (port: int) =
      var e = newOtlpHttpExporter(baseConfig())
      discard e.sendRequest("http://127.0.0.1:" & $port & "/v1/traces",
                            payload, "application/x-protobuf")
      e.close())
    check req.startsWith("POST /v1/traces ")
    check req.toLowerAscii.contains("content-type: application/x-protobuf")

  test "custom headers are injected on every request":
    var cfg = baseConfig()
    cfg.headers = @[("authorization", "Bearer tok123"), ("x-tenant", "acme")]
    let req = capture(proc (port: int) =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest("http://127.0.0.1:" & $port & "/v1/traces",
                            @[0x01'u8, 0x02], "application/x-protobuf")
      e.close())
    check req.toLowerAscii.contains("authorization: bearer tok123")
    check req.toLowerAscii.contains("x-tenant: acme")

  test "protocol Content-Type wins over a colliding config header":
    var cfg = baseConfig()
    cfg.headers = @[("content-type", "text/plain")]   # must NOT override
    let req = capture(proc (port: int) =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest("http://127.0.0.1:" & $port & "/v1/traces",
                            @[0x01'u8], "application/x-protobuf")
      e.close())
    check req.toLowerAscii.contains("content-type: application/x-protobuf")
    check not req.toLowerAscii.contains("text/plain")

  test "protobuf body bytes (incl. NUL) are sent verbatim":
    let payload = @[0xde'u8, 0xad, 0xbe, 0xef, 0x00, 0x7f]
    let req = capture(proc (port: int) =
      var e = newOtlpHttpExporter(baseConfig())
      discard e.sendRequest("http://127.0.0.1:" & $port & "/v1/metrics",
                            payload, "application/x-protobuf")
      e.close())
    let body = req[req.find("\r\n\r\n") + 4 .. ^1]
    check body.len == payload.len
    for i, b in payload:
      check byte(body[i]) == b

  test "json protocol body and content-type":
    var cfg = baseConfig()
    cfg.protocol = otlpJsonHttp
    let jsonStr = "{\"resourceLogs\":[]}"
    var payload = newSeq[byte](jsonStr.len)
    for i, c in jsonStr: payload[i] = byte(c)
    let req = capture(proc (port: int) =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest("http://127.0.0.1:" & $port & "/v1/logs",
                            payload, defaultContentType(cfg.protocol))
      e.close())
    check req.toLowerAscii.contains("content-type: application/json")
    check req[req.find("\r\n\r\n") + 4 .. ^1] == jsonStr

suite "OtlpHttpExporter sendSignal":
  test "sendSignal uses the configured signal endpoint and protocol content-type":
    let req = capture(proc (port: int) =
      var cfg = baseConfig()
      cfg.protocol = otlpProtoHttp
      cfg.signalEndpoints[SigMetrics] = "http://127.0.0.1:" & $port & "/v1/metrics"
      var e = newOtlpHttpExporter(cfg)
      discard e.sendSignal(SigMetrics, @[0x01'u8])
      e.close())
    check req.startsWith("POST /v1/metrics ")
    check req.toLowerAscii.contains("content-type: application/x-protobuf")

  test "sendSignal with json protocol picks application/json":
    let req = capture(proc (port: int) =
      var cfg = baseConfig()
      cfg.protocol = otlpJsonHttp
      cfg.signalEndpoints[SigLogs] = "http://127.0.0.1:" & $port & "/v1/logs"
      var e = newOtlpHttpExporter(cfg)
      discard e.sendSignal(SigLogs, @[byte('{'), byte('}')])
      e.close())
    check req.startsWith("POST /v1/logs ")
    check req.toLowerAscii.contains("content-type: application/json")

suite "OtlpHttpExporter response":
  test "returns 200 with response metadata":
    var resp: ExportResponse
    discard capture(proc (port: int) =
      var e = newOtlpHttpExporter(baseConfig())
      resp = e.sendRequest("http://127.0.0.1:" & $port & "/v1/traces",
                           @[0x01'u8], "application/x-protobuf")
      e.close())
    check resp.code == Http200

suite "defaultContentType":
  test "protobuf maps to application/x-protobuf":
    check defaultContentType(otlpProtoHttp) == "application/x-protobuf"
  test "json maps to application/json":
    check defaultContentType(otlpJsonHttp) == "application/json"

suite "OtlpHttpExporter lifecycle and validation":
  when not defined(observyGzip):
    test "gzip compression fails fast at construction without -d:observyGzip":
      var cfg = baseConfig()
      cfg.compression = compGzip
      expect ValueError:
        discard newOtlpHttpExporter(cfg)

  when defined(observyGzip):
    test "gzip roundtrip — Content-Encoding header set and gzip magic bytes present":
      # Use a compressible payload (repeated byte pattern) large enough to produce
      # a non-trivially compressed body.
      let payload = newSeq[byte](64)   # 64 zero bytes, highly compressible
      let req = capture(proc (port: int) =
        var cfg = baseConfig()
        cfg.compression = compGzip
        cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:" & $port & "/v1/traces"
        var e = newOtlpHttpExporter(cfg)
        discard e.sendSignal(SigTraces, payload)
        e.close())
      check req.toLowerAscii.contains("content-encoding: gzip")
      let body = req[req.find("\r\n\r\n") + 4 .. ^1]
      check body.len > 0
      # Verify gzip magic number (0x1f 0x8b) — guards against windowBits regression
      # (zlib format starts 0x78; raw deflate has no header). If this ever uses
      # deflate or zlib framing instead of gzip, this test fails.
      check body.len >= 2
      check byte(body[0]) == 0x1f'u8
      check byte(body[1]) == 0x8b'u8

  test "empty URL raises":
    var e = newOtlpHttpExporter(baseConfig())
    expect ValueError:
      discard e.sendRequest("", @[0x01'u8], "application/x-protobuf")
    e.close()

  test "send after close raises":
    var e = newOtlpHttpExporter(baseConfig())
    e.close()
    expect ValueError:
      discard e.sendRequest("http://127.0.0.1:1/v1/traces", @[0x01'u8],
                            "application/x-protobuf")

suite "retryWithBackoff integration (real send path)":
  test "200 from mock → succeeded in one attempt":
    var result: ExportResult
    discard capture(proc (port: int) =
      var e = newOtlpHttpExporter(baseConfig())
      result = e.retryWithBackoff("http://127.0.0.1:" & $port & "/v1/traces",
                                  @[0x01'u8, 0x02], "application/x-protobuf")
      e.close())
    check result.succeeded
    check result.attempts == 1
    check result.response.code == Http200

suite "Input validation at system boundary":
  # Point 1 & 2: TraceId/SpanId are Nim array types (array[16,byte], array[8,byte])
  # enforced at compile time — no runtime validation needed. Verified by type declaration.
  test "TraceId is compile-time-enforced 16 bytes":
    var tid: TraceId
    check tid.len == 16    # array type guarantees this; no runtime check needed

  test "SpanId is compile-time-enforced 8 bytes":
    var sid: SpanId
    check sid.len == 8

  # Point 3: endpoint URL scheme must be http or https
  test "http scheme is accepted":
    var cfg = baseConfig()
    cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:4318/v1/traces"
    var e = newOtlpHttpExporter(cfg)
    e.close()
    check true

  test "https scheme is accepted":
    var cfg = baseConfig()
    cfg.signalEndpoints[SigTraces] = "https://collector.example.com/v1/traces"
    var e = newOtlpHttpExporter(cfg)
    e.close()
    check true

  test "non-http/https endpoint raises ValueError":
    var cfg = baseConfig()
    cfg.signalEndpoints[SigTraces] = "grpc://127.0.0.1:4317/v1/traces"
    expect ValueError:
      var e = newOtlpHttpExporter(cfg)
      e.close()

  test "ftp endpoint raises ValueError":
    var cfg = baseConfig()
    cfg.endpoint = "ftp://example.com"
    expect ValueError:
      var e = newOtlpHttpExporter(cfg)
      e.close()

  # Point 4: header key/value CR/LF injection prevention
  test "header with CR in name raises ValueError":
    var cfg = baseConfig()
    cfg.headers = @[("X-Evil\rHeader", "value")]
    expect ValueError:
      var e = newOtlpHttpExporter(cfg)
      e.close()

  test "header with LF in name raises ValueError":
    var cfg = baseConfig()
    cfg.headers = @[("X-Evil\nHeader", "value")]
    expect ValueError:
      var e = newOtlpHttpExporter(cfg)
      e.close()

  test "header with CR in value raises ValueError":
    var cfg = baseConfig()
    cfg.headers = @[("X-Token", "legit\rX-Injected: bad")]
    expect ValueError:
      var e = newOtlpHttpExporter(cfg)
      e.close()

  test "header with LF in value raises ValueError":
    var cfg = baseConfig()
    cfg.headers = @[("X-Token", "legit\nX-Injected: bad")]
    expect ValueError:
      var e = newOtlpHttpExporter(cfg)
      e.close()

  test "normal headers are accepted":
    var cfg = baseConfig()
    cfg.headers = @[("Authorization", "Bearer token123"), ("X-Tenant", "acme")]
    var e = newOtlpHttpExporter(cfg)
    e.close()
    check true

  # Point 5: attribute string truncation is UTF-8 safe (rune boundaries)
  test "truncateUtf8 does not cut a 2-byte UTF-8 sequence":
    # U+00E9 (é) is 2 bytes: 0xC3 0xA9. Truncating at 1 byte must yield empty.
    let s = "\xC3\xA9" & "rest"    # "érest"
    check truncateUtf8(s, 1) == ""   # can't fit the lead byte alone

  test "truncateUtf8 includes a 2-byte sequence when limit allows":
    let s = "\xC3\xA9" & "rest"
    check truncateUtf8(s, 2) == "\xC3\xA9"

  test "truncateUtf8 does not cut a 3-byte UTF-8 sequence":
    # U+4E2D (中) is 3 bytes: 0xE4 0xB8 0xAD
    let s = "\xE4\xB8\xAD" & "ok"
    check truncateUtf8(s, 2) == ""   # only 2 bytes available, can't fit 3-byte char
    check truncateUtf8(s, 3) == "\xE4\xB8\xAD"

  test "attribute add truncates string value to maxValueLen rune-safely":
    var attrs = initAttributeSet(maxCount = 128, maxValueLen = 2)
    # 3-byte UTF-8 char: truncating at maxValueLen=2 must not cut it
    attrs.add("k", AnyValue(kind: avString, strVal: "\xE4\xB8\xAD"))
    check attrs.pairs[0].value.strVal == ""   # can't fit the 3-byte char in 2 bytes

# ---------------------------------------------------------------------------
# Multi-response mock: returns different HTTP responses per connection number.
# ---------------------------------------------------------------------------
var multiReqChan: Channel[string]
var multiPortChan: Channel[int]
var multiResponses: seq[string]

proc runMultiMock() {.thread.} =
  {.cast(gcsafe).}:
    var server = newSocket()
    var portSent = false
    try:
      server.setSockOpt(OptReuseAddr, true)
      server.bindAddr(Port(0))
      server.listen()
      multiPortChan.send(int(server.getLocalAddr()[1]))
      portSent = true
      for i, resp in multiResponses:
        var client: Socket
        server.accept(client)
        let req = recvRequest(client)
        client.send(resp)
        client.close()
        multiReqChan.send(req)
    except CatchableError as ex:
      if not portSent: multiPortChan.send(-1)
      multiReqChan.send("ERROR: " & ex.msg)
    finally:
      server.close()

proc captureMulti(responses: seq[string]; body: proc (port: int)): seq[string] =
  multiResponses = responses
  multiReqChan.open()
  multiPortChan.open()
  var t: Thread[void]
  createThread(t, runMultiMock)
  let port = multiPortChan.recv()
  doAssert port > 0, "multi-mock failed to bind"
  body(port)
  joinThread(t)
  for _ in responses:
    let (ok, r) = multiReqChan.tryRecv()
    if ok: result.add(r)
  multiReqChan.close()
  multiPortChan.close()

suite "retryWithBackoff — end-to-end HTTP retry scenarios":
  # Use fast (no-sleep) hooks for deterministic, fast tests.
  proc fastHooks(): RetryHooks =
    var fakeTime = 0.0
    RetryHooks(
      nowSec:  proc (): float {.gcsafe.} = {.cast(gcsafe).}: fakeTime,
      sleepMs: proc (ms: int) {.gcsafe.} = {.cast(gcsafe).}: fakeTime += ms.float / 1000.0,
      jitter:  proc (d: float): float {.gcsafe.} = d,
      nowWall: proc (): Time {.gcsafe.} = {.cast(gcsafe).}: getTime(),
    )

  test "503 twice then 200 — retries twice and succeeds":
    # The mock returns 503 on the first two attempts then 200 on the third.
    const
      r503 = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n"
      r200 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    var result: ExportResult
    discard captureMulti(@[r503, r503, r200], proc (port: int) =
      var cfg = baseConfig()
      cfg.maxRetryElapsed = 60
      cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:" & $port & "/v1/traces"
      var e = newOtlpHttpExporter(cfg)
      result = e.retryWithBackoff(cfg.signalEndpoints[SigTraces],
                                  @[0x01'u8], "application/x-protobuf",
                                  hooks = fastHooks())
      e.close())
    check result.succeeded
    check result.attempts >= 3   # at least 2 retries after the two 503s
    check result.response.code == Http200

  test "400 does not retry — returns on first attempt":
    const r400 = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
    var result: ExportResult
    discard captureMulti(@[r400], proc (port: int) =
      var e = newOtlpHttpExporter(baseConfig())
      result = e.retryWithBackoff("http://127.0.0.1:" & $port & "/v1/traces",
                                  @[0x01'u8], "application/x-protobuf",
                                  hooks = fastHooks())
      e.close())
    check not result.succeeded
    check result.attempts == 1
    check result.response.code == Http400
