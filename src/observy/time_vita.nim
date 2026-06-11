## PlayStation Vita time source (M2).
##
## observy does NOT auto-stamp telemetry — Span/LogRecord/Metric timestamps are
## user-set `uint64` Unix-nanosecond fields. On Vita the consumer should source
## them from this helper for the same uniform console contract as time_3ds.nim.
##
## M0 validated VitaSDK newlib `clock_gettime(CLOCK_REALTIME)` on real hardware:
## `.agents/plans/vita-support/SPIKE-NOTES.md` records a correct UTC reading and
## an `sceRtcGetCurrentTick` fallback reading from the same run. Set the Vita
## clock correctly before emitting telemetry; Datadog rejects or misplaces data
## with wrong-epoch timestamps.
##
## Compiled only for `-d:vita`; importing it on desktop is a no-op-with-error to
## catch accidental host use (use std/times on desktop).

when defined(vita):
  import std/posix

  proc nowUnixNano*(): uint64 =
    ## Current wall-clock time in Unix nanoseconds — the unit OTLP timestamp
    ## fields (startTimeUnixNano / timeUnixNano / ...) expect.
    var ts: Timespec
    if clock_gettime(CLOCK_REALTIME, ts) != 0:
      raise newException(OSError, "clock_gettime(CLOCK_REALTIME) failed")
    ts.tv_sec.uint64 * 1_000_000_000'u64 + ts.tv_nsec.uint64

  proc nowUnixMillis*(): uint64 =
    ## Current wall-clock time in Unix milliseconds.
    nowUnixNano() div 1_000_000'u64
else:
  {.error: "observy/time_vita is Vita-only (-d:vita); use std/times on desktop".}
