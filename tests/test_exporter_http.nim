import unittest
import std/net
import std/strutils
import std/httpcore
import ../src/observy/config
import ../src/observy/exporter_http

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
  test "gzip compression fails fast at construction":
    var cfg = baseConfig()
    cfg.compression = compGzip
    expect ValueError:
      discard newOtlpHttpExporter(cfg)

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
