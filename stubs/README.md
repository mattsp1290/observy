# Console link stubs

Empty static archives for libraries Nim references on a `--os:linux` target but
that **do not exist on the Nintendo 3DS** (devkitARM / libctru / newlib), or
that are referenced by Nim even though the target libc supplies the symbols:

- `libdl.a` — Nim emits `-ldl` for `--os:linux` targets; the 3DS has no `dlopen`.
- `librt.a` — `std/times` (imported transitively, e.g. by `retry.nim`) pulls
  `-lrt`; the 3DS has no POSIX realtime libs.

Linking against empty stubs satisfies the `-ldl`/`-lrt` references at link time.
**Do not call `dlopen`/`clock_gettime` at runtime on the 3DS** — they resolve to
nothing and crash. (observy's 3DS path uses `osGetTime()` for time, never
`std/times` at runtime — see `.agents/plans/3ds-support/SPIKE-NOTES.md`.)

On Vita, `clock_gettime(CLOCK_REALTIME)` is supplied by VitaSDK newlib libc and
was runtime-validated in `.agents/plans/vita-support/SPIKE-NOTES.md`; the empty
`librt.a` only silences Nim's `-lrt` linker reference. The Vita build script also
creates both archives with `arm-vita-eabi-ar` if they are missing.

The `.a` files are git-ignored (`*.a`) and regenerated per checkout — they are
build state, not source.

## Create them (one-time per checkout)

For 3DS builds:

```sh
arm-none-eabi-ar rcs stubs/libdl.a    # GNU ar; macOS BSD ar rejects empty archives
arm-none-eabi-ar rcs stubs/librt.a
```

For Vita builds, `scripts/build_vita.sh` creates these automatically with the
Vita toolchain when missing. To create them manually:

```sh
arm-vita-eabi-ar rcs stubs/libdl.a
arm-vita-eabi-ar rcs stubs/librt.a
```
