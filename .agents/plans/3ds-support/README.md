# Plan: Nintendo 3DS support for observy

**Goal:** Ship OTLP telemetry (traces, metrics, logs) from a Nintendo 3DS app
using observy, export it to an OTel collector on the local network, and verify
the signals land in Datadog via the `pup` CLI.

**Status:** Planning. Nothing implemented yet.

**Target collector (already running on the LAN):**

| Protocol   | Endpoint                  |
| ---------- | ------------------------- |
| OTLP/gRPC  | `10.0.0.106:4317`         |
| OTLP/HTTP  | `http://10.0.0.106:4318`  |

The 3DS will use **OTLP/HTTP + protobuf** to `10.0.0.106:4318`. gRPC is out of
scope (observy has no gRPC transport; `exporter_http.nim:7` says so explicitly).

**Verification (Datadog):**

```bash
DD_SITE=us3.datadoghq.com $HOME/git/pup/target/release/pup <query>
```

---

## The crux: this is two tiers of work with very different risk

Read this before anything else. "3DS support" is not one task — it is a low-risk
core and a high-risk transport seam, and the plan is sequenced around that split.

### Tier 1 — Portable core (low risk, the real deliverable)

observy's encoders and request builders are **pure Nim with no I/O**:
`protoEncode*`, `protoEncodeTraceRequest`/`…LogsRequest`/`…MetricsRequest`
(`src/observy.nim`), `spanToJson` / `logRecordsToJson` / `metricToJson`, plus the
value types in `anyvalue.nim` / `traces.nim` / `metrics.nim` / `logs.nim` /
`resource.nim` / `proto.nim`. These almost certainly compile under
`--mm:arc --threads:off` unchanged. This is what "observy supports 3DS" actually
*means*, and it is the high-value, low-risk part.

### Tier 2 — Transport seam (high risk, unexplored)

Everything that touches `std/httpclient` lives in **one file**:
`src/observy/exporter_http.nim`. **No project in `~/git/boxy`, `~/git/shady`,
`~/git/birbparty/clckr`, or `~/git/raylib-nim-multiplatform` has ever done socket
I/O on the 3DS** — they are all graphics/input only (confirmed by survey). libctru
*provides* BSD socket headers (`sys/socket.h`, `netdb.h`) and the SOC service, so
Nim's `std/net` *should* compile — but "compiles and runs against the collector"
is the thing we must **prove**, not assume. Nim's `std/nativesockets` uses the
generic `posix` bindings that assume real Linux; they can mismatch libctru's
header subset or call sockopts the 3DS doesn't support.

**The single way this effort fails is treating httpclient-on-3DS as a detail.**
It is the crux. So we gate on it first (Milestone 0) and we carry a fallback.

---

## Milestone map

Each milestone is detailed in its own file. Later milestones are **contingent on
Milestone 0 passing**.

| #  | Milestone                          | File                              | Gate |
| -- | ---------------------------------- | --------------------------------- | ---- |
| 0  | Networking spike (GO/NO-GO)        | `02-networking-spike.md`          | ⛔ blocks all below |
| 1  | Build toolchain & conditional compile | `03-build-toolchain.md`        | |
| 2  | Platform abstraction (time, mm, threads) | `04-platform-abstraction.md` | |
| 3  | 3DS example app + hardware verify  | `05-example-and-verification.md`  | |
| 4  | Datadog verification via pup       | `05-example-and-verification.md`  | |

Background and the full constraint inventory: `01-architecture-and-constraints.md`.
Task/issue breakdown (maps to beads): `06-milestones.md`.

---

## Decisions baked into this plan

1. **HTTP/protobuf to an IP, no DNS, no TLS, no gzip.** The collector is given by
   IP (`10.0.0.106`), so we sidestep DNS resolution entirely. Plaintext `http://`
   means no OpenSSL (`-d:ssl` off). No `-d:observyGzip` (avoids linking libz).
2. **Synchronous `record()` only on 3DS — no BatchProcessor, no retry, for the
   MVP.** The async path (`batch.nim`) is hard-wired to `system.Channel` /
   `Thread`, which require `--threads:on`; the 3DS builds `--threads:off`. The
   retry loop's default hooks *all four* call crashing syscalls (see
   `04-platform-abstraction.md`). MVP = single-attempt synchronous export.
3. **Hardware is the verification target, not an emulator.** The collector is on
   the LAN; the 3DS must reach it over WiFi. Citra/Azahar LAN networking is
   unreliable-to-absent — emulator support is its own later spike, not the path.
4. **A unique marker isolates 3DS telemetry in Datadog.** Set
   `service.name = observy-3ds-verify` plus `device:nintendo-3ds` /
   `observy.run.id` **as `Resource` attributes** (not `config.serviceName`, which
   the exporter never reads — it's only parsed by `loadFromEnv`). `pup` queries
   then match exactly the 3DS data and nothing ambient.
5. **Plan B is a ~40-line raw-socket POST.** If `std/httpclient` won't port, we
   ship a minimal raw BSD-socket HTTP/1.1 POST that reuses observy's encoders
   unchanged. This is the insurance that makes the effort viable regardless of
   httpclient. See `02-networking-spike.md`.

---

## Reference projects (what they taught us)

| Project                       | 3DS use            | What we borrow |
| ----------------------------- | ------------------ | -------------- |
| `boxy`                        | citro3d graphics   | `nim_3ds.cfg` shape, `build_3ds.sh`, libdl stub |
| `shady`                       | shader compilation (desktop-only on 3ds path) | conditional `when not defined(ds3)` pattern |
| `birbparty/clckr`             | graphics + input   | `config.nims` `when defined(ds3)` switches, `stubs/` (libdl+librt), build script |
| `raylib-nim-multiplatform`    | raylib game        | multi-target `config.nims` (`ds3`/`psp`/`vita`/`emscripten`) layout |

None do networking — Tier 2 has no prior art in this codebase.
