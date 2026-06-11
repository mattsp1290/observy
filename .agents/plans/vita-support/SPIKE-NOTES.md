# Vita M0 Spike Notes

**GO/NO-GO (2026-06-11): GO.**

The M0 spike ran on real Vita hardware and all required rungs passed. The Vita
result file was read back from `ux0:data/observy_vita_spike.txt` after mounting
the memory card at `/Volumes/Untitled`; SHA-256 of the copied result was
`f16056ebf964bb0b022f92bd4a71d52a4e244beb94219d8d4e2c061547aab534`.

## Build

- Command: `VITASDK=/usr/local/vitasdk spike/build_vita_spike.sh`
- Collector override:
  `NIMFLAGS_VITA='-d:CollectorEndpoint=http://<collector-ip>:4318' VITASDK=/usr/local/vitasdk spike/build_vita_spike.sh`
- Output: `spike/build/observy_vita_spike.vpk`
- Deploy: `curl -T spike/build/observy_vita_spike.vpk ftp://<vita-ip>:1337/ux0:/`
- Result file: `ux0:data/observy_vita_spike.txt`

## Rung Results

### Rung 1 — sceNet bring-up + raw HTTP POST

- Status: PASS
- Evidence:
  - `httpInit PASS`
  - `sceNetCtlInetGetState rc=0 state=3 (3 means IP obtained)`
  - `RUNG1 finite-timeout PASS http_status=400 400 Bad Request`
  - `RUNG1 infinite-timeout PASS http_status=400 400 Bad Request`
- SCE/http errors: none.

### Rung 2 — observy encoders over real transport

- Status: PASS
- Evidence: `RUNG2 PASS http_status=200 200 OK`.
- Encoded payload bytes: 316.
- Collector response: HTTP 200.

### Rung 3 — wall-clock source decision

- Status: PASS
- `CLOCK_REALTIME`: `1781150558582067000` ns =
  `2026-06-11T04:02:38.582067012Z`.
- `sceRtcGetCurrentTick`: `1781150558585766000` ns =
  `2026-06-11T04:02:38.585765838Z`, `sceRtcGetTickResolution() = 1000000`.
- UTC vs local: readings match the UTC reference time for the run
  (`2026-06-11T04:05:55Z` checked on the dev machine shortly after readback).
- Chosen source for `time_vita.nim`: newlib `clock_gettime(CLOCK_REALTIME)`.
  `sceRtcGetCurrentTick` is validated as a fallback and uses the planned
  year-1-to-Unix epoch conversion.

### Rung 4 — ARC sanity under emit loop

- Status: PASS
- Evidence: `RUNG4 encode-loop PASS cycles=100 encoded_bytes_total=31694`.
- Notes: encode loop wrote progress every 10 cycles and completed without crash.

## Follow-Ups

- `~/git/http` fixes required: none from M0.
- VitaSDK/toolchain issues: none from M0.

## Raw Result

```text
START observy Vita M0 spike
collector=http://10.0.0.106:4318
httpInit PASS
sceNetCtlInetGetState rc=0 state=3 (3 means IP obtained)
RUNG1 finite-timeout PASS http_status=400 400 Bad Request
RUNG1 infinite-timeout PASS http_status=400 400 Bad Request
RUNG2 encoded trace bytes=316
RUNG2 PASS http_status=200 200 OK
RUNG3 CLOCK_REALTIME PASS unix_nano=1781150558582067000
RUNG3 sceRtcGetCurrentTick PASS unix_nano=1781150558585766000 resolution=1000000
RUNG4 progress cycles=10 encoded_bytes_total=3162
RUNG4 progress cycles=20 encoded_bytes_total=6332
RUNG4 progress cycles=30 encoded_bytes_total=9502
RUNG4 progress cycles=40 encoded_bytes_total=12672
RUNG4 progress cycles=50 encoded_bytes_total=15842
RUNG4 progress cycles=60 encoded_bytes_total=19012
RUNG4 progress cycles=70 encoded_bytes_total=22182
RUNG4 progress cycles=80 encoded_bytes_total=25352
RUNG4 progress cycles=90 encoded_bytes_total=28522
RUNG4 progress cycles=100 encoded_bytes_total=31694
RUNG4 encode-loop PASS cycles=100 encoded_bytes_total=31694
DONE inspect rung PASS/FAIL lines and compare RUNG3 timestamps to UTC wall clock
```
