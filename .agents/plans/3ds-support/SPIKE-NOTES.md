# M0 SPIKE-NOTES — 3DS networking gate (GO)

**Date:** 2026-06-07 · **Verdict: GO.** All three rungs passed. The 3DS can run
observy's encoders and POST OTLP to the LAN collector. Transport decision: **the
raw-socket path (Plan B), realized as the new `~/git/http` library** — `std/httpclient`
is empirically unusable on 3DS.

## Environment

- devkitARM r66 (`arm-none-eabi-gcc` 15.1.0), libctru at `/opt/devkitpro/libctru`.
- Nim 2.2.10. Build mode: `-d:ds3 -d:release` → `--mm:arc --threads:off`
  `--define:useMalloc --define:nimAllocPagesViaMalloc --define:noSignalHandler
  --opt:size` (from `config.nims` `when defined(ds3)`).
- Emulator: Azahar (`/Applications/Azahar.app`). Virtual SD at
  `~/Library/Application Support/Azahar/sdmc/`.
- Collector: `http://10.0.0.106:4318` (up — returns 400 to a junk body from the host).

## Rung 1 — platform can talk to the collector (PASS)

`spike/net_spike_3ds.nim`: bare app, `socInit` + raw C `AF_INET`/`SOCK_STREAM`
POST. On Azahar (confirmed on-screen + via `svcOutputDebugString`):

```
OBSERVY-SPIKE socInit rc=0
OBSERVY-SPIKE RESULT http_status=400 RUNG1_PASS
```

400 = collector answered (junk body rejected) → bytes crossed the LAN. Also
validated the time source: `osGetTime()` − `2_208_988_800_000` ms (1900→1970)
gave a unix time matching today (2026-06-07) — **B6 timestamp epoch is correct.**

## Rung 2 — observy's real encoders → 200 (PASS)

`spike/trace_spike_3ds.nim`: imports `observy/{anyvalue,proto,resource,traces}`
(the Tier-1 portable core), builds a real `Span`/`Resource`/`InstrumentationScope`,
encodes with the actual `protoEncodeSpan`/`protoEncode`, POSTs via raw socket,
writes result to `sdmc:/observy_spike_result.txt`. Read back headlessly:

```
http_status=200
RUNG2_PASS
encoded_bytes=155
resp_first_line=HTTP/1.1 200 OK
```

→ **The encoder core compiles for arm-none-eabi under arc and emits wire-correct
OTLP protobuf the collector fully accepts.** Confirms B2 (arc) for Tier-1.

## Rung 3 — transport decision: Plan B (raw socket), NOT std/httpclient (PASS)

`import std/httpclient` **fails to compile** for `-d:ds3`. It pulls
`std/nativesockets` → `std/asyncdispatch`/`asyncfutures`; first hard error:

```
@pnativesockets.nim.c:32:48: error: 'AF_UNIX' undeclared
```

libctru's `sys/socket.h` is a subset (no Unix-domain sockets; async stack
unportable). Raw `AF_INET` sockets work (rungs 1–2 both got real responses).

**Decision: raw-socket transport.** Rather than inline it in observy, it becomes
the new shared library `~/git/http` (request filed:
`~/.agents/projects/http/requests/2026-06-07-stdhttpclient-subset-retro-consoles.md`)
— a `std/httpclient`-compatible subset over raw BSD sockets for 3DS/Vita/Dreamcast,
reused by observy and doggy. `std/httpcore` is portable and reused verbatim;
only the socket transport is replaced.

## Key technical facts (carry into M1+)

- `socInit(u32* buf, u32 size)` with `buf` from `memalign(0x1000, 0x100000)` (1 MiB).
  Buffer must stay alive while sockets are open. `socExit()` on teardown. rc 0 = ok.
- Wall clock: `osGetTime()` → ms since 1900; subtract `2_208_988_800_000`, ×1e6 → unix ns.
- Per-file `<name>.nim.cfg` (auto-discovered) carries the devkitARM toolchain;
  `config.nims` carries mm/threads/opt — no root `nim.cfg` dance needed for single files.
- Link stubs required: `stubs/libdl.a`, `stubs/librt.a` (empty, GNU `arm-none-eabi-ar`).
- Headless verification mechanism that works on Azahar AND hardware: write a result
  file to the SD root (`writeFile("name.txt", ...)` → sdmc root) and read it back.
- `svcOutputDebugString` surfaces in Azahar's log only if `log_filter` includes
  `Debug.Emulated` (default `*:Info` hides it) — the SD-file path is more reliable.

## Spike artifacts (in `spike/`, throwaway scaffolding)

- `net_spike_3ds.nim` (+`.nim.cfg`) — rung 1.
- `trace_spike_3ds.nim` (+`.nim.cfg`) — rung 2 (real encoders).
- `build_spike.sh` — `nim c -d:ds3` → `3dsxtool` → `.3dsx`.

## Implication for the plan

M1's transport work is no longer "inline a raw socket in `exporter_http.nim`" —
it's "consume `~/git/http`". Until that library exists, observy is unblocked on
everything *except* the live 3DS send (encoders, build, config, time all proven).
See the updated Rung-3/Plan-B notes in `02-networking-spike.md`.
