# 01 — Architecture & constraints

Inventory of what in observy is portable to the 3DS, what blocks the port, and
why. This grounds every later milestone. File/line references are from the repo
state at planning time.

## observy as it stands

- Pure-Nim OTLP exporter. **Zero Nimble dependencies** (`observy.nimble`);
  OpenSSL only when compiled `-d:ssl` for HTTPS.
- Two emit paths (`src/observy.nim`):
  - **Synchronous:** `record(exporter, resource, scope, items) -> ExportResponse`
    — encode + one HTTP POST, single attempt, **no threads**. (`observy.nim:141-183`)
  - **Async:** `record(p: var BatchProcessor[T], item)` → `p.submit` — worker
    thread + `system.Channel`. (`observy.nim:120-130`, `batch.nim`)
- Transport is `std/httpclient` over HTTP/1.1, in **one file**
  (`exporter_http.nim`). protobuf → `application/x-protobuf`, JSON →
  `application/json`. gRPC explicitly out of scope (`exporter_http.nim:7`).
- `config.nims` currently **mandates `--mm:orc --threads:on`** for all consumers.

## The 3DS target environment (from the reference projects)

All four reference repos build the 3DS with the same shape (see
`clckr/config.nims`, `raylib/config.nims`):

```
--cpu:arm --os:linux
--mm:arc              # NOT orc
--threads:off        # no pthreads on 3DS
--define:useMalloc           # newlib has no mmap; Nim's default allocator needs it
--define:nimAllocPagesViaMalloc
--define:noSignalHandler     # no POSIX signals
--opt:size                   # memory-constrained device
```

Toolchain is devkitARM (`arm-none-eabi-gcc`) + libctru, paths in a
`nim_3ds.cfg` that the build script copies to `nim.cfg` (Nim has no `--config`
flag; auto-discovery is the only mechanism). Link stubs are required for
libraries Nim references but the 3DS lacks: `libdl.a` (Nim emits `-ldl` for
`--os:linux`) and `librt.a` (`std/times` pulls `-lrt`). **The stubs satisfy the
linker but the underlying syscalls crash at runtime** — see the project memory
and `clckr/stubs/README.md`.

## Blocker matrix

| # | Blocker | Where | Severity | Resolution |
|---|---------|-------|----------|------------|
| B1 | `--threads:on` mandated; 3DS is `--threads:off` | `config.nims`; `batch.nim` uses `Thread`/`Channel` | **Hard** | Conditionalize `config.nims`; gate `batch.nim` + BatchProcessor `record` overloads + `import/export batch` behind `when not defined(ds3)`. 3DS uses synchronous `record()` only. |
| B2 | `--mm:orc` mandated; 3DS uses `--mm:arc` | `config.nims` | Medium | Switch to `arc` on `ds3`. observy's types are value types/seqs with no reference cycles → arc (no cycle collector) is sufficient. **Verify in spike.** |
| B3 | `std/httpclient` → `std/net` untested on 3DS | `exporter_http.nim:8` | **Hard / unknown** | Milestone 0 spike. Fallback: raw-socket POST (`02-networking-spike.md`). |
| B4 | SOC service not initialized | (no code yet) | **Hard** | New `net_3ds` bootstrap: `socInit()` w/ 0x1000-aligned buffer before any socket; `socExit()` after. |
| B5 | `getMonoTime()` / `getTime()` / `sleep()` hit crashing syscalls | `retry.nim:96-102`, `batch.nim:60,107` | **Hard at runtime** | `batch.nim` already excluded (B1). `retry.nim` defaults must never be *called* on 3DS — MVP skips retry; later, inject libctru-backed hooks. Module still *compiles* (imports are fine; the syscalls only crash when executed). |
| B6 | Wall-clock timestamps for spans/logs/metrics | user-set `*UnixNano` fields (`traces.nim:64-65`, etc.) | **Hard for correctness** | observy does **not** auto-stamp — the consumer supplies `uint64` Unix nanos. On 3DS those must come from a libctru time source with a *correct epoch* (Datadog drops/misplaces telemetry with wrong timestamps). See `04-platform-abstraction.md`. |
| B7 | gzip links libz | `gzip.nim`, gated `-d:observyGzip` | Low | Don't define `observyGzip` on 3DS. |
| B8 | TLS links OpenSSL | `-d:ssl` | Low | Plaintext `http://` only; don't define `ssl`. |

### Key insight on B5/B6

`retry.nim` and `std/times` **compile** fine on the 3DS (the `librt.a` stub
satisfies `-lrt` at link time). The danger is purely at runtime: calling
`getMonoTime`/`getTime`/`clock_gettime` crashes. So:

- The library can keep importing `std/times` / `std/monotimes`.
- The 3DS code path must simply **never call** `defaultRetryHooks()` or anything
  that reaches those syscalls. MVP achieves this by using single-attempt
  `record()` (no retry loop) and by the consumer sourcing timestamps from libctru.

## What is portable unchanged (Tier 1)

Confirmed pure / no I/O, expected to build under `arc/threads:off`:

- `anyvalue.nim`, `proto.nim`, `json_encode.nim`, `resource.nim`
- `traces.nim`, `metrics.nim`, `logs.nim` (value types + encoders)
- The request builders in `observy.nim` (`protoEncodeTraceRequest`, etc.)

These are the deliverable's backbone. The spike (Milestone 0) confirms they
compile for `arm-none-eabi` and produce byte-identical output to desktop (the
existing proto/JSON fixtures in `tests/fixtures/` are the oracle).

## Conditional-compilation surface (the complete list)

The umbrella `src/observy.nim` imports everything unconditionally. To build on
3DS, these must move behind `when not defined(ds3)`:

1. `import observy/batch; export batch` (`observy.nim:30`)
2. The three `record(p: var BatchProcessor[T], ...)` overloads
   (`observy.nim:120-130`) — they reference `BatchProcessor`.

Everything else in the umbrella's unconditional imports
(`anyvalue/proto/json_encode/resource/traces/metrics/logs/config/exporter_http/retry`)
must be confirmed during the spike to **not** pull `threads`/`Channel`
transitively. `retry.nim` uses `{.threadvar.}` — under `--threads:off` Nim
treats a threadvar as an ordinary global, so it compiles; verify.

> ⚠️ Grounding note: the file/line numbers above are a snapshot. Re-grep before
> editing — `grep -rn "BatchProcessor\|import observy/batch" src/observy.nim`.
