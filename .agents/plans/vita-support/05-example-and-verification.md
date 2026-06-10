# 05 — M3/M4: Example app & end-to-end verification

## M3 — `examples/observy_vita.nim`

Mirror `examples/observy_3ds.nim` (the proven shape) with the
console-specific parts swapped. Key difference from the 3DS example: **stay
headless** — observy needs no graphics, and skipping vitaGL/display keeps
the build at "sceNet stubs only". The 3DS example used the console screen
for interactive feedback, but its *actual* verification channel was the
result file; keep only that channel here.

Shape:

1. `when not defined(vita): {.error: "build with scripts/build_vita.sh (-d:vita)".}`
2. Compile-time knobs (mirroring the 3DS example):
   - `CollectorEndpoint` (default `http://10.0.0.106:4318`)
   - `ObservyVitaUtcOffsetSec` (default 0; only if M0 rung 3 found a
     local-time RTC)
3. Breadcrumb writer to `ux0:data/observy_vita_result.txt` — a hang
   mid-run must still leave the earlier steps' evidence. Use the
   hardware-proven inputty pattern: defensive `createDir("ux0:data")`,
   accumulate crumbs in a seq, **rewrite the whole file on every crumb**
   (`writeFile(crumbs.join("\n"))`, exceptions discarded). Not `fmAppend`
   (unproven on `ux0:` device-prefix paths). Final line is `PASS` or
   `FAIL <detail>`.
4. `newOtlpHttpExporter(config)` — on Vita this performs the entire sceNet
   bring-up via `httpInit()`. **Do not** call sceNet/sceSysmodule directly
   in the example; that would double-init what `~/git/http` owns. After
   construction, breadcrumb `sceNetCtlInetGetState` (`<psp2/net/netctl.h>`,
   state 3 = IP obtained) so a WiFi-off run is distinguishable from a
   transport failure.
5. Resource with marker attributes (as `Resource` attributes — the exporter
   never reads `config.serviceName`):
   - `service.name = observy-vita-verify`
   - `device = playstation-vita`
   - `observy.run.id = vita-<nowUnixNano()>`
6. Emit, synchronously, wrapping **each** export in `try/except` and
   breadcrumbing either the HTTP code or the exception message — a
   no-network run must end `FAIL <connect error, netctl state=N>`, not
   crash before the file is written (the 3DS example's
   `try/except → writeResult("FAIL", …)` is the precedent):
   - one trace (root span + child, a few attributes, an event)
   - one metric (`observy.vita.boot.gauge`, value 1) — mirrors
     `observy.3ds.boot.gauge`
   - one log record (severity INFO, marker attribute)
7. `exporter.close()` (tears down sceNet), write final status,
   `sceKernelExitProcess(0)`.

Timestamps come from `observy/time_vita` with the UTC offset applied in the
example (per `04-platform-abstraction.md`).

Build: `scripts/build_vita.sh examples/observy_vita.nim observy_vita` →
`build/observy_vita.vpk`.

Deploy: VitaShell FTP (`curl -T build/observy_vita.vpk ftp://<vita-ip>:1337/ux0:/`
then install from VitaShell), or USB. Launch from LiveArea; the app exits
on its own; read the result back over FTP:
`ftp://<vita-ip>:1337/ux0:/data/observy_vita_result.txt`.

**M3 acceptance:**

- [ ] `.vpk` builds via `scripts/build_vita.sh`.
- [ ] On hardware: result file shows HTTP `200` for traces, metrics, logs.
- [ ] Signals visible in the collector's debug/file exporter output.

## M4 — Datadog verification via pup

Identical recipe to 3DS M4. Preconditions: collector at `10.0.0.106:4318`
up and exporting to Datadog us3 (confirm before blaming the Vita).

```bash
DD_SITE=us3.datadoghq.com $HOME/git/pup/target/release/pup <query>
```

- [ ] Trace from `service:observy-vita-verify` in APM, sensible timestamp.
- [ ] Log line carrying `device:playstation-vita` + the run id.
- [ ] Metric `observy.vita.boot.gauge` visible.
- [ ] Timestamps correct end-to-end (UTC; compare against wall clock —
      the silent-drop failure mode is wrong-epoch/wrong-zone stamps).

Record the run id, timestamps, and pup queries used in
`06-milestones.md`'s status block, the way the 3DS plan did
(run `3ds-1781063828225000000` is the precedent).

## Emulator note (non-blocking)

If Vita3K runs the `.vpk` at all, attempt the same flow against the LAN
collector and record the outcome in SPIKE-NOTES — useful for future CI
dreams, but **no milestone depends on it** (Vita3K networking is partial;
hardware is the gate, per README decision 6).
