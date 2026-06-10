# 01 — Architecture & constraints

What has to change in observy, what must not change, and the complete
inventory of platform gates.

## Invariants (do not break these)

1. **Desktop branch stays byte-equivalent.** `config.nims:3-4` is explicit:
   the desktop path (`--mm:orc --threads:on`) carries the entire test suite.
   Every change in this plan is additive behind `defined(vita)`.
2. **The `ds3` build keeps working.** `nim check -d:ds3 --path:../http/src
   src/observy.nim` and `scripts/build_3ds.sh examples/observy_3ds.nim
   observy_3ds` must stay green after every milestone.
3. **observy stays zero-dependency.** The Vita path adds no nimble deps;
   `~/git/http` is supplied via `--path` exactly as the 3DS build does
   (`config.nims:11-15`, `OBSERVY_HTTP_SRC` env override).
4. **observy does not auto-timestamp.** Consumers supply `uint64`
   Unix-nanosecond fields; `time_vita.nim` is a helper for them, not a hook
   the library calls (same contract as `time_3ds.nim`).

## Tier 1 — portable core: no expected work

`anyvalue.nim`, `proto.nim`, `json_encode.nim`, `resource.nim`, `traces.nim`,
`metrics.nim`, `logs.nim`, `config.nim`, plus the request builders in
`observy.nim` are pure Nim, no I/O, already proven under
`--mm:arc --threads:off` by the 3DS port (M0 rung 2, M1). They should compile
for Vita unchanged. If they don't, that's a finding to record in
`SPIKE-NOTES.md`, not something to pre-engineer around.

## Tier 2 — the platform seams

### Complete `defined(ds3)` gate inventory (each becomes `defined(ds3) or defined(vita)`)

| File:line | What it gates | Vita action |
| --------- | ------------- | ----------- |
| `config.nims:10` | `--path` to `~/git/http`, `cpu:arm`, `os:linux`, `arc`, `threads:off`, `useMalloc`, `nimAllocPagesViaMalloc`, `noSignalHandler`, `opt:size` | Extend condition. Flags are identical for Vita; `OBSERVY_HTTP_SRC` env override reused as-is. |
| `src/observy.nim:38` | `import observy/batch; export batch` (threads/Channel) | Extend to `when not (defined(ds3) or defined(vita))`. |
| `src/observy.nim:128` | the three `record(BatchProcessor, T)` overloads | Same extension. |
| `src/observy.nim:18` | docstring describing the 3DS build | Document the `-d:vita` build path alongside. |
| `src/observy/exporter_http.nim:15` | `import http` vs `std/httpclient` | Extend condition; `~/git/http` itself then picks `sockets_vita.nim` because `-d:vita` is in scope. Update the seam comment (lines 9-14) to mention Vita. |
| `src/observy/exporter_http.nim:82` | reject `https://` endpoints | Extend; reword message so it names the actual platform (or says "on this console target"). |
| `src/observy/exporter_http.nim:106` | `httpInit()` in `newOtlpHttpExporter` | Extend. On Vita this runs the full sceNet bring-up (1 MiB pool alloc, module load, `sceNetInit`, `sceNetCtlInit`) — see transport notes below. |
| `src/observy/exporter_http.nim:118` | `httpShutdown()` in `close()` | Extend. |
| `examples/nim.cfg:1` | `@if not ds3:` keeps examples off orc/threads | Must also exclude vita. Spelling **confirmed**: `@if not ds3 and not vita:` parses and evaluates correctly on Nim 2.2.10 (tested 2026-06-10: marker define set with no flags, unset under `-d:vita` and `-d:ds3`). |
| `src/observy/time_3ds.nim` | 3DS-only time module | Not modified. Sibling `time_vita.nim` created (see `04-platform-abstraction.md`). |
| `examples/README.md` | documents the 3DS example + cfg note | Add an `observy_vita.nim` row (build command, `NIMFLAGS_VITA` / `ObservyVitaUtcOffsetSec` hints) and extend the nim.cfg note to mention vita (M3). |

Nothing else in `src/` references `ds3` (verified by grep 2026-06-10; the
`spike/` artifacts from the 3DS port are intentionally untouched).

### Transport: `~/git/http` Vita seam (exists, unproven at runtime)

`/Users/punk1290/git/http/src/http.nim:21-26`:

```nim
when defined(ds3):
  import ./http/sockets_3ds
elif defined(vita):
  import ./http/sockets_vita
else:
  import ./http/sockets_posix
```

`sockets_vita.nim` facts that matter to observy:

- `spNetInit()` (reached via observy's `httpInit()` call) mallocs a **1 MiB**
  net pool, loads `SCE_SYSMODULE_NET`, calls `sceNetInit` + `sceNetCtlInit`;
  refcounted, raises `HttpRequestError` with the SCE error code on failure.
  `spNetShutdown()` tears all of it down. So `newOtlpHttpExporter()` /
  `close()` bracket the console's network lifecycle on Vita exactly as they
  do on 3DS — **the example app must not also init sceNet itself.**
- Sockets go through VitaSDK newlib's POSIX layer (`std/posix`:
  `getaddrinfo` (+`AI_NUMERICHOST` for IP literals), non-blocking `connect`
  + `poll`, `send`/`recv` loops). All compile-only verified.
- Timeouts use `clock_gettime(CLOCK_MONOTONIC)` (`sockets_vita.nim:36-40`) —
  if that crashes or returns garbage on device, every timed request breaks.
  This is an explicit M0 rung.
- `sockets_vita.nim` never queries connection state — `sceNetCtlInit`
  succeeds even with WiFi off, and the first `getaddrinfo`/`connect` then
  fails with an opaque error indistinguishable from "transport broken". The
  spike and the example must breadcrumb `sceNetCtlInetGetState`
  (`<psp2/net/netctl.h>`; state 3 = IP obtained) before the first POST to
  disambiguate (see `02-networking-spike.md` rung 1).
- HTTP/1.1, `Connection: close` per request, no TLS, no chunked responses —
  same contract the 3DS path already lives with.

If the spike finds bugs in `sockets_vita.nim`, **fix them in `~/git/http`**
(its repo, its tests), not by forking transport code into observy.

### Threading

Vita genuinely has threads (sceKernel + newlib pthread), unlike the 3DS.
MVP ignores this: `--threads:off`, synchronous `record()` only, batch module
gated out. Revisit only if a real consumer needs background export
(`06-milestones.md`, deferred section).

### Memory

Same profile as 3DS: `arc` (value-type data model, no cycles expected),
`useMalloc` + `nimAllocPagesViaMalloc` (newlib, no mmap), `opt:size`.
The Vita has ~512 MB — far roomier than the 3DS — so memory is not a risk
line-item; the flags exist for newlib-correctness, not headroom.

### Retry / std/times reachability

`retry.nim`'s `defaultRetryHooks()` uses `std/times`/`std/monotimes`/
`os.sleep`. On 3DS these link (via stubs) but crash at runtime, so the rule
is "never reachable from the console `record()` path". Keep the same rule
for Vita MVP **even if** the spike shows `clock_gettime` works — proving the
full hook set (sleep, jitter) is not MVP work. Record what the spike learns;
a working `vitaRetryHooks()` is a cheap follow-up if wanted.

## Risks

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| `sockets_vita.nim` fails at runtime (sceNet init, posix layer, poll) | Medium | High | M0 rung 1 on hardware before anything else; fixes land in `~/git/http` |
| `clock_gettime(CLOCK_MONOTONIC)` broken on device → timeouts unusable | Low-Med | High | Explicit M0 rung; fallback: rewrite `monoMs()` over `sceKernelGetProcessTimeWide` in `~/git/http` |
| Wall-clock source wrong epoch → Datadog silently drops | Medium | High | M0 rung validates chosen source against a known reference (3DS plan's B6 pattern) |
| Vita not reachable / WiFi power-save stalls long requests | Low-Med | Medium | Collector on same LAN; result file captures partial progress per signal |
| Linker stub set wrong (missing `-lSce*_stub`) | Medium | Low | Iterate on link errors in M1; boxy's cfg is the known-good superset |
| Vita3K can't do networking | High | Low (hardware is the target) | Decision 6: emulator is bonus coverage only |
