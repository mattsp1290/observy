## Runtime test for record(exporter, ..., profiles) — the alpha profiles emit
## path. Gated behind -d:observyProfiles. Imports the umbrella `observy` (where
## the record() overload lives) and drives it against a local TCP mock so the
## sendSignal(SigProfiles) → /v1development/profiles wiring and handle2xx
## partial-success path are exercised, not just compiled.
import unittest

when defined(observyProfiles):
  import std/net
  import std/strutils
  import std/httpcore
  import ../src/observy

  # Mock: capture the request line + return 200 with a protobuf partial_success
  # body (rejected_profiles via the signal-agnostic decode path) so handle2xx
  # surfaces a warning.
  var reqChan: Channel[string]
  var portChan: Channel[int]

  proc profMock() {.thread.} =
    {.cast(gcsafe).}:
      var server = newSocket()
      var portSent = false
      try:
        server.setSockOpt(OptReuseAddr, true)
        server.bindAddr(Port(0))
        server.listen()
        portChan.send(int(server.getLocalAddr()[1]))
        portSent = true
        var client: Socket
        server.accept(client)
        var headers = ""
        var firstLine = ""
        var lineNo = 0
        while true:
          var line = ""
          client.readLine(line, timeout = 3000)
          if lineNo == 0: firstLine = line
          inc lineNo
          if line == "\r\L" or line.len == 0: break
          headers.add(line & "\r\n")
        var clen = 0
        for ln in headers.split("\r\n"):
          if ln.toLowerAscii.startsWith("content-length:"):
            clen = parseInt(ln.split(":", 1)[1].strip())
        if clen > 0: discard client.recv(clen, timeout = 3000)
        # partial_success { rejected = 5, "quota exceeded" }
        const hexBody = "0a120805120e71756f7461206578636565646564"
        var b = ""
        var i = 0
        while i < hexBody.len:
          b.add(char(parseHexInt(hexBody[i ..< i+2])))
          i += 2
        client.send("HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: " &
                    $b.len & "\r\n\r\n" & b)
        client.close()
        reqChan.send(firstLine)
      except CatchableError as ex:
        if not portSent: portChan.send(-1)
        reqChan.send("ERR:" & ex.msg)
      finally:
        server.close()

  suite "Profiles record() exporter overload (alpha)":
    test "record() POSTs to /v1development/profiles and surfaces partial-success":
      reqChan.open(); portChan.open()
      var warns: Channel[string]
      warns.open()
      var t: Thread[void]
      createThread(t, profMock)
      let port = portChan.recv()
      doAssert port > 0

      var cfg: ExporterConfig
      cfg.protocol = otlpProtoHttp
      cfg.signalEndpoints[SigProfiles] =
        "http://127.0.0.1:" & $port & "/v1development/profiles"
      var e = newOtlpExporter(cfg)
      e.warn = proc (msg: string) {.gcsafe.} =
        {.cast(gcsafe).}: warns.send(msg)

      let res = Resource(attributes: initAttributeSet())
      let scope = InstrumentationScope(attributes: initAttributeSet())
      let p = Profile(stringTable: @["", "cpu"], timeNanos: 1, sample: @[
        Sample(locationIndex: @[0'u64], value: @[1'i64])])

      let resp = e.record(res, scope, @[p])
      e.close()
      joinThread(t)

      let reqLine = reqChan.recv()
      reqChan.close(); portChan.close()

      check resp.code == Http200
      check reqLine.startsWith("POST /v1development/profiles ")

      var msgs: seq[string]
      while true:
        let (ok, m) = warns.tryRecv()
        if not ok: break
        msgs.add(m)
      warns.close()
      check msgs.len == 1
      check msgs[0].contains("rejected=5")

else:
  suite "Profiles record() (skipped — no -d:observyProfiles)":
    test "skipped: compile with -d:observyProfiles to exercise profiles record()":
      skip()
