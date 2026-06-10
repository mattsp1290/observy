## M0 PlayStation Vita networking + time spike.
##
## Headless app. It rewrites ux0:data/observy_vita_spike.txt after every
## breadcrumb so a hardware hang still leaves the last completed step.

when not defined(vita):
  {.error: "build with spike/build_vita_spike.sh (-d:vita)".}

import std/os
import std/posix
import std/strutils

import http
import observy/anyvalue
import observy/proto
import observy/resource
import observy/traces

const
  CollectorEndpoint {.strdefine.} = "http://10.0.0.106:4318"
  ResultPath = "ux0:data/observy_vita_spike.txt"
  RtcEpochOffsetMicros = 62_135_596_800_000_000'u64

type SceRtcTick {.importc: "SceRtcTick", header: "<psp2/rtc.h>", bycopy.} = object
  tick: uint64

proc sceNetCtlInetGetState(state: ptr cint): cint
  {.importc, header: "<psp2/net/netctl.h>".}
proc sceKernelExitProcess(status: cint): cint
  {.importc, header: "<psp2/kernel/processmgr.h>", discardable.}
proc sceRtcGetCurrentTick(tick: ptr SceRtcTick): cint
  {.importc, header: "<psp2/rtc.h>".}
proc sceRtcGetTickResolution(): cint
  {.importc, header: "<psp2/rtc.h>".}

var crumbs: seq[string]

proc crumb(line: string) =
  crumbs.add(line)
  try:
    createDir("ux0:data")
    writeFile(ResultPath, crumbs.join("\n") & "\n")
  except CatchableError:
    discard

proc statusLine(resp: Response): string =
  $int(resp.code) & " " & $resp.code

proc bytesToString(payload: seq[byte]): string =
  result = newString(payload.len)
  if payload.len > 0:
    copyMem(addr result[0], unsafeAddr payload[0], payload.len)

proc encodeTraceRequest(res: Resource; scope: InstrumentationScope;
                        spans: seq[Span]): seq[byte] =
  var scopeSpans: ProtoWriter
  scopeSpans.writeBytes(1, protoEncode(scope))
  for s in spans:
    var sw: ProtoWriter
    protoEncodeSpan(sw, s)
    scopeSpans.writeBytes(2, sw.buf)
  var resourceSpans: ProtoWriter
  resourceSpans.writeBytes(1, protoEncode(res))
  resourceSpans.writeBytes(2, scopeSpans.buf)
  var req: ProtoWriter
  req.writeBytes(1, resourceSpans.buf)
  req.buf

proc clockRealtimeNano(): uint64 =
  var ts: Timespec
  if clock_gettime(CLOCK_REALTIME, ts) != 0:
    raise newException(OSError, "clock_gettime(CLOCK_REALTIME): " & $strerror(errno))
  ts.tv_sec.uint64 * 1_000_000_000'u64 + ts.tv_nsec.uint64

proc rtcUnixNano(): uint64 =
  var tick: SceRtcTick
  let rc = sceRtcGetCurrentTick(addr tick)
  if rc < 0:
    raise newException(OSError, "sceRtcGetCurrentTick failed: " & $rc)
  if tick.tick < RtcEpochOffsetMicros:
    raise newException(ValueError, "sceRtcGetCurrentTick precedes Unix epoch: " & $tick.tick)
  (tick.tick - RtcEpochOffsetMicros) * 1_000'u64

proc buildSpan(i: int; nowNs: uint64): Span =
  var attrs = initAttributeSet()
  attrs.add("device", AnyValue(kind: avString, strVal: "playstation-vita"))
  attrs.add("rung", AnyValue(kind: avString, strVal: "m0-spike"))
  attrs.add("iteration", AnyValue(kind: avInt, intVal: i.int64))
  Span(
    traceId: [0xa1'u8, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18,
              0x29, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90],
    spanId: [byte(i and 0xff), 0x22'u8, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
    name: "vita-spike-" & $i,
    kind: skInternal,
    startTimeUnixNano: nowNs,
    endTimeUnixNano: nowNs + 1_000_000'u64,
    attributes: attrs,
    droppedAttributesCount: attrs.dropped,
    events: @[
      SpanEvent(
        timeUnixNano: nowNs,
        name: "breadcrumb",
        attributes: initAttributeSet()
      )
    ],
    status: SpanStatus(code: statusOk)
  )

proc post(client: HttpClient; path: string; contentType: string; body: string): Response =
  client.headers["Content-Type"] = contentType
  client.request(CollectorEndpoint & path, httpMethod = HttpPost, body = body)

proc excSummary(e: ref CatchableError): string =
  $e.name & ": " & e.msg

proc main() =
  crumb("START observy Vita M0 spike")
  crumb("collector=" & CollectorEndpoint)

  try:
    httpInit()
    crumb("httpInit PASS")
  except CatchableError as e:
    crumb("httpInit FAIL " & e.msg)
    discard sceKernelExitProcess(0)
    return

  var netState: cint = -1
  let netRc = sceNetCtlInetGetState(addr netState)
  crumb("sceNetCtlInetGetState rc=" & $netRc & " state=" & $netState & " (3 means IP obtained)")

  var rung1Ok = false
  try:
    let c = newHttpClient(timeout = 10_000)
    let resp = c.post("/v1/traces", "application/x-protobuf", "junk-from-observy-vita")
    crumb("RUNG1 finite-timeout PASS http_status=" & statusLine(resp))
    rung1Ok = true
  except CatchableError as e:
    crumb("RUNG1 finite-timeout FAIL " & excSummary(e))

  try:
    let c = newHttpClient(timeout = -1)
    let resp = c.post("/v1/traces", "application/x-protobuf", "junk-from-observy-vita-infinite")
    crumb("RUNG1 infinite-timeout PASS http_status=" & statusLine(resp))
    rung1Ok = true
  except CatchableError as e:
    crumb("RUNG1 infinite-timeout FAIL " & excSummary(e))

  if not rung1Ok:
    crumb("STOP RUNG1 hard failure; skipping RUNG2/RUNG3/RUNG4")
    httpShutdown()
    discard sceKernelExitProcess(0)
    return

  var chosenNow = 0'u64
  try:
    chosenNow = clockRealtimeNano()
  except CatchableError:
    try:
      chosenNow = rtcUnixNano()
    except CatchableError:
      chosenNow = 1_700_000_000_000_000_000'u64

  var resAttrs = initAttributeSet()
  resAttrs.add("service.name", AnyValue(kind: avString, strVal: "observy-vita-spike"))
  resAttrs.add("device", AnyValue(kind: avString, strVal: "playstation-vita"))
  resAttrs.add("observy.run.id", AnyValue(kind: avString, strVal: "vita-spike-" & $chosenNow))
  let res = Resource(attributes: resAttrs, droppedAttributesCount: resAttrs.dropped)
  let scope = InstrumentationScope(name: "observy-vita-spike", version: "0.1.0",
                                   attributes: initAttributeSet())
  let payload = encodeTraceRequest(res, scope, @[buildSpan(1, chosenNow)])
  crumb("RUNG2 encoded trace bytes=" & $payload.len)

  var rung2Ok = false
  try:
    let c = newHttpClient(timeout = 10_000)
    let resp = c.post("/v1/traces", "application/x-protobuf", bytesToString(payload))
    if int(resp.code) == 200:
      crumb("RUNG2 PASS http_status=" & statusLine(resp))
      rung2Ok = true
    else:
      crumb("RUNG2 FAIL http_status=" & statusLine(resp) & " body=" & resp.body)
  except CatchableError as e:
    crumb("RUNG2 FAIL " & excSummary(e))

  if not rung2Ok:
    crumb("STOP RUNG2 hard failure; skipping RUNG3/RUNG4")
    httpShutdown()
    discard sceKernelExitProcess(0)
    return

  chosenNow = 0'u64
  try:
    chosenNow = clockRealtimeNano()
    crumb("RUNG3 CLOCK_REALTIME PASS unix_nano=" & $chosenNow)
  except CatchableError as e:
    crumb("RUNG3 CLOCK_REALTIME FAIL " & excSummary(e))

  try:
    let res = sceRtcGetTickResolution()
    let rtcNow = rtcUnixNano()
    crumb("RUNG3 sceRtcGetCurrentTick PASS unix_nano=" & $rtcNow &
          " resolution=" & $res)
    if chosenNow == 0'u64:
      chosenNow = rtcNow
  except CatchableError as e:
    crumb("RUNG3 sceRtcGetCurrentTick FAIL " & excSummary(e))

  if chosenNow == 0'u64:
    crumb("NO-GO no wall-clock source produced a Unix timestamp")
    httpShutdown()
    discard sceKernelExitProcess(0)
    return

  try:
    var totalBytes = 0
    for i in 0 ..< 100:
      let p = encodeTraceRequest(res, scope, @[buildSpan(i + 2, chosenNow + uint64(i + 1) * 1_000_000'u64)])
      totalBytes += p.len
      if i mod 10 == 9:
        crumb("RUNG4 progress cycles=" & $(i + 1) & " encoded_bytes_total=" & $totalBytes)
    crumb("RUNG4 encode-loop PASS cycles=100 encoded_bytes_total=" & $totalBytes)
  except CatchableError as e:
    crumb("RUNG4 FAIL " & excSummary(e))

  httpShutdown()
  crumb("DONE inspect rung PASS/FAIL lines and compare RUNG3 timestamps to UTC wall clock")
  discard sceKernelExitProcess(0)

main()
