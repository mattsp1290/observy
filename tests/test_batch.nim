import unittest
import std/os
import std/atomics
import std/strutils
import ../src/observy/batch

type Item = object
  id: int
  name: string

# The worker thread invokes onBatch; it reports each batch's size back to the
# main thread over a global channel so assertions stay thread-safe.
var sizeChan: Channel[int]

proc recordBatch(items: seq[Item]) {.gcsafe.} =
  {.cast(gcsafe).}: sizeChan.send(items.len)

proc drainSizes(): seq[int] =
  while true:
    let (ok, n) = sizeChan.tryRecv()
    if not ok: break
    result.add(n)

proc sum(s: seq[int]): int =
  for x in s: result += x

suite "BatchProcessor — maxSize batching":
  test "exact multiples flush into equal batches":
    # Timing-independent: 9 items / maxSize 3 is an exact multiple, and both the
    # main loop and the stop-drain flush at maxSize, so the result is [3,3,3]
    # regardless of how far the worker got before stop().
    sizeChan.open()
    var p = newBatchProcessor[Item](
      BatchConfig(maxSize: 3, flushIntervalMs: 10_000, maxQueueSize: 100))
    p.start(recordBatch)
    for i in 0 ..< 9:
      p.submit(Item(id: i, name: "n" & $i))
    p.stop()                # drains + flushes everything
    let sizes = drainSizes()
    sizeChan.close()
    check sizes == @[3, 3, 3]
    check sum(sizes) == 9

  test "remainder is flushed on stop":
    sizeChan.open()
    var p = newBatchProcessor[Item](
      BatchConfig(maxSize: 100, flushIntervalMs: 10_000, maxQueueSize: 100))
    p.start(recordBatch)
    for i in 0 ..< 5:
      p.submit(Item(id: i, name: ""))
    p.stop()                # drains + final-flushes the partial batch
    let sizes = drainSizes()
    sizeChan.close()
    check sizes == @[5]

  test "no items → no batches":
    sizeChan.open()
    var p = newBatchProcessor[Item](defaultBatchConfig())
    p.start(recordBatch)
    p.stop()
    let sizes = drainSizes()
    sizeChan.close()
    check sizes.len == 0

  test "many items split into maxSize chunks (count preserved)":
    sizeChan.open()
    var p = newBatchProcessor[Item](
      BatchConfig(maxSize: 10, flushIntervalMs: 10_000, maxQueueSize: 1000))
    p.start(recordBatch)
    for i in 0 ..< 250:
      p.submit(Item(id: i, name: "x"))
    sleep(150)
    p.stop()
    let sizes = drainSizes()
    sizeChan.close()
    check sum(sizes) == 250               # 250 items total
    for s in sizes: check s <= 10         # never exceeds maxSize
    check sizes.len == 25                 # 250 / 10 exactly

suite "BatchProcessor — interval flush":
  test "non-empty batch flushes after the idle interval (below maxSize)":
    sizeChan.open()
    var p = newBatchProcessor[Item](
      BatchConfig(maxSize: 1000, flushIntervalMs: 50, maxQueueSize: 100))
    p.start(recordBatch)
    p.submit(Item(id: 1, name: "a"))
    p.submit(Item(id: 2, name: "b"))
    sleep(200)              # > flushIntervalMs → worker flushes the partial batch
    let flushed = drainSizes()
    p.stop()
    discard drainSizes()
    sizeChan.close()
    check flushed == @[2]   # the interval flushed 2 items before stop ran

suite "BatchProcessor — payload integrity across the thread boundary":
  test "string/seq fields survive the channel copy":
    sizeChan.open()
    var got: Channel[string]
    got.open()
    proc capture(items: seq[Item]) {.gcsafe.} =
      {.cast(gcsafe).}:
        for it in items: got.send(it.name)
    var p = newBatchProcessor[Item](
      BatchConfig(maxSize: 2, flushIntervalMs: 10_000, maxQueueSize: 100))
    p.start(capture)
    p.submit(Item(id: 1, name: "hello"))
    p.submit(Item(id: 2, name: "world"))
    sleep(80)
    p.stop()
    var names: seq[string]
    while true:
      let (ok, s) = got.tryRecv()
      if not ok: break
      names.add(s)
    got.close()
    sizeChan.close()
    check "hello" in names
    check "world" in names

suite "BatchProcessor — lifecycle guards and error isolation":
  test "a raising onBatch does not kill the worker; later batches still flush":
    sizeChan.open()
    var errs: Channel[string]
    errs.open()
    var flushNo: Atomic[int]
    proc flaky(items: seq[Item]) {.gcsafe.} =
      {.cast(gcsafe).}:
        let n = flushNo.fetchAdd(1)
        if n == 0:
          raise newException(ValueError, "boom")   # first flush fails
        sizeChan.send(items.len)                    # subsequent flushes succeed
    proc onErr(msg: string) {.gcsafe.} =
      {.cast(gcsafe).}: errs.send(msg)
    var p = newBatchProcessor[Item](
      BatchConfig(maxSize: 2, flushIntervalMs: 10_000, maxQueueSize: 100))
    p.start(flaky, onErr)
    for i in 0 ..< 4:       # 2 batches of 2: first raises, second records
      p.submit(Item(id: i, name: ""))
    p.stop()
    let sizes = drainSizes()
    var errMsgs: seq[string]
    while true:
      let (ok, m) = errs.tryRecv()
      if not ok: break
      errMsgs.add(m)
    errs.close(); sizeChan.close()
    check errMsgs.len == 1               # the failed flush was reported, not fatal
    check errMsgs[0].contains("boom")
    check sizes == @[2]                  # the second batch still flushed

  test "submit before start raises ValueError":
    var p = newBatchProcessor[Item](defaultBatchConfig())
    expect ValueError:
      p.submit(Item(id: 1, name: "x"))

  test "submit after stop raises ValueError (no crash)":
    sizeChan.open()
    var p = newBatchProcessor[Item](defaultBatchConfig())
    p.start(recordBatch)
    p.stop()
    expect ValueError:
      p.submit(Item(id: 1, name: "x"))
    discard drainSizes()
    sizeChan.close()

  test "stop is idempotent":
    sizeChan.open()
    var p = newBatchProcessor[Item](defaultBatchConfig())
    p.start(recordBatch)
    p.stop()
    p.stop()                # second stop is a no-op, does not crash
    discard drainSizes()
    sizeChan.close()
    check true
