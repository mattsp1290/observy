# 02 — Milestone 0: Networking spike (GO/NO-GO gate)

> ✅ **RESOLVED 2026-06-07: GO.** All three rungs passed on Azahar against the live
> collector. Rung 1 (raw socket → 400, collector answered), Rung 2 (real observy
> encoders → **200**), Rung 3 (`std/httpclient` fails `-d:ds3` on `AF_UNIX` →
> **Plan B: raw socket**, now scoped as the shared `~/git/http` library). Time
> source (`osGetTime` epoch) validated. Full write-up: `SPIKE-NOTES.md`.

**This is the gate. Everything in milestones 1–4 is contingent on this passing.**
Nobody has done socket I/O on the 3DS in any of the reference projects. We prove
it works — smallest rung first — before investing in library refactoring.

Do this work in a throwaway sandbox (a scratch dir or a `spike/` folder), **not**
by refactoring observy yet. The point is to de-risk, fast.

## The rungs (smallest provable step first)

### Rung 1 — Platform can talk to the collector at all (zero observy)

A bare Nim 3DS app that opens a raw BSD socket and POSTs a hardcoded body.

```nim
# Pseudocode — the shape, not final code.
import std/[posix]  # or direct {.importc.} of socket/connect/send/recv

const SOC_BUFSZ = 0x100000        # 1 MiB, must be 0x1000-aligned
var socBuf: ptr uint32            # memalign(0x1000, SOC_BUFSZ)

socInit(socBuf, SOC_BUFSZ)        # libctru — REQUIRED before any socket call
defer: socExit()
# NB: do NOT free socBuf while sockets are open (classic libctru gotcha).

let fd = socket(AF_INET, SOCK_STREAM, 0)
# sockaddr_in for 10.0.0.106:4318  — IP literal, NO DNS
connect(fd, ...)
let body = "hello"
let req = "POST /v1/traces HTTP/1.1\r\nHost: 10.0.0.106:4318\r\n" &
          "Content-Type: application/x-protobuf\r\n" &
          "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n" & body
send(fd, req)                     # then recv() the status line
close(fd)
```

**Pass criterion:** the 3DS reads back an HTTP status line from `10.0.0.106:4318`.
A `400`/`415` is still a PASS for rung 1 — it means bytes crossed the network and
the collector answered. (The body is garbage, so the collector rejecting it is
expected.) Connection refused / timeout / crash = the platform networking itself
isn't working yet; fix that before moving on.

Watch for, in order of likelihood:
- `socInit` buffer not 0x1000-aligned, or freed too early → connect fails/crashes.
- WiFi not associated / 3DS not on the LAN → timeout (this is a device setup
  issue, not code).
- `std/posix` socket bindings mismatching libctru's `sys/socket.h` subset → may
  need direct `{.importc, header: "<sys/socket.h>".}` declarations instead.

### Rung 2 — Real OTLP body from observy's encoders

Replace the hardcoded `body` with the output of observy's **portable core**
(Tier 1): build one `Span` with libctru-sourced timestamps, encode via
`protoEncodeTraceRequest(res, scope, @[span])`. Keep the raw socket from rung 1.

**Pass criterion:** the collector returns **HTTP 200** (full acceptance) — and
the trace shows up in the collector's debug/file exporter. This proves the
encoders compile and emit wire-correct protobuf on `arm-none-eabi`.

This rung also validates **B6 (timestamps)**: see `04-platform-abstraction.md`.
If the timestamp epoch is wrong, the collector may still 200 but the data lands
in the wrong time window — verify the emitted `startTimeUnixNano` against a known
wall-clock reading.

### Rung 3 — Decide the transport: httpclient vs. raw-socket fallback

Only now, attempt to compile + run observy's real transport
(`exporter_http.nim` → `std/httpclient`) on the 3DS, pointed at
`10.0.0.106:4318`.

- **If `std/httpclient` compiles and a `record()` call returns 200 → GO with
  httpclient.** This is the clean outcome: observy's existing transport is reused
  verbatim, nothing in `exporter_http.nim` needs a 3DS branch.
- **If it won't compile or crashes at runtime → GO with Plan B (raw socket).**
  Rung 1 already proved raw sockets work; Plan B is just promoting that ~40-line
  POST into a real module. The encoders (Tier 1) are identical either way.

## Plan B — raw-socket transport (CHOSEN) → the `~/git/http` library

> Rung 3 chose Plan B. Rather than inline a raw socket in observy, the transport
> is being built as a **shared, reusable library** `~/git/http` (a
> `std/httpclient`-compatible subset over raw BSD sockets for 3DS/Vita/Dreamcast),
> consumed by both observy and doggy. Request:
> `~/.agents/projects/http/requests/2026-06-07-stdhttpclient-subset-retro-consoles.md`.
> The proven spike C (`spike/trace_spike_3ds.nim`'s `spike_post`) is the reference
> implementation. M1's transport work becomes "consume `~/git/http`" (gate
> `import std/httpclient` behind `when not defined(ds3)`; `when defined(ds3): import http`).
> The inline sketch below remains the fallback if the library isn't ready.

A minimal `exporter_socket_3ds.nim` (only compiled `when defined(ds3)`), exposing
the **same surface** the synchronous `record()` path needs:

```nim
proc sendRequest3ds(host: string; port: int; path: string;
                    payload: seq[byte]; contentType: string): ExportResponse
```

- BSD socket → `connect` to the IP → write a fixed HTTP/1.1 POST → read the
  response → parse status code, `Content-Type`, body, `Retry-After` into the
  existing `ExportResponse` (`exporter_http.nim:34-42`).
- `Connection: close` (no keep-alive; sidesteps the socket-reuse hazard recorded
  in the project memory and `retry.nim`'s header).
- No DNS (IP literal), no TLS, no gzip, no chunked encoding (collector returns a
  fixed-length body for OTLP).
- Reuses `bytesToBody`/partial-success decoding from `exporter_http.nim` as-is —
  those are pure and portable.

The seam: have the synchronous `record()` overloads call `sendSignal`, and let
`sendSignal`/`sendRequest` dispatch to the socket implementation
`when defined(ds3)`. This keeps the public API (`record`, `newOtlpExporter`)
identical across desktop and 3DS.

> ⚠️ **In-proc `when` dispatch is not enough for Plan B.** `exporter_http.nim:8`
> does `import std/httpclient` at **file scope**, and `src/observy.nim:28`
> imports/exports `exporter_http` **unconditionally**. If httpclient doesn't
> compile on 3DS, that file-level import fails before any proc body runs — so
> `nim check -d:ds3 src/observy.nim` can never pass while the import is
> ungated. Plan B therefore **requires gating the import itself**: wrap
> `import std/httpclient` and the httpclient-using procs in `exporter_http.nim`
> behind `when not defined(ds3)`, and provide the `ds3` transport (socket POST)
> behind `when defined(ds3)`, with `sendRequest`/`sendSignal`/`ExportResponse`
> as the shared surface both branches implement. This import gating is detailed
> in `03-build-toolchain.md` §4 and is part of Milestone 1, not optional.

## Spike deliverables (what "Milestone 0 done" means)

- [ ] Rung 1 PASS: a `.3dsx` that gets an HTTP status line from the collector.
- [ ] Rung 2 PASS: collector returns 200 for an observy-encoded trace, visible in
      the collector debug exporter, with a sane timestamp.
- [ ] Rung 3 decision recorded: **httpclient GO** or **Plan B GO**, with the
      compile/runtime evidence that drove it.
- [ ] B2 confirmed: the portable core compiles clean under `--mm:arc`.
- [ ] A short `SPIKE-NOTES.md` capturing what worked, the `socInit` buffer size
      used, and any `{.importc.}` declarations needed. **Write it to
      `.agents/plans/3ds-support/SPIKE-NOTES.md`** (a durable location, not the
      throwaway spike sandbox) so the decision survives cleanup.

> If rung 1 cannot pass on hardware after reasonable effort (device on LAN,
> aligned buffer, correct sockaddr), **stop and escalate** — that is the NO-GO
> signal, and it means 3DS networking needs deeper libctru work than this plan
> scopes.
