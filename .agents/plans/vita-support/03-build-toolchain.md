# 03 — M1: Build toolchain & conditional compile

Productize what the spike hand-rolled. Every artifact mirrors an existing
3DS artifact; diffs from the 3DS version are called out.

## 1. `config.nims` — extend the console branch

Change `config.nims:10` from `when defined(ds3):` to
`when defined(ds3) or defined(vita):`. The body is reused **unchanged** —
same `OBSERVY_HTTP_SRC`/`../http/src` path logic, same
`cpu:arm / os:linux / arc / threads:off / useMalloc /
nimAllocPagesViaMalloc / noSignalHandler / opt:size` set. Update the header
comment (lines 1-9) to document the Vita branch.

Acceptance: `nimble test -y` still green (desktop untouched);
`nim check -d:ds3 --path:../http/src src/observy.nim` still green.

## 2. `nim_vita.cfg` — toolchain template (new file, repo root)

Start from `/Users/punk1290/git/boxy/nim_vita.cfg` and **delete every
graphics line** (vitaGL, vitashark, SceShaccCg, taihen, mathneon, SceGxm,
SceDisplay, SceCtrl, SceCommonDialog, SceAppMgr — none of it applies to a
headless exporter). Keep observy's convention: toolchain-only here, memory
model/threads flags live in `config.nims` (the 3DS split,
`nim_3ds.cfg` vs `config.nims`).

Expected shape (exact stub list to be settled by linker errors — boxy's cfg
is the known-good superset to crib from):

```ini
# observy PlayStation Vita build config (VitaSDK, headless).
--cpu:arm
--os:linux
cc = "gcc"
arm.linux.gcc.path      = "/usr/local/vitasdk/bin"
arm.linux.gcc.exe       = "arm-vita-eabi-gcc"
arm.linux.gcc.linkerexe = "arm-vita-eabi-gcc"

--passC:"-I/usr/local/vitasdk/arm-vita-eabi/include"

# -Wl,-q is MANDATORY: vita-elf-create consumes the retained relocations.
--passL:"-Wl,-q"
--passL:"-L/usr/local/vitasdk/arm-vita-eabi/lib"
--passL:"-lSceNet_stub -lSceNetCtl_stub -lSceSysmodule_stub"
# + -lSceRtc_stub if the M0 time decision lands on sceRtc
--passL:"-Wl,--start-group -lc -lm -lSceLibKernel_stub -lSceIofilemgr_stub -lSceProcessmgr_stub -Wl,--end-group"
--passL:"-Lstubs"

--path:"src"
--path:"../http/src"
```

Notes:

- Prefer `$VITASDK`-relative paths if the cfg DSL allows env expansion the
  way the build script can guarantee; otherwise hardcode
  `/usr/local/vitasdk` (what boxy/clckr/inputty do) and let the build
  script assert `$VITASDK` matches.
- The `-lrt` reference comes from `std/times` (in observy's graph via
  `retry.nim`), and `-ldl` from the os/dynlib path — see the precise wording
  in `stubs/README.md:6-8`; don't paraphrase it as "`--os:linux` emits
  them". Verified 2026-06-10: `/usr/local/vitasdk/arm-vita-eabi/lib` ships
  `libdl.a` but **no `librt.a`** → `stubs/librt.a` is required; keep
  `-Lstubs` and create both stubs anyway (empty archives, byte-identical to
  the 3DS ones, harmless if redundant).

## 3. `stubs/` — reuse

`stubs/libdl.a` / `stubs/librt.a` already exist (empty GNU archives created
for the 3DS; an empty `.a` is the 8-byte `!<arch>` header, toolchain-
independent). The build script creates them with `arm-vita-eabi-ar rcs` if
missing, mirroring `build_3ds.sh:67-73`. Extend `stubs/README.md` with one
paragraph: on Vita, librt symbols (`clock_gettime` etc.) are satisfied by
**newlib libc**, the stub only silences the linker's `-lrt`; whether they
*work at runtime* is recorded in SPIKE-NOTES.

## 4. `scripts/build_vita.sh` (new, mirrors `build_3ds.sh`)

Same skeleton as `scripts/build_3ds.sh` — usage block, `need` tool checks,
`OBSERVY_HTTP_SRC` default `../http/src`, refusal to overwrite an existing
`nim.cfg`, `cp nim_vita.cfg nim.cfg` + EXIT-trap cleanup, `NIMFLAGS_VITA`
extra-flags passthrough. Differences:

- Tool checks: `nim`, `arm-vita-eabi-gcc`, `arm-vita-eabi-ar`,
  `vita-elf-create`, `vita-make-fself`, `vita-mksfoex`, `zip`.
  Fail-loud with an install hint (`https://vitasdk.org`, vdpm). Assert
  `$VITASDK` is set.
- Pipeline after `nim c -d:vita -d:release --path:"$http_src"
  --out:"$build_dir/$name.elf" "$target"` — **zip staging, the
  hardware-proven boxy/clckr method** (`boxy/scripts/build_vita.sh:58-68`,
  `clckr/scripts/build_vita.sh:256-259`; a `.vpk` is a zip of `eboot.bin` +
  `sce_sys/param.sfo`; neither script ever calls `vita-pack-vpk`):

  ```bash
  vita-elf-create "$build_dir/$name.elf"  "$build_dir/$name.velf"
  vita-make-fself "$build_dir/$name.velf" "$build_dir/eboot.bin"
  vita-mksfoex -s TITLE_ID="$title_id" "$name" "$build_dir/param.sfo"
  stage="$build_dir/vpk_stage"
  mkdir -p "$stage/sce_sys"
  cp "$build_dir/eboot.bin" "$stage/"
  cp "$build_dir/param.sfo" "$stage/sce_sys/"
  ( cd "$stage" && zip -qr "../$name.vpk" . )
  ```

  Copy the exact flag spellings for the vita-* tools from
  `/Users/punk1290/git/boxy/scripts/build_vita.sh:58-60` rather than
  trusting the sketch above. (`vita-pack-vpk -s param.sfo -b eboot.bin
  out.vpk` is a valid alternative — inputty's `examples/vita/main.nim.cfg`
  header documents it — but the templates this plan copies use zip staging,
  so use that.)
- `TITLE_ID` default `OBSV00001` (9 chars: 4 letters + 5 digits),
  overridable via env.
- No `--run` deploy step for MVP (no 3dslink equivalent in common use);
  print the `.vpk` path and a one-line VitaShell FTP hint instead.

## 5. Gate the library and examples

- `src/observy.nim:38` and `:128` → `when not (defined(ds3) or defined(vita))`.
- `src/observy/exporter_http.nim:15,82,106,118` → extend each condition;
  update the seam comment block (lines 9-14) and the https error text.
- `examples/nim.cfg:1` → `@if not ds3 and not vita:` — spelling confirmed
  working on Nim 2.2.10 (parses and evaluates correctly under no flags,
  `-d:vita`, and `-d:ds3`).
- `src/observy.nim:18` docstring: add the Vita build line.

## 6. Tier-A semantic gate (no VitaSDK required)

`nim check` does no C compilation, so these run anywhere (CI-able later) —
the inputty `tests/cross_compile_gate.sh` pattern:

```bash
nim check -d:vita --path:../http/src src/observy.nim
nim check -d:vita --path:../http/src examples/observy_vita.nim   # once M3 exists
```

Wire them next to wherever the equivalent `-d:ds3` checks are run today
(currently documented in `.agents/plans/3ds-support/06-milestones.md` M1
notes; if no script exists, add `scripts/check_consoles.sh` covering both
ds3 and vita — small, optional).

## Acceptance (M1 done)

- [ ] `nimble test -y` green (desktop unchanged).
- [ ] `nim check -d:ds3 --path:../http/src src/observy.nim` green (3DS unchanged).
- [ ] `nim check -d:vita --path:../http/src src/observy.nim` green — proves
      no `httpclient`/threads/Channel leak into the Vita graph.
- [ ] `scripts/build_vita.sh examples/observy_vita.nim observy_vita`
      produces `build/observy_vita.vpk`. Until the M3 example exists, the
      smoke target is the **M0 spike app** (`spike/` — building it through
      the productized script also retro-validates the script against the
      hand-rolled spike build).
- [ ] `scripts/build_3ds.sh examples/observy_3ds.nim observy_3ds` still builds.
