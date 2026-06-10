# 02 — M0: Networking + time spike (GO/NO-GO)

**Question to answer:** does `~/git/http`'s `sockets_vita.nim` actually work
on a real Vita — sceNet bring-up, connect/send/recv against the LAN
collector, and monotonic timeouts — and which wall-clock source gives
correct Unix time?

Everything below M0 is contingent on a GO. Mirror of the 3DS M0
(`.agents/plans/3ds-support/02-networking-spike.md`), but the transport code
already exists; this spike *exercises* it rather than writing it.

## Preconditions

- Collector reachable: `curl -s http://10.0.0.106:4318/v1/traces -d '{}'`
  from the dev machine returns an HTTP response (any code — proves it's up).
- Henkaku-enabled Vita on the same WiFi LAN, VitaShell installed (FTP deploy).
- `$VITASDK` set (`/usr/local/vitasdk` on this machine), `vita-elf-create`,
  `vita-make-fself`, `vita-mksfoex`, and `zip` on PATH (packaging is
  zip-staged per boxy/clckr; `vita-pack-vpk` is not used).
- A spike build path. **Important:** "boxy's cfg minus graphics" is NOT
  sufficient — boxy does no networking, so its cfg links
  `-lSceSysmodule_stub` but not `-lSceNet_stub -lSceNetCtl_stub`, and it has
  no `--path` for `~/git/http/src` or observy's `src/`. The cfg sketch in
  `03-build-toolchain.md` §2 **is** the spike cfg: write it now under
  `spike/` and productize it as `nim_vita.cfg` in M1. Likewise check in
  `spike/build_vita_spike.sh` adapted from clckr's `scripts/build_vita.sh`
  (drop the vitaGL fork injection; keep the librt stub + the
  velf→fself→sfo→zip packaging), mirroring how the 3DS port kept
  `spike/build_spike.sh`.

## Spike app shape

One small Nim program, `-d:vita`, **headless**, writing every step's outcome
to `ux0:data/observy_vita_spike.txt` (file-based breadcrumbs — the inputty
vita example proved this pattern on hardware; no display dependency,
survives a hang before the final write). Use **inputty's exact pattern**:
defensive `createDir("ux0:data")`, accumulate crumbs in a seq, and
**rewrite the whole file on every crumb** (`writeFile(crumbs.join("\n"))`,
exceptions discarded). Do NOT use `fmAppend` — appending to a `ux0:`
device-prefix path via newlib is unproven, rewrite-per-crumb is
hardware-proven. Exit with `sceKernelExitProcess(0)`.

## Rungs (in order; stop at first hard failure)

### Rung 1 — sceNet bring-up + raw HTTP POST round-trip

- Call `httpInit()` (from `~/git/http`) — this is the real `spNetInit()`
  path observy will use.
- Breadcrumb the network state **before** the first POST:
  `sceNetCtlInetGetState` (`<psp2/net/netctl.h>`; state 3 = IP obtained).
  `sceNetCtlInit` succeeds even with WiFi off, and a connect failure on an
  unassociated Vita is otherwise indistinguishable from a broken transport —
  this one line is what separates "no network" from "NO-GO".
- `newHttpClient(timeout = 10_000)`, POST junk bytes to
  `http://10.0.0.106:4318/v1/traces`.
- **Pass:** any HTTP status line comes back (400/415 expected for junk).
  This single rung proves module load, `sceNetInit`, `sceNetCtlInit`,
  `getaddrinfo` on an IP literal, non-blocking connect + `poll`, send/recv,
  and `clock_gettime(CLOCK_MONOTONIC)` (the timeout path runs it).
- Also record: behavior with `timeout = -1` (infinite) in case the
  monotonic clock is the broken piece — that isolates timeouts from
  transport.

### Rung 2 — observy encoders over the real transport

- Build a one-span `protoEncodeTraceRequest` payload with observy's encoders
  (Tier 1 portable core) and POST via the raw `~/git/http` client with
  Content-Type `application/x-protobuf`.
- **Do not try `OtlpHttpExporter` here** — it cannot compile under `-d:vita`
  until M1's gates land: `observy.nim:38`'s batch gate is
  `when not defined(ds3)` (pulls Channel/Thread under `--threads:off`) and
  `exporter_http.nim:15` would select `std/httpclient`, the wrong transport.
  Import the Tier-1 modules piecemeal instead
  (`observy/{anyvalue,proto,resource,traces}` + the request builder),
  mirroring the 3DS spike's `spike/trace_spike_3ds.nim` shape.
- **Pass:** collector returns 200.

### Rung 3 — wall-clock source decision

Test the candidates **in this order** on device, comparing each against the
real date (the 3DS B6 pattern — a wrong epoch silently corrupts Datadog):

1. **newlib POSIX time:** `clock_gettime(CLOCK_REALTIME)` and/or
   `std/times.getTime()`. VitaSDK newlib is more complete than 3DS newlib +
   librt stub, so this may simply work — in which case `time_vita.nim`
   wraps it (still provide the module: keeps the consumer contract uniform
   and insulates against newlib quirks).
2. **`sceRtcGetCurrentTick`** (`<psp2/rtc.h>`, microsecond ticks since
   0001-01-01 00:00:00 UTC). Conversion to Unix:
   `unixMicros = tick - 62_135_596_800_000_000'u64`
   (62,135,596,800 s between year 1 and 1970 — verify on device against a
   known reference before trusting; also confirm whether the RTC sysmodule
   needs explicit loading).
3. **`sceKernelGetProcessTimeWide`** (`<psp2/kernel/processmgr.h>`, µs,
   monotonic since process start — clckr uses it). This is a *monotonic*
   fallback only, not wall clock; if rungs 3.1 and 3.2 both fail, the
   example app needs an epoch-anchor workaround and that's a yellow flag
   worth pausing on.

- **Pass:** one source produces today's date (UTC) within seconds of a
  reference clock. Record whether the Vita RTC is UTC or local time
  (3DS/Azahar needed a `Observy3dsUtcOffsetSec` compensation define — plan
  the same `ObservyVitaUtcOffsetSec` knob in the example, see `05-…md`).

### Rung 4 — arc sanity under emit loop

- Loop ~100 record/encode cycles; confirm no crash/leak growth visible via
  breadcrumbs (coarse is fine; the 3DS port already proved the core under
  arc, this is a cheap regression check on the new libc).

## Outputs

- `.agents/plans/vita-support/SPIKE-NOTES.md` — durable record: per-rung
  PASS/FAIL, SCE error codes seen, chosen time source + measured offset,
  net pool size adequacy, any `sockets_vita.nim` bugs found (and the
  corresponding `~/git/http` fix commits).
- GO/NO-GO declared at the top of SPIKE-NOTES.md and mirrored into
  `06-milestones.md`.

**Gate:** Rung 1 failing in a way that can't be fixed in `~/git/http` within
the spike → NO-GO, escalate to the user. Rung 3 having *no* working wall
clock → pause and consult before building M2 on a workaround.
