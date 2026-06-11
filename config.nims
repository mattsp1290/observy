# Required compiler flags for observy.
#
# Desktop (default): consumers compile with --mm:orc --threads:on. This branch
# MUST stay byte-equivalent to the original — the whole test suite runs through it.
#
# Nintendo 3DS (-d:ds3) and PlayStation Vita (-d:vita): ARM console builds,
# no pthreads for MVP, arc, newlib allocator. The synchronous record() path only
# (no BatchProcessor/threads/retry). Toolchain paths live in nim_3ds.cfg /
# nim_vita.cfg / per-example cfgs. See .agents/plans/{3ds,vita}-support/.
when defined(ds3) or defined(vita):
  let observyHttpSrc = getEnv("OBSERVY_HTTP_SRC")
  if observyHttpSrc.len > 0:
    switch("path", observyHttpSrc)
  else:
    switch("path", "../http/src")
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
