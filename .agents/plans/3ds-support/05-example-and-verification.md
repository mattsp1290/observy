# 05 — Milestones 3 & 4: Example app + end-to-end verification

*Contingent on Milestones 0–2.* Build a real 3DS example that emits all three
signals to the collector, run it on hardware, and confirm the data in Datadog
via `pup`.

## Milestone 3 — The 3DS example app

`examples/observy_3ds.nim` (guarded `when defined(ds3)`), built by
`scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds`.

> Verification note from the Azahar run (2026-06-10): Azahar exposed the 3DS wall
> clock as EDT local time, not UTC. Build the example with
> `NIMFLAGS_3DS='-d:Observy3dsUtcOffsetSec=14400'` in that environment so metric
> timestamps land within Datadog's current custom-metric window. Real hardware
> may need `0` if its RTC/user-time source is already UTC-like, or the local
> offset if it behaves like Azahar.

Structure:

> ⚠️ The snippet below is **grounded against the real observy API** (see
> `examples/traces.nim`). Two traps the first draft fell into, now fixed:
> - There is **no `newResource(@[(string,string)])`**. `Resource` is a plain
>   object built from an `AttributeSet` (`initAttributeSet()` + `.add(k,
>   AnyValue(...))`).
> - A hand-built `ExporterConfig` leaves `signalEndpoints` **empty** — only
>   `loadFromEnv()` derives them. `record()` would then raise
>   `ValueError: "empty endpoint URL"` (`exporter_http.nim:120`). The 3DS app
>   has no env, so it must set `signalEndpoints` explicitly.

```nim
# 1. Platform bring-up
gfxInitDefault()              # console output so we can see results on-screen
consoleInit(...)
socInit(socBuf, 0x100000)     # networking — see 02-networking-spike.md
defer: socExit(); gfxExit()

# 2. Config pointed at the collector (IP, no DNS). signalEndpoints MUST be set
#    explicitly — no env, no loadFromEnv() to derive them. (serviceName/
#    resourceAttributes on the config are NOT consumed by the exporter; the
#    marker is carried by the resource attribute in step 3, not here.)
var cfg = ExporterConfig(
  endpoint: "http://10.0.0.106:4318",
  protocol: otlpProtoHttp,          # http/protobuf
)
cfg.signalEndpoints = ["http://10.0.0.106:4318/v1/traces",
                       "http://10.0.0.106:4318/v1/metrics",
                       "http://10.0.0.106:4318/v1/logs",
                       ""]                        # profiles unused
var exporter = newOtlpExporter(cfg)

# 3. Resource carries the unique marker (THIS is what pup queries match on).
var resAttrs = initAttributeSet()
resAttrs.add("service.name",           AnyValue(kind: avString, strVal: "observy-3ds-verify"))
resAttrs.add("telemetry.sdk.language", AnyValue(kind: avString, strVal: "nim"))
resAttrs.add("device",                 AnyValue(kind: avString, strVal: "nintendo-3ds"))
resAttrs.add("observy.run.id",         AnyValue(kind: avString, strVal: runId))  # disambiguate boots
let res = Resource(attributes: resAttrs)
let scope = InstrumentationScope(
  name: "observy-3ds-example", version: "0.1.0",
  attributes: initAttributeSet())               # match examples/*.nim

# 4. Emit one of each, timestamps from time_3ds.nowUnixNano() (epoch-correct!).
#    Span requires non-zero 16-byte traceId / 8-byte spanId (see examples/traces.nim).
let t0 = nowUnixNano()
var span = Span(
  traceId: tid, spanId: sid,                     # generate non-zero ids
  name: "boot", kind: skInternal,
  startTimeUnixNano: t0, endTimeUnixNano: t0 + 1_000_000)
discard exporter.record(res, scope, @[span])         # traces
discard exporter.record(res, scope, @[someMetric])   # metrics
discard exporter.record(res, scope, @[someLogRecord])# logs

# 5. Print each ExportResponse.code to the 3DS screen so a human sees 200/!=200.
```

Notes:
- Use the synchronous `record()` overloads (no BatchProcessor, no retry).
- Print `resp.code` per signal to the console so success/failure is visible
  on-device without a debugger.
- Generate valid 16-byte trace IDs / 8-byte span IDs (non-zero) — see the `TID`/
  `SID` constants in `examples/traces.nim` for the byte-array form.
- If Milestone 0 chose **Plan B**, `record()` already routes through the raw
  socket transport `when defined(ds3)` — the example code is identical.

### Deploy & run on hardware

The reference build scripts (boxy, clckr, raylib) **only build the `.3dsx` —
none deploy**. So there is no inherited convention; pick one explicitly:

- **`3dslink` over WiFi (fastest iteration):** put the 3DS into netloader mode
  (Homebrew Launcher → Y, or the relevant menu), then
  `3dslink build/observy_3ds.3dsx`. Requires the 3DS and host on the same LAN
  (which we need anyway for the collector). Add an optional `--run` flag to
  `scripts/build_3ds.sh` that calls `3dslink` after a successful build.
- **SD card + Homebrew Launcher:** copy `build/observy_3ds.3dsx` to
  `sdmc:/3ds/` on the card, boot Homebrew Launcher, launch it.

Recommended: `3dslink` for the dev loop. State the chosen path in the script's
usage text.

### Milestone 3 deliverables

- [ ] `examples/observy_3ds.nim` builds to `observy_3ds.3dsx`.
- [ ] On hardware, prints `200` for traces, metrics, and logs.
- [ ] Signals visible in the collector's debug/file exporter (host-side sanity
      before involving Datadog).

## Milestone 4 — Datadog verification via `pup`

### The verification chain

```
3DS (WiFi/LAN) ──http/protobuf──▶ collector @10.0.0.106:4318 ──▶ Datadog (us3) ──▶ pup query
```

### Preconditions

- **Hardware on the LAN.** The collector is on the local network; the 3DS must be
  associated to the same WiFi and able to reach `10.0.0.106`. **Emulator
  (Citra/Azahar) is not the path** — its LAN networking to a host service is
  unreliable-to-absent; treat emulator support as a separate later spike.
- **3DS RTC set** to a correct date/time (see `04-platform-abstraction.md`) or
  Datadog will drop/misplace the data despite a 200 from the collector.
- **Collector forwards to Datadog us3.** Confirm the collector's
  `datadog/exporter` (or OTLP→DD pipeline) targets `us3.datadoghq.com` with a
  valid API key. (`observy/collector-config.yml` is the desktop reference; the
  LAN collector config is owned outside this repo — confirm it exports to DD.)
  **Actionable check — isolate the collector→DD link BEFORE involving the 3DS:**
  run observy's existing desktop example against the *same* LAN collector and
  confirm it reaches Datadog via `pup` first:

  ```bash
  OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.0.106:4318 \
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
  OTEL_SERVICE_NAME=observy-3ds-verify-desktop \
  nim c -r examples/traces.nim
  # then query pup for service:observy-3ds-verify-desktop (see below)
  ```

  If the desktop trace lands in Datadog, the collector→DD pipeline is proven and
  any later failure is isolated to the 3DS side. If it does NOT, fix the
  collector config before touching hardware — this is the #1 troubleshooting
  symptom ("200 from collector, nothing in Datadog").

### The marker

Everything is queried by the unique identity set in the example:
`service.name = observy-3ds-verify` + resource attrs `device:nintendo-3ds`,
`observy.run.id:<id>`. This isolates 3DS telemetry from all ambient data.

### pup queries (run AFTER the example, allow ~1–2 min for ingest)

```bash
PUP="DD_SITE=us3.datadoghq.com $HOME/git/pup/target/release/pup"

# Traces — APM, filter by the marker service
eval $PUP traces --service observy-3ds-verify --from "now-15m"

# Logs — filter by service / device
eval $PUP logs --query "service:observy-3ds-verify device:nintendo-3ds" --from "now-15m"

# Metrics — the metric name(s) emitted by the example
eval $PUP metrics --query "<metric.name>{service:observy-3ds-verify}" --from "now-15m"
```

> The exact `pup` subcommand/flag spelling must be confirmed against
> `pup --help` (and the `/datadog` skill) at execution time — the above is the
> intent (query each signal by the marker), not verified flag syntax. Use the
> `datadog` skill to drive these queries if available.

### Pass criterion (the definition of done for the whole effort)

- [ ] A trace from `observy-3ds-verify` appears in Datadog APM with a sensible
      timestamp (within minutes of "now", not 1970 or 2095).
- [ ] A log line from the 3DS appears with the marker attributes.
- [ ] The metric appears with the marker.
- [ ] Timestamps are correct (the timestamp gate from B6 actually held
      end-to-end).

### Troubleshooting ladder

| Symptom | Likely cause | Where to look |
| ------- | ------------ | ------------- |
| 200 from collector, nothing in Datadog | bad timestamp (epoch) OR collector not exporting to DD | `04-platform-abstraction.md` B6; collector DD exporter config |
| Connection refused / timeout on 3DS | not on LAN / wrong IP / socInit buffer | `02-networking-spike.md` rung 1 |
| Data in Datadog but wrong time window | RTC/epoch conversion off | `time_3ds.nowUnixNano` epoch math |
| Collector returns 400/415 | malformed body / wrong Content-Type | encoder output; `defaultContentType` |
| Can't find the data among ambient telemetry | marker not unique enough | add/strengthen `observy.run.id` |
