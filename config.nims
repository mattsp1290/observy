# Required compiler flags for observy.
#
# Desktop (default): consumers compile with --mm:orc --threads:on. This branch
# MUST stay byte-equivalent to the original — the whole test suite runs through it.
#
# Nintendo 3DS (-d:ds3): devkitARM/libctru, no pthreads, arc, newlib allocator.
# The synchronous record() path only (no BatchProcessor/threads/retry). Toolchain
# paths live in nim_3ds.cfg / the per-example <name>.nim.cfg. See
# .agents/plans/3ds-support/.
when defined(ds3):
  switch("cpu", "arm")
  switch("os", "linux")
  switch("mm", "arc")
  switch("threads", "off")
  switch("define", "useMalloc")          # newlib has no mmap; Nim's allocator needs it
  switch("define", "nimAllocPagesViaMalloc")
  switch("define", "noSignalHandler")    # no POSIX signals on 3DS
  switch("opt", "size")                  # memory-constrained device
else:
  switch("mm", "orc")
  switch("threads", "on")
