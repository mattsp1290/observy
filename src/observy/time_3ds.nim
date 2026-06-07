## Nintendo 3DS time source (M2).
##
## observy does NOT auto-stamp telemetry — Span/LogRecord/Metric timestamps are
## user-set `uint64` Unix-nanosecond fields. On the 3DS the consumer must supply
## them from a libctru source, because `std/times` (getTime / getMonoTime →
## clock_gettime) links via the librt stub but CRASHES at runtime on device.
##
## `osGetTime()` (libctru) returns milliseconds since 1900-01-01; this converts
## to Unix nanoseconds. Datadog drops/misplaces telemetry with a wrong-epoch
## timestamp, so the 3DS RTC must be set correctly (validated in the M0 spike:
## the conversion below produced today's date).
##
## Compiled only for `-d:ds3`; importing it on desktop is a no-op-with-error to
## catch accidental host use (use std/times on desktop).

when defined(ds3):
  proc osGetTime(): uint64 {.importc, header: "<3ds.h>".}
    ## libctru: milliseconds since 1st Jan 1900 00:00.

  const epochOffsetMs = 2_208_988_800_000'u64
    ## Milliseconds between 1900-01-01 and the Unix epoch (1970-01-01).
    ## = 2_208_988_800 seconds × 1000. Verified against a known reference in M0.

  proc nowUnixMillis*(): uint64 =
    ## Current wall-clock time in Unix milliseconds (libctru osGetTime).
    osGetTime() - epochOffsetMs

  proc nowUnixNano*(): uint64 =
    ## Current wall-clock time in Unix nanoseconds — the unit OTLP timestamp
    ## fields (startTimeUnixNano / timeUnixNano / ...) expect.
    nowUnixMillis() * 1_000_000'u64
else:
  {.error: "observy/time_3ds is 3DS-only (-d:ds3); use std/times on desktop".}
