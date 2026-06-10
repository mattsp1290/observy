# 04 — M2: Platform abstraction (time)

The only new platform module is the time source. Memory/threads/retry were
settled architecturally in `01-architecture-and-constraints.md` (same gates
as 3DS); this file specifies `time_vita.nim`.

## `src/observy/time_vita.nim` (new, mirrors `time_3ds.nim`)

Contract identical to `time_3ds.nim`:

- Compiled only under `-d:vita`; the `else` branch is
  `{.error: "observy/time_vita is Vita-only (-d:vita); use std/times on desktop".}`
- Exports `nowUnixMillis*(): uint64` and `nowUnixNano*(): uint64` (the OTLP
  timestamp unit). Keep the API surface byte-compatible with `time_3ds.nim`
  so example code differs only in the import.
- observy never calls it; consumers stamp their own signals.

The **implementation** is whatever M0 rung 3 validated:

### If newlib POSIX time works (preferred — least code)

```nim
when defined(vita):
  import std/posix
  proc nowUnixNano*(): uint64 =
    var ts: Timespec
    if clock_gettime(CLOCK_REALTIME, ts) != 0:
      raise newException(OSError, "clock_gettime(CLOCK_REALTIME) failed")
    ts.tv_sec.uint64 * 1_000_000_000'u64 + ts.tv_nsec.uint64
  proc nowUnixMillis*(): uint64 = nowUnixNano() div 1_000_000'u64
```

Document in the module header *why* we still wrap it (uniform console
contract; SPIKE-NOTES reference for the runtime proof; desktop import trap).

### If only sceRtc works

```nim
when defined(vita):
  type SceRtcTick {.importc: "SceRtcTick", header: "<psp2/rtc.h>", bycopy.} = object
    tick: uint64
  proc sceRtcGetCurrentTick(t: ptr SceRtcTick): cint
    {.importc, header: "<psp2/rtc.h>".}

  const epochOffsetMicros = 62_135_596_800_000_000'u64
    ## Microseconds between 0001-01-01 and the Unix epoch (1970-01-01):
    ## 62,135,596,800 s × 1e6. MUST be re-verified on device in M0 rung 3
    ## before this constant is trusted (the 3DS plan's B6 lesson: a wrong
    ## epoch silently corrupts Datadog).

  proc nowUnixMicros(): uint64 =
    var t: SceRtcTick
    if sceRtcGetCurrentTick(addr t) < 0:
      raise newException(OSError, "sceRtcGetCurrentTick failed")
    t.tick - epochOffsetMicros

  proc nowUnixNano*(): uint64 = nowUnixMicros() * 1_000'u64
  proc nowUnixMillis*(): uint64 = nowUnixMicros() div 1_000'u64
```

Plus `-lSceRtc_stub` in `nim_vita.cfg`, and a check whether the RTC
sysmodule needs explicit loading (record in SPIKE-NOTES either way).

> Signatures verified against the installed headers 2026-06-10:
> `int sceRtcGetCurrentTick(SceRtcTick *tick)` in `psp2/rtc.h`;
> `SceRtcTick = { SceUInt64 tick }` in `psp2common/kernel/rtc.h` (included
> by `psp2/rtc.h`, so the importc header above is fine);
> `libSceRtc_stub.a` is present in the SDK lib dir. What the headers do
> NOT document is the tick **unit and epoch** — supporting signals:
> `sceRtcGetCurrentTickUtc` is a macro alias of `sceRtcGetCurrentTick`
> (consistent with a UTC tick), and `sceRtcGetTickResolution()` exists —
> the M0 spike should call it to confirm µs on device before the epoch
> constant is trusted.

## UTC handling

The Vita RTC may be set to local time (the 3DS/Azahar combo was; Datadog
needs UTC-ish stamps). Decide from M0 rung 3 evidence:

- If the chosen source returns true UTC: nothing to do, note it.
- If it returns local time: mirror the 3DS solution — a compile-time
  `ObservyVitaUtcOffsetSec` define applied **in the example app**
  (`05-example-and-verification.md`), not in `time_vita.nim`. The library
  helper stays a raw clock reading.

## Retry hooks: explicitly out

No `defaultRetryHooks()` / `std/times` runtime call may be reachable from
the Vita `record()` path — same rule and same verification as 3DS M2
(`.agents/plans/3ds-support/04-platform-abstraction.md`). A
`vitaRetryHooks()` (clock from `time_vita`, sleep via `sceKernelDelayThread`)
is a deferred follow-up, filed as backlog, only if on-device retry proves
necessary.

## Acceptance (M2 done)

- [ ] `time_vita.nim` lands with the M0-validated source; desktop import
      fails with the explicit `{.error.}`.
- [ ] Timestamps validated against a wall-clock reference on device
      (today's date, correct hour in UTC).
- [ ] `nim check -d:vita --path:../http/src src/observy.nim` green.
- [ ] Grep-proof: no `std/times` / `std/monotimes` call reachable from the
      Vita `record()` path (batch + retry hooks gated out).
- [ ] Doc line: "set the Vita clock correctly or Datadog rejects the data"
      (README or module doc).
