# 04 — Milestone 2: Platform abstraction (time, memory, threads)

*Contingent on Milestone 0.* The seams that let the same observy API behave
correctly on the 3DS. The big one is **time** — it's a Datadog correctness gate,
not a nicety.

## Time: the Datadog gate (B6)

### The problem

1. **observy does not auto-stamp.** Span/log/metric timestamps are user-set
   `uint64` Unix-nanoseconds fields (`traces.nim:64-65` `startTimeUnixNano` /
   `endTimeUnixNano`, `timeUnixNano`, etc.). On 3DS the *consumer* must supply
   them.
2. **`clock_gettime` / `getMonoTime` / `getTime` crash on 3DS** (they link via the
   `librt.a` stub but the syscall is empty — per project memory and
   `clckr/stubs/README.md`). So we cannot use `std/times` at runtime.
3. **Datadog drops or misplaces telemetry whose timestamp is too far past/future.**
   The 3DS wall clock comes from its RTC; if the system clock is unset or the
   epoch conversion is wrong, traces silently vanish or land in the wrong window
   even though the collector returns 200.

### The solution

Provide a 3DS time source backed by libctru, exposing **Unix nanoseconds**:

- **Wall clock (for timestamps):** libctru `osGetTime()` returns milliseconds
  since 1900-01-01. Convert to Unix epoch (subtract the 1900→1970 offset =
  `2_208_988_800_000` ms) then `* 1_000_000` to nanoseconds. Alternatively use
  newlib `time()`/`gettimeofday()` **iff** the spike confirms libctru hooks them
  to the RTC without going through `clock_gettime`. **Pick whichever the spike
  proves correct against a known reference reading.**
- **Monotonic (for durations, if needed):** `svcGetSystemTick()` /
  `SYSCLOCK_ARM11` for elapsed time without epoch concerns — useful to compute a
  span's `endTimeUnixNano = startTimeUnixNano + elapsedNanos`.
- **Sleep (only if retry is added later):** `svcSleepThread(nanos)` instead of
  `std/os sleep` (which routes through `nanosleep`).

Ship this as a small helper, `when defined(ds3)`, e.g.
`src/observy/time_3ds.nim`:

```nim
proc nowUnixNano*(): uint64   ## wall clock → Unix nanoseconds (osGetTime-based)
proc monoNanos*():  uint64    ## svcGetSystemTick-based monotonic, for durations
```

Document loudly: **the consumer must set the 3DS RTC** (or the build/runtime must
ensure a sane clock) or Datadog will reject the data. Add this to the example and
the verification checklist.

### Spike check (do this in Milestone 0 rung 2)

Emit one span, read back its `startTimeUnixNano`, and compare to the real
wall-clock time. Off by ~70 years → you used the 1900 epoch without converting.
Off by hours → timezone/RTC. Zero/garbage → wrong syscall.

## Memory management: arc not orc (B2)

- 3DS builds `--mm:arc`; observy mandates `orc` today.
- observy's data model is value types + `seq`/`string`; no intentional reference
  cycles. `arc` (ref-counting, no cycle collector) should be sufficient and is
  what every reference 3DS project uses.
- `--define:useMalloc --define:nimAllocPagesViaMalloc` route Nim's allocator
  through newlib `malloc` (no `mmap` on 3DS). Already in the `config.nims` `ds3`
  branch (`03-build-toolchain.md`).
- **Verify in the spike:** no leaks/cycles in a long-running emit loop. If a cycle
  is ever introduced, `arc` would leak it (not crash) — acceptable for the
  short-lived export use case, but note it.

## Threads: none (B1)

- `batch.nim` (worker thread + `system.Channel`) is **excluded** on 3DS via
  `when not defined(ds3)` (`03-build-toolchain.md` §4).
- 3DS uses the **synchronous** `record(exporter, resource, scope, items)` path
  exclusively. The app emits on its main loop; each `record()` is one blocking
  HTTP POST.
- `retry.nim`'s `{.threadvar.}` (`jitterRng`) compiles as a plain global under
  `--threads:off`. The module imports fine; just don't call its default hooks.

## Retry: deferred (B5)

`retry.nim`'s `defaultRetryHooks()` is **all-or-nothing** on 3DS — *every* hook
hits a crashing syscall:

| Hook       | Default impl                | 3DS verdict |
| ---------- | --------------------------- | ----------- |
| `nowSec`   | `getMonoTime()`             | crashes (clock_gettime) |
| `nowWall`  | `getTime()`                 | crashes (clock_gettime) |
| `sleepMs`  | `sleep(ms)`                 | crashes/no-op (nanosleep) |
| `jitter`   | `defaultJitter`→`initRand()`| `initRand()` reads `std/sysrand.urandom`; if unavailable on 3DS it calls `quit()` (process abort) |

So either override **all four** with libctru-backed implementations, or **never
call `retryLoop`**. **MVP: never call it** — use single-attempt `record()`. A
later milestone can add `ds3RetryHooks()` (using `monoNanos`/`nowUnixNano`/
`svcSleepThread` and a fixed or tick-seeded RNG) if on-device retry proves
necessary. Don't let retry expand the spike's surface.

## Milestone 2 deliverables

- [ ] `time_3ds.nim` with `nowUnixNano()` (+ `monoNanos()` if used), epoch-correct
      (validated against a wall-clock reference in the spike).
- [ ] arc confirmed: portable core + transport run leak-free in an emit loop.
- [ ] No `defaultRetryHooks()` / `std/times` runtime call reachable from the 3DS
      `record()` path (grep + `nim check -d:ds3`).
- [ ] Doc note: "set the 3DS RTC or Datadog rejects the data."
