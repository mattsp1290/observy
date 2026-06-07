# 03 — Milestone 1: Build toolchain & conditional compilation

*Contingent on Milestone 0 passing.* Make observy build a `.3dsx` cleanly with
the synchronous export path, behind a `ds3` define, without disturbing the
desktop build.

## 1. Conditionalize `config.nims`

Today it unconditionally forces `orc` + `threads:on`. Mirror clckr's pattern
(`when defined(ds3)`):

```nim
# config.nims
when defined(ds3):
  # 3DS: devkitARM/libctru. Toolchain paths live in nim_3ds.cfg (copied to
  # nim.cfg by scripts/build_3ds.sh). No threads, arc, newlib allocator.
  switch("cpu", "arm")
  switch("os", "linux")
  switch("mm", "arc")
  switch("threads", "off")
  switch("define", "useMalloc")
  switch("define", "nimAllocPagesViaMalloc")
  switch("define", "noSignalHandler")
  switch("opt", "size")
else:
  # Desktop default — UNCHANGED.
  switch("mm", "orc")
  switch("threads", "on")
```

> The desktop branch must stay byte-equivalent to today's behavior — every
> existing test runs through it.

## 2. Add `nim_3ds.cfg` (toolchain paths)

Adapt boxy's/clckr's `nim_3ds.cfg`, **minus citro3d** (observy is headless) and
**plus** the link stubs. observy needs no graphics libs.

```
# nim_3ds.cfg — observy Nintendo 3DS build (devkitARM + libctru, headless).
# Copied to nim.cfg by scripts/build_3ds.sh (Nim has no --config flag).
--cpu:arm
--os:linux

cc = "gcc"
arm.linux.gcc.path      = "/opt/devkitpro/devkitARM/bin"
arm.linux.gcc.exe       = "arm-none-eabi-gcc"
arm.linux.gcc.linkerexe = "arm-none-eabi-gcc"

--passC:"-specs=3dsx.specs"
--passC:"-march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft"
--passC:"-D__3DS__ -DARM11"
--passC:"-I/opt/devkitpro/libctru/include"   # 3ds.h, sys/socket.h, netdb.h, soc.h

--passL:"-specs=3dsx.specs -march=armv6k -mtune=mpcore -mfloat-abi=hard"
--passL:"-L/opt/devkitpro/libctru/lib -lctru -lm"
# Empty stubs for libs Nim references but the 3DS lacks (-ldl, -lrt).
--passL:"-Lstubs"

--path:"src"
```

Notes:
- **No `-lcitro3d`** — observy doesn't render. Just `-lctru -lm`.
- libctru's `include` provides the BSD socket + `soc.h` headers the transport
  needs (confirmed present at `/opt/devkitpro/libctru/include/`).
- `librt.a` stub is needed because `std/times` (imported by `retry.nim`) pulls
  `-lrt`. `libdl.a` because Nim emits `-ldl` for `--os:linux`.

## 3. Create the link stubs (one-time per checkout)

Same as clckr. Add a `stubs/README.md` documenting *why* (and that the syscalls
crash if actually called).

```sh
arm-none-eabi-ar rcs stubs/libdl.a    # Nim emits -ldl for --os:linux
arm-none-eabi-ar rcs stubs/librt.a    # std/times pulls -lrt
```

> Must be **GNU `ar`** (`arm-none-eabi-ar`); macOS BSD `ar` rejects zero-member
> archives. The build script should regenerate these if missing.

## 4. Gate the threaded + httpclient surface behind `when [not] defined(ds3)`

Two separate gatings. Both are required; the first is for threads (B1), the
second only matters **if Milestone 0 chose Plan B** (httpclient won't port).

### 4a. Threads — always

In `src/observy.nim`:

```nim
when not defined(ds3):
  import observy/batch; export batch
# ... and wrap the three BatchProcessor record() overloads (observy.nim:120-130)
when not defined(ds3):
  proc record*(p: var BatchProcessor[Span]; span: Span) = ...
  proc record*(p: var BatchProcessor[LogRecord]; log: LogRecord) = ...
  proc record*(p: var BatchProcessor[Metric]; metric: Metric) = ...
```

The synchronous `record(exporter, resource, scope, items)` overloads stay
unconditional — they're the 3DS path.

### 4b. httpclient import — only under Plan B

`import std/httpclient` is a **file-scope** statement in `exporter_http.nim:8`,
and `observy.nim:28` imports/exports `exporter_http` unconditionally. A file-level
import resolves before any proc body, so the in-proc `when defined(ds3)` dispatch
floated in `02` does **not** keep httpclient out of the 3DS build. If httpclient
doesn't compile on 3DS, you must gate the import itself:

```nim
# exporter_http.nim
when not defined(ds3):
  import std/httpclient        # desktop transport
# httpclient-using procs (newHttpClient, sendRequest's request() call, close)
# move under `when not defined(ds3)`; the ds3 branch implements the same
# sendRequest/sendSignal surface over raw sockets (exporter_socket_3ds.nim).
# ExportResponse / partial-success decoding stay shared (pure, portable).
```

> If Milestone 0 chose **httpclient GO** (it compiles + runs on 3DS), skip 4b
> entirely — nothing in `exporter_http.nim` needs a branch.

Confirm (via `nim check -d:ds3`) that no other unconditional umbrella import
pulls `system.Channel`/`Thread` (or, under Plan B, `std/httpclient`)
transitively. `retry.nim`'s `{.threadvar.}` compiles as a plain global under
`--threads:off`.

## 5. `scripts/build_3ds.sh`

Adapt boxy's script, dropping the picasso/shader and smdh/banner stages
(headless). Pipeline:

```
1. ensure stubs/libdl.a + stubs/librt.a exist (regenerate with arm-none-eabi-ar)
2. cp nim_3ds.cfg nim.cfg     (trap on EXIT to restore/remove)
3. nim c -d:ds3 -d:release --out:build/<name>.elf <target.nim>
4. 3dsxtool build/<name>.elf build/<name>.3dsx
```

- Toolchain gate up front: check `nim`, `3dsxtool`, `arm-none-eabi-ar` on PATH;
  print the `dkp-pacman -S 3ds-dev` hint if missing (copy boxy's gate).
- `cp nim_3ds.cfg nim.cfg` with an EXIT trap to remove it — never edit `nim.cfg`
  directly, never leave it behind (it would clobber the desktop build).
- `nim c` directly, **not `nimble build`** — observy has no Nimble deps so this is
  trivial, but keep the convention (and it avoids any future dep that can't
  cross-compile).

### ⚠️ `examples/nim.cfg` will clobber the 3DS flags — must be handled

`examples/nim.cfg` already contains `--mm:orc` + `--threads:on` (verified). Nim
discovers `nim.cfg` files by walking **up** the tree and applies them
outermost→innermost; for a target at `examples/observy_3ds.nim`, the nearer
`examples/nim.cfg` is read **after** the repo-root `nim.cfg` we copy from
`nim_3ds.cfg`, and single-value switches (`--mm`, `--threads`) are last-write-wins.
Result: the example would silently compile back to `orc`/`threads:on` — defeating
the entire B1 strategy. Pick one fix and state it in the script:

- **Preferred — conditionalize `examples/nim.cfg`** using nim.cfg's `@if`/`@end`
  syntax so it leaves the `ds3` build alone:
  ```
  @if not ds3:
    --mm:orc
    --threads:on
  @end
  path="../src"
  ```
- **Or** place the 3DS example outside `examples/` (e.g. `examples3ds/`) so the
  desktop `examples/nim.cfg` never applies.
- **Or** have `build_3ds.sh` temporarily neutralize the nested cfg for the 3DS
  build (more fragile; not recommended).

(Boxy's script *errors out* if a root `nim.cfg` exists; observy has none at the
root, so that guard passes — but the **nested** `examples/nim.cfg` is a different
hazard boxy never faced. Don't assume copying boxy's script covers it.)

## Milestone 1 deliverables

- [ ] `config.nims` conditionalized; desktop build + `nimble test` unchanged
      (run the existing suite to prove it).
- [ ] `examples/nim.cfg` conditionalized (or example relocated) so the 3DS build
      does not inherit `orc`/`threads:on` — verify the emitted flags.
- [ ] `nim_3ds.cfg`, `stubs/` (+README), `scripts/build_3ds.sh` added.
- [ ] `batch` gated (4a); under Plan B, `std/httpclient` import gated (4b).
- [ ] `nim check -d:ds3 src/observy.nim` passes (no threads/Channel — and under
      Plan B, no `std/httpclient` — leak).
- [ ] Update the `src/observy.nim` module docstring (currently "Compile consumers
      with `--mm:orc --threads:on`", observy.nim:16) to document the `ds3`
      (`arc`/`threads:off`, synchronous-only) build path.
- [ ] A trivial 3DS example compiles to a `.3dsx` (even if it only encodes +
      prints — full send is Milestone 3).
