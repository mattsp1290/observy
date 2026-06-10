# Vita M0 Spike Notes

**GO/NO-GO (2026-06-10): PENDING HARDWARE RUN.**

Local spike artifacts have been added under `spike/`, but the actual M0 gate
requires running `build/observy_vita_spike.vpk` on a real Henkaku-enabled Vita.
Do not close `observy-yn5` or unblock M1/M2 until the per-rung evidence below is
filled from `ux0:data/observy_vita_spike.txt`.

## Build

- Command: `VITASDK=/usr/local/vitasdk spike/build_vita_spike.sh`
- Collector override:
  `NIMFLAGS_VITA='-d:CollectorEndpoint=http://<collector-ip>:4318' VITASDK=/usr/local/vitasdk spike/build_vita_spike.sh`
- Output: `spike/build/observy_vita_spike.vpk`
- Deploy: `curl -T spike/build/observy_vita_spike.vpk ftp://<vita-ip>:1337/ux0:/`
- Result file: `ux0:data/observy_vita_spike.txt`

## Rung Results

### Rung 1 — sceNet bring-up + raw HTTP POST

- Status: PENDING
- Required evidence: `httpInit PASS`, `sceNetCtlInetGetState ... state=3`, and
  at least one `RUNG1 ... PASS http_status=...` line.
- SCE/http errors:

### Rung 2 — observy encoders over real transport

- Status: PENDING
- Required evidence: `RUNG2 PASS http_status=200`.
- Encoded payload bytes:
- Collector response:

### Rung 3 — wall-clock source decision

- Status: PENDING
- Required evidence: one timestamp source produces today's UTC date within
  seconds of a reference clock.
- `CLOCK_REALTIME`:
- `sceRtcGetCurrentTick`:
- UTC vs local:
- Chosen source for `time_vita.nim`:

### Rung 4 — ARC sanity under emit loop

- Status: PENDING
- Required evidence: `RUNG4 encode-loop PASS cycles=100`.
- Notes:

## Follow-Ups

- `~/git/http` fixes required:
- VitaSDK/toolchain issues:
