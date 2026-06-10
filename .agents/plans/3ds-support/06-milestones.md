# 06 — Milestones & task breakdown

> **Status (2026-06-09, branch `feat/3ds-support`):**
> - **M0 — DONE (GO).** Spike passed all rungs on Azahar vs the live collector
>   (encoders → HTTP 200; `std/httpclient` ruled out; time source validated).
>   Closed: `observy-8vi`. See `SPIKE-NOTES.md`.
> - **M1 — DONE for local build gates.** `config.nims` ds3 branch, `nim_3ds.cfg`,
>   `stubs/`, `scripts/build_3ds.sh`, `examples/nim.cfg` ds3 guard, threaded-batch
>   gating, and `exporter_http` Plan-B transport via `~/git/http` are implemented.
>   Verified: `nimble test -y`, `nim check -d:ds3 --path:../http/src src/observy.nim`,
>   `nim check -d:ds3 --path:../http/src examples/observy_3ds.nim`, and
>   `scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds`.
> - **M2 — DONE for implementation gates.** `time_3ds.nim` uses the M0-validated
>   `osGetTime` epoch conversion. The 3DS synchronous `record()` path does not call
>   `defaultRetryHooks()` and excludes BatchProcessor.
> - **M3/M4 — remaining live verification.** `examples/observy_3ds.nim` builds to
>   `.3dsx`; the remaining proof is running it on hardware/Azahar against the LAN
>   collector, confirming 200s for traces/metrics/logs, then querying Datadog via
>   `pup`.

Sequenced milestones with acceptance criteria. Each bullet maps cleanly to a
beads issue when work starts. M0/M1/M2 partially implemented (see status above);
remaining items map to `bd create` per bullet, with deps mirroring the gating
arrows below.

## Dependency order

```
M0 (spike, GO/NO-GO) ──┬─▶ M1 (build toolchain)
                       ├─▶ M2 (platform abstraction)
                       └─▶ ...
M1 + M2 ──▶ M3 (example app) ──▶ M4 (Datadog verification)
```

M1 and M2 can proceed in parallel once M0 is GO. M3 needs both. M4 needs M3.

---

## M0 — Networking spike (GO/NO-GO) · `02-networking-spike.md`

- [ ] Rung 1: bare 3DS raw-socket HTTP POST gets a status line from
      `10.0.0.106:4318`.
- [ ] Rung 2: collector returns 200 for an observy-encoded trace; timestamp sane.
- [ ] Rung 3: transport decision recorded — **httpclient GO** or **Plan B GO** —
      with evidence.
- [ ] arc (B2) confirmed for the portable core.
- [ ] `.agents/plans/3ds-support/SPIKE-NOTES.md` written (buffer size, importc
      decls, what worked) — durable location, survives the spike sandbox.

**Gate:** if Rung 1 can't pass on hardware → NO-GO, escalate.

## M1 — Build toolchain & conditional compile · `03-build-toolchain.md`

- [ ] `config.nims` conditionalized (`when defined(ds3)`); desktop branch
      unchanged, `nimble test` still green.
- [ ] `nim_3ds.cfg` added (headless: `-lctru -lm`, no citro3d).
- [ ] `stubs/libdl.a` + `stubs/librt.a` + `stubs/README.md` (GNU ar).
- [ ] `scripts/build_3ds.sh` (headless pipeline, nim.cfg copy + EXIT trap).
- [ ] `examples/nim.cfg` conditionalized (or example relocated) so the 3DS build
      doesn't inherit `orc`/`threads:on`.
- [ ] `batch` import/export + BatchProcessor `record` overloads gated
      `when not defined(ds3)`; under Plan B, `std/httpclient` import gated too.
- [ ] `src/observy.nim:16` docstring updated for the `ds3` build path.
- [ ] `nim check -d:ds3 src/observy.nim` clean (no threads/Channel — and under
      Plan B, no httpclient — leak).

## M2 — Platform abstraction · `04-platform-abstraction.md`

- [ ] `src/observy/time_3ds.nim`: `nowUnixNano()` (+ `monoNanos()` if used),
      epoch-correct, validated against a wall-clock reference.
- [ ] arc leak-free across a long emit loop.
- [ ] No `defaultRetryHooks()`/`std/times` runtime call reachable from the 3DS
      `record()` path.
- [ ] Doc: "set the 3DS RTC or Datadog rejects the data."

## M3 — 3DS example app · `05-example-and-verification.md`

- [ ] `examples/observy_3ds.nim` → `observy_3ds.3dsx`.
- [ ] On hardware prints `200` for traces, metrics, logs.
- [ ] Signals visible in collector debug/file exporter.

## M4 — Datadog verification via pup · `05-example-and-verification.md`

- [ ] Trace from `observy-3ds-verify` in Datadog APM, sensible timestamp.
- [ ] Log line with marker attributes present.
- [ ] Metric with marker present.
- [ ] Timestamps correct end-to-end.

---

## Later / out of MVP scope

These are explicitly deferred — file as backlog issues, don't block the MVP:

- **On-device retry** — `ds3RetryHooks()` backed by libctru time/sleep, only if
  on-device retry proves necessary (`04-platform-abstraction.md` B5).
- **Async batching on 3DS** — would need a non-thread batch implementation (a
  main-loop-driven flush); large, probably unnecessary for a device emitting at
  human/frame cadence.
- **Emulator (Citra/Azahar) verification path** — its own networking spike.
- **TLS / HTTPS** — needs OpenSSL on devkitARM; out of scope (plaintext LAN).
- **gzip** — needs libz on devkitARM; out of scope.
- **gRPC** — observy has no gRPC transport at all.
- **Profiles signal on 3DS** — alpha; not part of MVP.
- **CI** — add a `-d:ds3` compile-only job once the toolchain is stable
  (mirrors how the reference projects gate the 3DS build separately from tests).

## Risk register (carried from `01`)

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| `std/httpclient` won't port | Medium | High | Plan B raw socket (M0 rung 3) |
| Timestamp epoch wrong → silent Datadog drop | Medium | High | M0 rung 2 + M2 validation against reference |
| 3DS not reachable on LAN | Low-Med | High | M0 rung 1 on hardware first |
| arc leaks a cycle | Low | Low | value-type data model; monitor in M2 |
| Collector not exporting to DD us3 | Low | High | confirm collector config in M4 preconditions |
