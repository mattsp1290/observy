import unittest
import std/net
import std/os
import std/strutils
import std/httpcore
import ../src/observy/config
import ../src/observy/exporter_http

# ---------------------------------------------------------------------------
# Local TCP mock server
#
# A background thread accepts a single connection, reads the full HTTP request
# (headers + Content-Length-delimited body), captures it, and returns 200 OK.
# The captured raw request is handed back via a global Channel.
# ---------------------------------------------------------------------------

var reqChan: Channel[string]

proc recvRequest(client: Socket): string =
  # Read the request line + headers with readLine (Nim sets `line` to the literal
  # "\r\L" for the blank header-terminator line, NOT ""), then read exactly
  # Content-Length body bytes. Returns the reconstructed "<headers>\r\n\r\n<body>".
  var headers = ""
  while true:
    var line = ""
    client.readLine(line, timeout = 3000)
    if line == "\r\L" or line.len == 0: break   # blank line ends headers (or EOF)
    headers.add(line & "\r\n")
  var contentLen = 0
  for line in headers.split("\r\n"):
    if line.toLowerAscii.startsWith("content-length:"):
      contentLen = parseInt(line.split(":", 1)[1].strip())
  var body = ""
  if contentLen > 0:
    body = client.recv(contentLen, timeout = 3000)
  headers & "\r\n" & body

proc runMock(port: int) {.thread.} =
  var server = newSocket()
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(port))
    server.listen()
    var client: Socket
    server.accept(client)
    let req = recvRequest(client)
    client.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    client.close()
    reqChan.send(req)
  except CatchableError as ex:
    reqChan.send("ERROR: " & ex.msg)
  finally:
    server.close()

proc captureRequest(port: int; body: proc ()): string =
  ## Start the mock on `port`, run `body` (which performs the export), and
  ## return the raw HTTP request the server received.
  reqChan.open()
  var t: Thread[int]
  createThread(t, runMock, port)
  sleep(150)   # let the server bind + listen before the client connects
  body()
  joinThread(t)
  result = reqChan.recv()
  reqChan.close()

proc baseConfig(): ExporterConfig =
  result.endpoint = "http://127.0.0.1"
  result.protocol = otlpProtoHttp

suite "OtlpHttpExporter sendRequest":
  test "protobuf protocol: correct path, method, and Content-Type":
    var cfg = baseConfig()
    let url = "http://127.0.0.1:18801/v1/traces"
    let payload = @[0x0a'u8, 0x01, 0x62]   # arbitrary proto-ish bytes
    let req = captureRequest(18801, proc () =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest(url, payload, "application/x-protobuf")
      e.close())
    check req.startsWith("POST /v1/traces ")
    check req.toLowerAscii.contains("content-type: application/x-protobuf")

  test "custom headers are injected on every request":
    var cfg = baseConfig()
    cfg.headers = @[("authorization", "Bearer tok123"), ("x-tenant", "acme")]
    let url = "http://127.0.0.1:18802/v1/traces"
    let req = captureRequest(18802, proc () =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest(url, @[0x01'u8, 0x02], "application/x-protobuf")
      e.close())
    check req.toLowerAscii.contains("authorization: bearer tok123")
    check req.toLowerAscii.contains("x-tenant: acme")

  test "protobuf body bytes are sent verbatim":
    var cfg = baseConfig()
    let url = "http://127.0.0.1:18803/v1/metrics"
    let payload = @[0xde'u8, 0xad, 0xbe, 0xef, 0x00, 0x7f]
    let req = captureRequest(18803, proc () =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest(url, payload, "application/x-protobuf")
      e.close())
    # Body is the last Content-Length bytes after the header terminator.
    let bodyStart = req.find("\r\n\r\n") + 4
    let body = req[bodyStart .. ^1]
    check body.len == payload.len
    for i, b in payload:
      check byte(body[i]) == b

  test "json protocol body and content-type":
    var cfg = baseConfig()
    cfg.protocol = otlpJsonHttp
    let url = "http://127.0.0.1:18804/v1/logs"
    let jsonStr = "{\"resourceLogs\":[]}"
    var payload = newSeq[byte](jsonStr.len)
    for i, c in jsonStr: payload[i] = byte(c)
    let req = captureRequest(18804, proc () =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendRequest(url, payload, defaultContentType(cfg.protocol))
      e.close())
    check req.toLowerAscii.contains("content-type: application/json")
    let bodyStart = req.find("\r\n\r\n") + 4
    check req[bodyStart .. ^1] == jsonStr

suite "OtlpHttpExporter sendSignal":
  test "sendSignal uses the configured signal endpoint and protocol content-type":
    var cfg = baseConfig()
    cfg.protocol = otlpProtoHttp
    cfg.signalEndpoints[SigMetrics] = "http://127.0.0.1:18805/v1/metrics"
    let req = captureRequest(18805, proc () =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendSignal(SigMetrics, @[0x01'u8])
      e.close())
    check req.startsWith("POST /v1/metrics ")
    check req.toLowerAscii.contains("content-type: application/x-protobuf")

  test "sendSignal with json protocol picks application/json":
    var cfg = baseConfig()
    cfg.protocol = otlpJsonHttp
    cfg.signalEndpoints[SigLogs] = "http://127.0.0.1:18806/v1/logs"
    let req = captureRequest(18806, proc () =
      var e = newOtlpHttpExporter(cfg)
      discard e.sendSignal(SigLogs, @[byte('{'), byte('}')])
      e.close())
    check req.startsWith("POST /v1/logs ")
    check req.toLowerAscii.contains("content-type: application/json")

suite "defaultContentType":
  test "protobuf maps to application/x-protobuf":
    check defaultContentType(otlpProtoHttp) == "application/x-protobuf"
  test "json maps to application/json":
    check defaultContentType(otlpJsonHttp) == "application/json"

suite "OtlpHttpExporter response":
  test "returns 200 from the mock server":
    var cfg = baseConfig()
    let url = "http://127.0.0.1:18807/v1/traces"
    reqChan.open()
    var t: Thread[int]
    createThread(t, runMock, 18807)
    sleep(150)
    var e = newOtlpHttpExporter(cfg)
    let code = e.sendRequest(url, @[0x01'u8], "application/x-protobuf")
    e.close()
    joinThread(t)
    discard reqChan.recv()
    reqChan.close()
    check code == Http200
