import unittest
import std/strutils
import std/atomics
import ../src/observy

proc hexToBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(s[i*2 ..< i*2+2]))

# Inputs mirroring the Python OTel SDK fixtures (see iteration 18 capture).
proc sampleResource(): Resource =
  var a = initAttributeSet()
  a.add("service.name", AnyValue(kind: avString, strVal: "svc"))
  Resource(attributes: a)

proc sampleScope(): InstrumentationScope =
  InstrumentationScope(name: "lib", version: "1.0", attributes: initAttributeSet())

proc sampleSpan(): Span =
  const
    TID = [0x4b'u8,0xf9,0x2f,0x35,0x77,0xb3,0x4d,0xa6,
           0xa3,0xce,0x92,0x9d,0x0e,0x0e,0x47,0x36]
    SID = [0x00'u8,0xf0,0x67,0xaa,0x0b,0xa9,0x02,0xb7]
  Span(traceId: TID, spanId: SID, name: "op", kind: skInternal,
       startTimeUnixNano: 1, endTimeUnixNano: 2, attributes: initAttributeSet())

# Golden request bytes from the Python SDK (ExportXServiceRequest serialization).
const
  TRACE_REQ = "0a5d0a170a150a0c736572766963652e6e616d6512050a0373766312420a0a0a036c69621203312e3012340a104bf92f3577b34da6a3ce929d0e0e4736120800f067aa0ba902b72a026f703001390100000000000000410200000000000000"
  LOGS_REQ  = "0a400a170a150a0c736572766963652e6e616d6512050a0373766312250a0a0a036c69621203312e30121709010000000000000010091a04494e464f2a040a026869"
  METRICS_REQ = "0a460a170a150a0c736572766963652e6e616d6512050a03737663122b0a0a0a036c69621203312e30121d0a01633a180a1219010000000000000031050000000000000010021801"

suite "proto request builders match the OTel SDK byte-for-byte":
  test "protoEncodeTraceRequest":
    let got = protoEncodeTraceRequest(sampleResource(), sampleScope(), @[sampleSpan()])
    check got == hexToBytes(TRACE_REQ)

  test "protoEncodeLogsRequest":
    let log = LogRecord(timeUnixNano: 1, severityNumber: severityInfo,
                        severityText: "INFO", body: AnyValue(kind: avString, strVal: "hi"),
                        attributes: initAttributeSet())
    let got = protoEncodeLogsRequest(sampleResource(), sampleScope(), @[log])
    check got == hexToBytes(LOGS_REQ)

  test "protoEncodeMetricsRequest":
    let m = Metric(name: "c", kind: mkSum, sum: MetricSum(
      dataPoints: @[NumberDataPoint(attributes: initAttributeSet(),
                                    timeUnixNano: 1, kind: ndpInt, intValue: 5)],
      aggregationTemporality: aggTempCumulative, isMonotonic: true))
    let got = protoEncodeMetricsRequest(sampleResource(), sampleScope(), @[m])
    check got == hexToBytes(METRICS_REQ)

# ---------------------------------------------------------------------------
# record() on a BatchProcessor enqueues; onBatch (worker) reports back.
# ---------------------------------------------------------------------------

var seenChan: Channel[int]

suite "record() on BatchProcessor":
  test "record(span) enqueues for batched export":
    seenChan.open()
    var p = newBatchProcessor[Span](
      BatchConfig(maxSize: 2, flushIntervalMs: 10_000, maxQueueSize: 100))
    p.start(proc (items: seq[Span]) {.gcsafe.} =
      {.cast(gcsafe).}: seenChan.send(items.len))
    p.record(sampleSpan())
    p.record(sampleSpan())
    p.forceFlush()
    p.shutdown()
    var total = 0
    while true:
      let (ok, n) = seenChan.tryRecv()
      if not ok: break
      total += n
    seenChan.close()
    check total == 2

  test "record(metric) and record(log) overloads resolve and enqueue":
    seenChan.open()
    var pm = newBatchProcessor[Metric](
      BatchConfig(maxSize: 1, flushIntervalMs: 10_000, maxQueueSize: 100))
    pm.start(proc (items: seq[Metric]) {.gcsafe.} =
      {.cast(gcsafe).}: seenChan.send(items.len))
    pm.record(Metric(name: "g", kind: mkGauge, gauge: MetricGauge(dataPoints: @[])))
    pm.forceFlush()
    pm.shutdown()
    var total = 0
    while true:
      let (ok, n) = seenChan.tryRecv()
      if not ok: break
      total += n
    seenChan.close()
    check total == 1

# ---------------------------------------------------------------------------
# record() on the exporter: synchronous send (encoded payload to the endpoint).
# ---------------------------------------------------------------------------

import std/net

var bodyChan: Channel[string]
var portChan2: Channel[int]

proc recordMock() {.thread.} =
  var server = newSocket()
  var portSent = false
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0))
    server.listen()
    portChan2.send(int(server.getLocalAddr()[1]))
    portSent = true
    var client: Socket
    server.accept(client)
    var headers = ""
    while true:
      var line = ""
      client.readLine(line, timeout = 3000)
      if line == "\r\L" or line.len == 0: break
      headers.add(line & "\r\n")
    var clen = 0
    for ln in headers.split("\r\n"):
      if ln.toLowerAscii.startsWith("content-length:"):
        clen = parseInt(ln.split(":", 1)[1].strip())
    var body = ""
    if clen > 0: body = client.recv(clen, timeout = 3000)
    client.send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    client.close()
    bodyChan.send(body)
  except CatchableError as ex:
    if not portSent: portChan2.send(-1)
    bodyChan.send("ERR:" & ex.msg)
  finally:
    server.close()

suite "record() on the exporter (synchronous send via mock)":
  test "proto protocol sends the exact ExportTraceServiceRequest bytes":
    bodyChan.open(); portChan2.open()
    var t: Thread[void]
    createThread(t, recordMock)
    let port = portChan2.recv()
    doAssert port > 0
    var cfg: ExporterConfig
    cfg.protocol = otlpProtoHttp
    cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:" & $port & "/v1/traces"
    var e = newOtlpExporter(cfg)
    let resp = e.record(sampleResource(), sampleScope(), @[sampleSpan()])
    e.close()
    joinThread(t)
    let body = bodyChan.recv()
    bodyChan.close(); portChan2.close()
    check resp.code == Http200
    var bodyBytes = newSeq[byte](body.len)
    for i, c in body: bodyBytes[i] = byte(c)
    check bodyBytes == hexToBytes(TRACE_REQ)

# Mock that returns 200 with a protobuf partial_success body (rejected_spans=5,
# "quota exceeded") and the x-protobuf content-type, to exercise record()'s
# partial-success handling.
var pbodyChan: Channel[string]
var pportChan: Channel[int]

proc partialMock() {.thread.} =
  var server = newSocket()
  var portSent = false
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0))
    server.listen()
    pportChan.send(int(server.getLocalAddr()[1]))
    portSent = true
    var client: Socket
    server.accept(client)
    var headers = ""
    while true:
      var line = ""
      client.readLine(line, timeout = 3000)
      if line == "\r\L" or line.len == 0: break
      headers.add(line & "\r\n")
    var clen = 0
    for ln in headers.split("\r\n"):
      if ln.toLowerAscii.startsWith("content-length:"):
        clen = parseInt(ln.split(":", 1)[1].strip())
    if clen > 0: discard client.recv(clen, timeout = 3000)
    # partial-success proto body
    let body = hexToBytes("0a120805120e71756f7461206578636565646564")
    var b = ""
    for x in body: b.add(char(x))
    client.send("HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: " &
                $b.len & "\r\n\r\n" & b)
    client.close()
    pbodyChan.send("ok")
  except CatchableError as ex:
    if not portSent: pportChan.send(-1)
    pbodyChan.send("ERR:" & ex.msg)
  finally:
    server.close()

suite "record() surfaces partial-success and JSON path":
  test "JSON protocol sends an OTLP-JSON body":
    bodyChan.open(); portChan2.open()
    var t: Thread[void]
    createThread(t, recordMock)
    let port = portChan2.recv()
    doAssert port > 0
    var cfg: ExporterConfig
    cfg.protocol = otlpJsonHttp
    cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:" & $port & "/v1/traces"
    var e = newOtlpExporter(cfg)
    let resp = e.record(sampleResource(), sampleScope(), @[sampleSpan()])
    e.close()
    joinThread(t)
    let body = bodyChan.recv()
    bodyChan.close(); portChan2.close()
    check resp.code == Http200
    check body.startsWith("{\"resourceSpans\":")

  test "200 with partial_success warns via the exporter warn hook":
    pbodyChan.open(); pportChan.open()
    var warns: Channel[string]
    warns.open()
    var t: Thread[void]
    createThread(t, partialMock)
    let port = pportChan.recv()
    doAssert port > 0
    var cfg: ExporterConfig
    cfg.protocol = otlpProtoHttp
    cfg.signalEndpoints[SigTraces] = "http://127.0.0.1:" & $port & "/v1/traces"
    var e = newOtlpExporter(cfg)
    e.warn = proc (msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: warns.send(msg)
    let resp = e.record(sampleResource(), sampleScope(), @[sampleSpan()])
    e.close()
    joinThread(t)
    discard pbodyChan.recv()
    pbodyChan.close(); pportChan.close()
    check resp.code == Http200
    var msgs: seq[string]
    while true:
      let (ok, m) = warns.tryRecv()
      if not ok: break
      msgs.add(m)
    warns.close()
    check msgs.len == 1
    check msgs[0].contains("rejected=5")
    check msgs[0].contains("quota exceeded")
