# Batch processor: a worker thread that accumulates submitted items into batches
# and flushes them (to an injected `onBatch` callback) when the batch reaches
# maxSize or the flush interval elapses.
#
# Concurrency model (stdlib only):
#   - system.Channel[T] (builtin, --threads:on) carries items to the worker. The
#     builtin channel deep-copies each message into shared memory and rebuilds it
#     on the receiving thread, so producer and worker never share the same heap
#     object — an ownership-safe transfer.
#   - std/isolation's isolate() is applied at the submit boundary as a
#     compile-time assertion that the item has no outside references before it
#     crosses the thread boundary (ORC: one owner at a time).
#   - std/atomics carries the stop flag.
#
# NOTE on the spec: the task suggested Channel[Isolated[T]], but on Nim 2.2.10 the
# builtin channel cannot instantiate Isolated[T] (=destroy calling-convention
# error) and std/channels / the threading package are unavailable / disallowed.
# Using Channel[T] + isolate() at submit is the equivalent stdlib-only design.
#
# forceFlush() and a richer shutdown() are observy-uml; this module provides the
# core processor plus a basic stop() for lifecycle/testing.
import std/isolation
import std/atomics
import std/monotimes
import std/os

type
  BatchConfig* = object
    maxSize*:         int   ## flush when the batch reaches this many items
    flushIntervalMs*: int   ## flush a non-empty batch after this many ms idle
    maxQueueSize*:    int   ## bounded channel capacity (0 = unbounded)

  BatchErrorProc* = proc (msg: string) {.gcsafe.}

  BatchProcessor*[T] = object
    ## Single-owner: holds a worker thread, channel and stop flag. The embedded
    ## Channel/Thread/Atomic make it non-copyable and non-movable (the compiler
    ## enforces this), so the worker's `addr p` stays valid for its whole life.
    ## Backpressure policy: submit() BLOCKS the producing thread when the bounded
    ## queue (maxQueueSize) is full — no data is dropped. Treat one processor as
    ## single-producer (or guard submit/stop with your own sync).
    config*:        BatchConfig
    chan:           Channel[T]
    thread:         Thread[ptr BatchProcessor[T]]
    onBatch:        proc (items: seq[T]) {.gcsafe.}
    onError:        BatchErrorProc        ## called if a flush raises; nil → stderr
    stopRequested:  Atomic[bool]
    started:        Atomic[bool]

proc defaultBatchConfig*(): BatchConfig =
  BatchConfig(maxSize: 512, flushIntervalMs: 5000, maxQueueSize: 2048)

proc monoMs(): int64 =
  getMonoTime().ticks div 1_000_000

proc worker[T](p: ptr BatchProcessor[T]) {.thread.} =
  var batch: seq[T]
  var lastFlush = monoMs()
  template flush() =
    if batch.len > 0:
      # A flush hitting a network error / 5xx is normal operation for an
      # exporter; an exception escaping the thread proc would abort the whole
      # process, so it is caught here. The batch is dropped after reporting.
      try:
        p.onBatch(batch)
      except CatchableError as ex:
        if p.onError != nil:
          p.onError("batch flush failed: " & ex.msg)
        else:
          {.cast(gcsafe).}:
            stderr.writeLine("observy batch: flush failed: " & ex.msg)
      batch.setLen(0)
      lastFlush = monoMs()
  while true:
    # Check stop every iteration (not only when idle) so a flooding producer
    # can't starve the stop signal and hang stop()/joinThread.
    if p.stopRequested.load(moAcquire):
      break
    let (ok, item) = p.chan.tryRecv()
    if ok:
      batch.add(item)
      if batch.len >= p.config.maxSize:
        flush()
    else:
      if batch.len > 0 and (monoMs() - lastFlush) >= p.config.flushIntervalMs:
        flush()
      sleep(1)   # idle tick; avoid busy-spin
  # Drain anything still queued, then a final flush (graceful stop).
  while true:
    let (ok, item) = p.chan.tryRecv()
    if not ok: break
    batch.add(item)
    if batch.len >= p.config.maxSize:
      flush()
  flush()

proc start*[T](p: var BatchProcessor[T];
               onBatch: proc (items: seq[T]) {.gcsafe.};
               onError: BatchErrorProc = nil) =
  ## Open the channel and spawn the worker thread. `onError` (optional) is called
  ## when a flush raises; if nil, failures are written to stderr.
  doAssert onBatch != nil, "onBatch callback is required"
  doAssert not p.started.load(moAcquire), "BatchProcessor already started"
  p.onBatch = onBatch
  p.onError = onError
  p.stopRequested.store(false, moRelease)
  p.chan.open(p.config.maxQueueSize)
  p.started.store(true, moRelease)
  createThread(p.thread, worker[T], addr p)

proc newBatchProcessor*[T](config = defaultBatchConfig()): BatchProcessor[T] =
  ## Construct a processor. Assign to a stable `var`, then call start() — the
  ## worker holds a pointer to the processor, so it cannot be started here (the
  ## result is moved to the caller's location on return).
  result.config = config

proc submit*[T](p: var BatchProcessor[T]; item: sink T) =
  ## Hand an item to the worker. Raises ValueError if the processor isn't running
  ## (before start() or after stop()) rather than crashing on a closed channel.
  ## BLOCKS when the bounded queue is full (backpressure, no drop).
  ## isolate() asserts at compile time that `item` has no outside references
  ## before it crosses the thread boundary.
  if not p.started.load(moAcquire):
    raise newException(ValueError, "submit() called before start() or after stop()")
  var iso = isolate(item)
  p.chan.send(extract(iso))

proc stop*[T](p: var BatchProcessor[T]) =
  ## Request stop, wait for the worker to drain + final-flush, then close.
  if not p.started.load(moAcquire): return
  p.started.store(false, moRelease)   # reject further submit() before close
  p.stopRequested.store(true, moRelease)
  joinThread(p.thread)
  p.chan.close()
