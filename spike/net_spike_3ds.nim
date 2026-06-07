## M0 networking spike — Rung 1 (and scaffold for Rung 2).
##
## Bare Nintendo 3DS app: bring up gfx/console, init the SOC service, open a raw
## BSD socket and POST a body to the collector, print the HTTP status code.
##
## Rung 1 PASS = any HTTP status line comes back from 10.0.0.106:4318 (even
## 400/415 — that proves bytes crossed the network and the collector answered).
## Connection refused / timeout / crash = platform networking not working yet.
##
## Build:  see spike/build_spike.sh
## Run:    3dslink build/net_spike.3dsx   (3DS in netloader mode), or Azahar,
##         or copy to the SD card and launch via Homebrew Launcher.

{.passC: "-I/opt/devkitpro/libctru/include".}

# ---------------------------------------------------------------------------
# libctru bindings (minimal, hand-rolled for the spike)
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

const
  GFX_TOP = cint(0)         ## gfxScreen_t: top screen
  KEY_START = uint32(1 shl 3)
  SOC_ALIGN = 0x1000
  SOC_BUFFERSIZE = 0x100000  ## 1 MiB, must be 0x1000-aligned

# C printf for reliable console output after consoleInit.
proc cprintf(fmt: cstring) {.importc: "printf", varargs, header: "<stdio.h>".}

# Log a line to BOTH the on-screen console and the emulator/debugger debug log
# (svcOutputDebugString surfaces in Azahar/Citra's azahar_log.txt → lets us
# verify headlessly without reading the emulated screen).
proc logLine(s: string) =
  cprintf("%s\n", s.cstring)
  svcOutputDebugString(s.cstring, cint(s.len))

# ---------------------------------------------------------------------------
# Raw-socket HTTP/1.1 POST, written in C to avoid sockaddr struct-layout risk.
# Returns the HTTP status code (e.g. 200), or a negative transport error code.
# ---------------------------------------------------------------------------
{.emit: """
#include <3ds.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

static int spike_http_post(const char* ip, int port, const char* path,
                           const char* body, int bodylen) {
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
    "POST %s HTTP/1.1\r\n"
    "Host: %s:%d\r\n"
    "Content-Type: application/x-protobuf\r\n"
    "Content-Length: %d\r\n"
    "Connection: close\r\n\r\n",
    path, ip, port, bodylen);
  if (send(fd, hdr, hlen, 0) < 0) { close(fd); return -3; }
  if (bodylen > 0 && send(fd, body, bodylen, 0) < 0) { close(fd); return -4; }

  char resp[256];
  int n = recv(fd, resp, sizeof(resp) - 1, 0);
  close(fd);
  if (n <= 0) return -5;
  resp[n] = 0;
  int code = 0;
  if (n > 12) sscanf(resp + 9, "%d", &code);  // skip "HTTP/1.1 "
  return code;
}
""".}

proc spikeHttpPost(ip: cstring; port: cint; path: cstring;
                   body: cstring; bodylen: cint): cint
  {.importc: "spike_http_post", nodecl.}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
proc main() =
  gfxInitDefault()
  consoleInit(GFX_TOP, nil)

  logLine("OBSERVY-SPIKE observy 3DS net spike (M0 rung 1)")

  # osGetTime sanity (validates the wall-clock source for later timestamp work).
  let ms1900 = osGetTime()
  let unixMs = ms1900 - 2_208_988_800_000'u64  # 1900 -> 1970 epoch offset
  logLine("OBSERVY-SPIKE osGetTime ms1900=" & $ms1900 & " unixMs=" & $unixMs)

  # SOC service init with a 0x1000-aligned 1 MiB buffer (do NOT free while open).
  let socBuf = cast[ptr uint32](memalign(csize_t(SOC_ALIGN), csize_t(SOC_BUFFERSIZE)))
  if socBuf == nil:
    logLine("OBSERVY-SPIKE FAIL memalign soc buffer nil")
  else:
    let rc = socInit(socBuf, uint32(SOC_BUFFERSIZE))
    logLine("OBSERVY-SPIKE socInit rc=" & $rc)
    if rc == 0:
      let body = "ping-from-3ds"
      logLine("OBSERVY-SPIKE POST http://10.0.0.106:4318/v1/traces")
      let code = spikeHttpPost("10.0.0.106", cint(4318), "/v1/traces",
                               body.cstring, cint(body.len))
      if code > 0:
        logLine("OBSERVY-SPIKE RESULT http_status=" & $code & " RUNG1_PASS")
      else:
        logLine("OBSERVY-SPIKE RESULT transport_error=" & $code)
      discard socExit()

  logLine("OBSERVY-SPIKE done; press START to exit")
  while aptMainLoop():
    gspWaitForVBlank()
    gfxFlushBuffers()
    gfxSwapBuffers()
    hidScanInput()
    if (hidKeysDown() and KEY_START) != 0: break

  gfxExit()

main()
