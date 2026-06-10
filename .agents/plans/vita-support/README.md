# Plan: PlayStation Vita support for observy

**Goal:** Ship OTLP telemetry (traces, metrics, logs) from a PS Vita homebrew
app using observy, export it to the OTel collector on the local network, and
verify the signals land in Datadog via the `pup` CLI — the same end state the
3DS port reached (`.agents/plans/3ds-support/06-milestones.md`, M3/M4 DONE
2026-06-10).

**Status:** Planning. Nothing implemented yet.

**Target collector (same LAN collector the 3DS port used — confirm it is still
running before the spike):**

| Protocol   | Endpoint                  |
| ---------- | ------------------------- |
| OTLP/gRPC  | `10.0.0.106:4317`         |
| OTLP/HTTP  | `http://10.0.0.106:4318`  |

The Vita will use **OTLP/HTTP + protobuf** to `10.0.0.106:4318`. gRPC is out of
scope (observy has no gRPC transport).

**Verification (Datadog):**

```bash
DD_SITE=us3.datadoghq.com $HOME/git/pup/target/release/pup <query>
```

---

## Why this is much smaller than the 3DS effort

The 3DS port did the expensive discovery work; Vita reuses almost all of it.

1. **The transport seam already exists — on both sides.**
   `src/observy/exporter_http.nim:15` already forks `import http` (the
   `~/git/http` raw-socket library) vs `std/httpclient`. And `~/git/http`
   **already has a Vita backend**: `http.nim:23-24` does
   `elif defined(vita): import ./http/sockets_vita`, and
   `sockets_vita.nim` implements the full seam (`spNetInit` allocates a
   1 MiB net pool, loads `SCE_SYSMODULE_NET`, calls
   `sceNetInit`/`sceNetCtlInit`; connect/send/recv go through VitaSDK's
   newlib BSD sockets via `std/posix`). Its header comment says it plainly:
   **"compile gate only, no device runtime proof yet."** Proving it at runtime
   is the only genuinely risky work in this plan (M0).
2. **The gating pattern is proven.** Every `when defined(ds3)` in observy
   (full inventory in `01-architecture-and-constraints.md`) extends to
   `when defined(ds3) or defined(vita)` — the flags Vita needs
   (`arc`, `threads:off`, `useMalloc`, `noSignalHandler`, `opt:size`) are
   identical to the 3DS set already in `config.nims`.
3. **The toolchain pattern is proven in sibling repos.** boxy, clckr, and
   inputty all cross-compile Nim to Vita with `arm-vita-eabi-gcc` +
   `--cpu:arm --os:linux` + `--passL:"-Wl,-q"` and package velf→fself→vpk.
   observy is **headless**, so it needs none of their vitaGL/graphics
   machinery — only the sceNet stubs. `nim_vita.cfg` here is
   `/Users/punk1290/git/boxy/nim_vita.cfg` minus every graphics line.
4. **The verification recipe is proven.** Result-file-on-storage + marker
   resource attributes + `pup` queries worked end-to-end for the 3DS; reuse it
   verbatim with `service.name = observy-vita-verify`.

## The crux

Same shape as the 3DS plan, smaller blast radius:

- **Tier 1 — portable core:** already proven portable under
  `--mm:arc --threads:off` by the 3DS port. Zero expected work.
- **Tier 2 — transport at runtime:** `sockets_vita.nim` has never run on a
  device or emulator. Its `std/posix` calls (`getaddrinfo`, `poll`, `fcntl`
  `O_NONBLOCK` dance, `clock_gettime(CLOCK_MONOTONIC)`) compile against
  VitaSDK newlib but any one of them could misbehave at runtime. **M0 gates
  everything on proving one HTTP POST round-trip from a real Vita.**

---

## Milestone map

| #  | Milestone                                 | File                             | Gate |
| -- | ----------------------------------------- | -------------------------------- | ---- |
| 0  | Networking + time spike (GO/NO-GO)        | `02-networking-spike.md`         | ⛔ blocks all below |
| 1  | Build toolchain & conditional compile     | `03-build-toolchain.md`          | |
| 2  | Platform abstraction (time_vita)          | `04-platform-abstraction.md`     | |
| 3  | Vita example app + hardware verify        | `05-example-and-verification.md` | |
| 4  | Datadog verification via pup              | `05-example-and-verification.md` | |

Background and the full gate inventory: `01-architecture-and-constraints.md`.
Task/issue breakdown (maps to beads): `06-milestones.md`.

---

## Decisions baked into this plan

1. **The define is `-d:vita`.** Non-negotiable: `~/git/http` selects
   `sockets_vita.nim` on `defined(vita)`, and boxy/clckr/inputty all use it.
   Do not invent `-d:psvita`.
2. **Extend the existing `ds3` gates with `or defined(vita)` — do not
   refactor them.** The desktop branch must stay byte-equivalent (the whole
   test suite runs through it, see `config.nims:3-4`) and the proven `ds3`
   path must not churn. A `retroConsole` const refactor is explicitly
   deferred until a third console forces it.
3. **HTTP/protobuf to an IP, no DNS-dependence assumed, no TLS, no gzip.**
   Same as 3DS. Collector by IP sidesteps DNS (though `sockets_vita.nim`
   does route literals through `getaddrinfo` with `AI_NUMERICHOST` — the
   spike exercises exactly that path). Plaintext only; extend the
   `exporter_http.nim:82` https rejection to Vita.
4. **Synchronous `record()` only — no BatchProcessor, no retry, for MVP.**
   Identical to the 3DS decision. The Vita *does* have usable threads
   (unlike the 3DS), but enabling `--threads:on` there is unexplored and
   buys nothing for the MVP. Deferred.
5. **Wall-clock source is decided by the M0 spike, not assumed.** Unlike the
   3DS (where `std/times` crashes at runtime over the librt stub), VitaSDK's
   newlib may implement `time()`/`gettimeofday()`/`clock_gettime` for real —
   `sockets_vita.nim:36-40` already bets on `clock_gettime(CLOCK_MONOTONIC)`.
   If `CLOCK_REALTIME` works on device, `time_vita.nim` is a thin wrapper;
   if not, fall back to `sceRtcGetCurrentTick` (`<psp2/rtc.h>`). See
   `04-platform-abstraction.md`.
6. **Hardware is the verification target.** Vita3K (emulator) networking
   support is partial/unreliable — treat any emulator run as a bonus, not
   the gate. A henkaku-enabled Vita on the LAN WiFi is the target, deploying
   the `.vpk` via VitaShell FTP.
7. **Marker attributes isolate Vita telemetry in Datadog:**
   `service.name = observy-vita-verify`, `device = playstation-vita`,
   `observy.run.id = vita-<nowUnixNano>` — as `Resource` attributes (the
   exporter never reads `config.serviceName`; the 3DS plan learned this).

---

## Reference material

| Source | What we take |
| ------ | ------------ |
| `.agents/plans/3ds-support/` (this repo) | Plan shape, seam inventory, verification recipe, risk framing |
| `src/observy/time_3ds.nim` | Template for `time_vita.nim` |
| `scripts/build_3ds.sh` | Template for `scripts/build_vita.sh` (nim.cfg copy + EXIT trap, stub creation, refusal-to-overwrite) |
| `/Users/punk1290/git/http/src/http/sockets_vita.nim` | The transport — needs runtime proof, not new code |
| `/Users/punk1290/git/boxy/nim_vita.cfg` | Toolchain cfg template (strip all vitaGL/graphics lines) |
| `/Users/punk1290/git/boxy/scripts/build_vita.sh` | velf→fself→sfo packaging order + zip-staged `.vpk` (boxy/clckr never call `vita-pack-vpk`; the `.vpk` is a zip of `eboot.bin` + `sce_sys/param.sfo`) |
| `/Users/punk1290/git/inputty/tests/cross_compile_gate.sh` | Tier-A semantic gate pattern (`nim check -d:vita`, no SDK needed) |
| `/Users/punk1290/git/birbparty/clckr` | librt stub precedent, fail-loud toolchain checks |

VitaSDK is installed on this machine at `/usr/local/vitasdk` (`$VITASDK` set,
`arm-vita-eabi-gcc` and the vita-* packaging tools on PATH via `$VITASDK/bin`).
