## M0 networking spike — Rung 2.
##
## Build a REAL OTLP trace with observy's actual encoders (proto/anyvalue/
## resource/traces), POST it to the collector, expect HTTP 200. This proves the
## portable encoder core compiles for arm-none-eabi under arc/threads:off and
## emits wire-correct protobuf the collector accepts.
##
## Result is printed on-screen AND written to sdmc:/observy_spike_result.txt so
## it can be read back headlessly (Azahar maps sdmc to
## ~/Library/Application Support/Azahar/sdmc/; on hardware it's the SD root).

{.passC: "-I/opt/devkitpro/libctru/include".}

import std/strutils
# observy portable encoder core — imported directly (NOT the umbrella, which
# pulls batch/threads + httpclient). This is exactly the Tier-1 surface.
import observy/anyvalue
import observy/proto
import observy/resource
import observy/traces

# ---------------------------------------------------------------------------
# libctru bindings
# ---------------------------------------------------------------------------
proc gfxInitDefault() {.importc, header: "<3ds.h>".}
proc gfxExit() {.importc, header: "<3ds.h>".}
proc gfxFlushBuffers() {.importc, header: "<3ds.h>".}
proc gfxSwapBuffers() {.importc, header: "<3ds.h>".}
proc gspWaitForVBlank() {.importc, header: "<3ds.h>".}
proc consoleInit(screen: cint; con: pointer): pointer {.importc, header: "<3ds.h>", discardable.}
proc hidScanInput() {.importc, header: "<3ds.h>".}
proc hidKeysDown(): uint32 {.importc, header: "<3ds.h>".}
proc aptMainLoop(): bool {.importc, header: "<3ds.h>".}
proc osGetTime(): uint64 {.importc, header: "<3ds.h>".}
proc socInit(ctx: ptr uint32; size: uint32): cint {.importc, header: "<3ds.h>".}
proc socExit(): cint {.importc, header: "<3ds.h>".}
proc memalign(align: csize_t; size: csize_t): pointer {.importc, header: "<malloc.h>".}
proc svcOutputDebugString(str: cstring; length: cint): cint {.importc, header: "<3ds.h>", discardable.}
proc cprintf(fmt: cstring) {.importc: "printf", varargs, header: "<stdio.h>".}

const
  GFX_TOP = cint(0)
  KEY_START = uint32(1 shl 3)
  SOC_ALIGN = 0x1000
  SOC_BUFFERSIZE = 0x100000

proc logLine(s: string) =
  cprintf("%s\n", s.cstring)
  svcOutputDebugString(s.cstring, cint(s.len))

# Raw-socket HTTP/1.1 POST; returns status code (or negative transport error)
# and fills `respOut` with the first response bytes for diagnostics.
{.emit: """
#include <3ds.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

static int spike_post(const char* ip, int port, const char* path,
                      const unsigned char* body, int bodylen,
                      char* respOut, int respCap) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = inet_addr(ip);
  if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) { close(fd); return -2; }
  char hdr[512];
  int hlen = snprintf(hdr, sizeof(hdr),
    "POST %s HTTP/1.1\r\nHost: %s:%d\r\n"
    "Content-Type: application/x-protobuf\r\nContent-Length: %d\r\n"
    "Connection: close\r\n\r\n", path, ip, port, bodylen);
  if (send(fd, hdr, hlen, 0) < 0) { close(fd); return -3; }
  int off = 0;
  while (off < bodylen) {
    int s = send(fd, body + off, bodylen - off, 0);
    if (s <= 0) { close(fd); return -4; }
    off += s;
  }
  int n = recv(fd, respOut, respCap - 1, 0);
  close(fd);
  if (n <= 0) return -5;
  respOut[n] = 0;
  int code = 0;
  if (n > 12) sscanf(respOut + 9, "%d", &code);
  return code;
}
""".}

proc spikePost(ip: cstring; port: cint; path: cstring;
               body: ptr byte; bodylen: cint;
               respOut: cstring; respCap: cint): cint
  {.importc: "spike_post", nodecl.}

# observy request builder, replicated (it lives in the umbrella src/observy.nim,
# which we deliberately don't import here). Pure nesting over the real encoders.
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

proc nowUnixNano(): uint64 =
  (osGetTime() - 2_208_988_800_000'u64) * 1_000_000'u64

proc main() =
  gfxInitDefault()
  consoleInit(GFX_TOP, nil)
  logLine("OBSERVY-SPIKE rung2: real OTLP trace -> 200")

  # --- build the trace with observy's real types/encoders ---
  var resAttrs = initAttributeSet()
  resAttrs.add("service.name", AnyValue(kind: avString, strVal: "observy-3ds-verify"))
  resAttrs.add("device",       AnyValue(kind: avString, strVal: "nintendo-3ds"))
  let res = Resource(attributes: resAttrs)
  let scope = InstrumentationScope(name: "observy-3ds-spike", version: "0.1.0",
                                   attributes: initAttributeSet())
  let t0 = nowUnixNano()
  var sp = Span(
    traceId: [0xa1'u8,0xb2,0xc3,0xd4,0xe5,0xf6,0x07,0x18,0x29,0x3a,0x4b,0x5c,0x6d,0x7e,0x8f,0x90],
    spanId:  [0x11'u8,0x22,0x33,0x44,0x55,0x66,0x77,0x88],
    name: "boot", kind: skInternal,
    startTimeUnixNano: t0, endTimeUnixNano: t0 + 1_000_000'u64)
  let payload = encodeTraceRequest(res, scope, @[sp])
  logLine("OBSERVY-SPIKE encoded bytes=" & $payload.len & " t0=" & $t0)

  # --- send ---
  let socBuf = cast[ptr uint32](memalign(csize_t(SOC_ALIGN), csize_t(SOC_BUFFERSIZE)))
  var status = -99
  var respText = "(no response)"
  if socBuf != nil and socInit(socBuf, uint32(SOC_BUFFERSIZE)) == 0:
    var resp = newString(256)
    status = spikePost("10.0.0.106", cint(4318), "/v1/traces",
                       cast[ptr byte](unsafeAddr payload[0]), cint(payload.len),
                       resp.cstring, cint(resp.len))
    respText = resp
    discard socExit()
  else:
    logLine("OBSERVY-SPIKE FAIL socInit/memalign")

  let verdict = if status == 200: "RUNG2_PASS" else: "RUNG2_FAIL"
  logLine("OBSERVY-SPIKE RESULT http_status=" & $status & " " & verdict)

  # --- persist for headless readback ---
  let firstLine = respText.splitLines()[0]
  try:
    writeFile("observy_spike_result.txt",
      "http_status=" & $status & "\n" & verdict & "\n" &
      "encoded_bytes=" & $payload.len & "\nt0=" & $t0 & "\n" &
      "resp_first_line=" & firstLine & "\n")
    logLine("OBSERVY-SPIKE wrote observy_spike_result.txt")
  except CatchableError as e:
    logLine("OBSERVY-SPIKE writeFile failed: " & e.msg)

  logLine("OBSERVY-SPIKE done; press START to exit")
  while aptMainLoop():
    gspWaitForVBlank(); gfxFlushBuffers(); gfxSwapBuffers()
    hidScanInput()
    if (hidKeysDown() and KEY_START) != 0: break
  gfxExit()

main()
