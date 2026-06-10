# 06 — Milestones & task breakdown

> **Status (2026-06-10):** Planning complete, nothing implemented. Update
> this block per milestone, the way `.agents/plans/3ds-support/06-milestones.md`
> does (it is the working example of the format).

Sequenced milestones with acceptance criteria. Beads granularity: **one
issue per milestone** (the 3DS precedent — `observy-8vi` covered all of M0),
with this file's bullets pasted into `-d` as the acceptance checklist, e.g.
`bd create "M0: Vita networking spike" -d "<bullets>" -p 0 -t task`, and
deps mirroring the gating arrows via `bd dep add <M1-id> <M0-id>` etc.
"Later / out of MVP scope" items are filed as `-p 3` backlog.

## Dependency order

```
M0 (spike, GO/NO-GO) ──┬─▶ M1 (build toolchain)
                       └─▶ M2 (time_vita)
M1 + M2 ──▶ M3 (example app) ──▶ M4 (Datadog verification)
```

M1 and M2 can proceed in parallel once M0 is GO. M3 needs both. M4 needs M3.
If M0 finds `sockets_vita.nim` bugs, the fixes are `~/git/http` work items
(its own repo/issues) and M0 re-runs after they land.

---

## M0 — Networking + time spike (GO/NO-GO) · `02-networking-spike.md`

- [ ] Spike build artifacts checked in under `spike/` (cfg from
      `03-build-toolchain.md` §2 — boxy's cfg alone lacks the net stubs —
      plus `build_vita_spike.sh`, mirroring the 3DS `spike/build_spike.sh`).
- [ ] Rung 1: `httpInit()` + `sceNetCtlInetGetState` breadcrumb + raw POST
      from real Vita gets an HTTP status line from `10.0.0.106:4318`
      (proves sceNet bring-up, posix sockets, monotonic-clock timeouts in
      `~/git/http`'s `sockets_vita.nim`).
- [ ] Rung 2: collector returns 200 for an observy-encoded trace.
- [ ] Rung 3: wall-clock source decided (newlib `CLOCK_REALTIME` vs
      `sceRtcGetCurrentTick` vs none) with on-device date validation;
      UTC-vs-local recorded.
- [ ] Rung 4: ~100-cycle emit loop survives under arc.
- [ ] `SPIKE-NOTES.md` written (durable: SCE error codes, chosen time
      source, `~/git/http` fixes if any, GO/NO-GO).

**Gate:** Rung 1 unfixable in `~/git/http` → NO-GO, escalate. No working
wall clock in rung 3 → pause, consult user.

## M1 — Build toolchain & conditional compile · `03-build-toolchain.md`

- [ ] `config.nims:10` condition extended to `or defined(vita)`; desktop
      branch unchanged, `nimble test -y` green.
- [ ] `nim_vita.cfg` added (headless: sceNet stubs only, `-Wl,-q`, no
      graphics; cribbed from `/Users/punk1290/git/boxy/nim_vita.cfg`).
- [ ] `stubs/` reused; `stubs/README.md` gains the Vita paragraph.
- [ ] `scripts/build_vita.sh` (nim.cfg copy + EXIT trap, tool checks,
      velf→fself→sfo + zip-staged `.vpk` per boxy/clckr's proven scripts,
      TITLE_ID `OBSV00001`).
- [ ] `examples/nim.cfg` excludes vita from the orc/threads block
      (`@if not ds3 and not vita:` — spelling confirmed on Nim 2.2.10).
- [ ] `src/observy.nim:38,:128` batch gates extended;
      `exporter_http.nim:15,82,106,118` gates extended; seam comment and
      https error text updated; `observy.nim:18` docstring updated.
- [ ] `nim check -d:vita --path:../http/src src/observy.nim` green.
- [ ] Regression: `nim check -d:ds3 …` green and
      `scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds` still builds.

## M2 — Platform abstraction (time) · `04-platform-abstraction.md`

- [ ] `src/observy/time_vita.nim`: `nowUnixMillis`/`nowUnixNano` from the
      M0-validated source; desktop import `{.error.}`; signatures match
      `time_3ds.nim`.
- [ ] On-device timestamp validated against a wall-clock reference.
- [ ] No `defaultRetryHooks()`/`std/times` runtime call reachable from the
      Vita `record()` path.
- [ ] Doc: "set the Vita clock or Datadog rejects the data."

## M3 — Vita example app · `05-example-and-verification.md`

- [ ] `examples/observy_vita.nim` → `build/observy_vita.vpk` via
      `scripts/build_vita.sh`.
- [ ] Headless; per-step breadcrumbs to `ux0:data/observy_vita_result.txt`
      (rewrite-per-crumb pattern, netctl state, per-signal try/except);
      exits cleanly. A no-network run ends `FAIL <detail>`, not a crash.
- [ ] On hardware: HTTP 200 recorded for traces, metrics, logs.
- [ ] Signals visible in collector debug/file exporter.
- [ ] `examples/README.md`: `observy_vita.nim` row added (build command,
      `NIMFLAGS_VITA` / `ObservyVitaUtcOffsetSec` hints); nim.cfg note
      extended to mention vita.

## M4 — Datadog verification via pup · `05-example-and-verification.md`

- [ ] Trace from `observy-vita-verify` in Datadog APM, sensible timestamp.
- [ ] Log line with `device:playstation-vita` + run id present.
- [ ] Metric `observy.vita.boot.gauge` present.
- [ ] Timestamps correct end-to-end; run id + queries recorded in the
      status block above.

---

## Later / out of MVP scope

File as backlog `bd` issues; don't block the MVP:

- **`vitaRetryHooks()`** — clock from `time_vita`, sleep via
  `sceKernelDelayThread`; only if on-device retry proves necessary.
- **Threaded batching on Vita** — the Vita has real threads (unlike 3DS);
  `--threads:on` + BatchProcessor there is plausible but unexplored. Its
  own spike if a consumer ever needs background export.
- **Vita3K emulator path** — networking support partial; bonus only.
- **TLS / gzip / gRPC / profiles signal** — same exclusions as 3DS, same
  reasons.
- **CI** — a `nim check -d:vita` job is free (no SDK needed); a full
  cross-compile job needs VitaSDK in the runner. Pair with the deferred
  `-d:ds3` CI item.
- **`retroConsole` gate refactor** — collapse the
  `defined(ds3) or defined(vita)` repetition only when a third console
  arrives.

## Risk register

Carried from `01-architecture-and-constraints.md` — headline items:

| Risk | Likelihood | Impact | Mitigation |
| ---- | ---------- | ------ | ---------- |
| `sockets_vita.nim` fails at runtime | Medium | High | M0 rung 1 first; fixes in `~/git/http` |
| `clock_gettime(CLOCK_MONOTONIC)` broken → timeouts dead | Low-Med | High | M0 rung 1 with/without timeout; fallback `sceKernelGetProcessTimeWide` in `~/git/http` |
| Wrong epoch/zone → silent Datadog drop | Medium | High | M0 rung 3 validation; UTC-offset knob in example |
| Linker stub set incomplete | Medium | Low | Iterate in M1 against boxy's known-good cfg |
| Collector/DD pipeline down | Low | High | Precondition checks in M0 and M4 |
