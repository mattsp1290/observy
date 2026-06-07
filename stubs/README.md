# 3DS link stubs

Empty static archives for libraries Nim references on a `--os:linux` target but
that **do not exist on the Nintendo 3DS** (devkitARM / libctru / newlib):

- `libdl.a` — Nim emits `-ldl` for `--os:linux` targets; the 3DS has no `dlopen`.
- `librt.a` — `std/times` (imported transitively, e.g. by `retry.nim`) pulls
  `-lrt`; the 3DS has no POSIX realtime libs.

Linking against empty stubs satisfies the `-ldl`/`-lrt` references at link time.
**Do not call `dlopen`/`clock_gettime` at runtime on the 3DS** — they resolve to
nothing and crash. (observy's 3DS path uses `osGetTime()` for time, never
`std/times` at runtime — see `.agents/plans/3ds-support/SPIKE-NOTES.md`.)

The `.a` files are git-ignored (`*.a`) and regenerated per checkout — they are
build state, not source.

## Create them (one-time per checkout)

```sh
arm-none-eabi-ar rcs stubs/libdl.a    # GNU ar; macOS BSD ar rejects empty archives
arm-none-eabi-ar rcs stubs/librt.a
```
