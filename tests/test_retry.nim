import unittest
import std/httpcore
import std/times
import std/strutils
import ../src/observy/exporter_http
import ../src/observy/retry

# A fake clock + recording sleep + identity jitter make retryLoop fully
# deterministic and instant (no real sleeping, no network).
type FakeClock = ref object
  nowSec:   float
  sleeps:   seq[int]      ## recorded sleepMs calls

let fixedWall = parse("Mon, 01 Jan 2024 00:00:00 GMT",
                      "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc()).toTime()

proc hooks(c: FakeClock): RetryHooks =
  RetryHooks(
    nowSec:  proc (): float {.gcsafe.} =
               {.cast(gcsafe).}: c.nowSec,
    sleepMs: proc (ms: int) {.gcsafe.} =
               {.cast(gcsafe).}:
                 c.sleeps.add(ms)
                 c.nowSec += ms.float / 1000.0,   # advance the fake clock
    jitter:  proc (d: float): float {.gcsafe.} =
               {.cast(gcsafe).}: d,                # identity: deterministic
    nowWall: proc (): Time {.gcsafe.} =
               {.cast(gcsafe).}: fixedWall,        # fixed wall clock for HTTP-date
  )

proc resp(code: int; retryAfter = ""): ExportResponse =
  ExportResponse(code: HttpCode(code), retryAfter: retryAfter)

suite "isRetryableStatus":
  test "retryable set":
    check isRetryableStatus(429)
    check isRetryableStatus(502)
    check isRetryableStatus(503)
    check isRetryableStatus(504)
  test "non-retryable":
    check not isRetryableStatus(200)
    check not isRetryableStatus(400)
    check not isRetryableStatus(401)
    check not isRetryableStatus(404)
    check not isRetryableStatus(500)
    check not isRetryableStatus(501)

suite "parseRetryAfter":
  let nowWall = parse("Mon, 01 Jan 2024 00:00:00 GMT",
                      "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc()).toTime()
  test "integer seconds":
    check parseRetryAfter("5", nowWall) == 5.0
  test "integer seconds with whitespace":
    check parseRetryAfter("  10 ", nowWall) == 10.0
  test "absent returns -1":
    check parseRetryAfter("", nowWall) == -1.0
  test "garbage returns -1":
    check parseRetryAfter("soon", nowWall) == -1.0
  test "HTTP-date 30s in the future":
    let d = parseRetryAfter("Mon, 01 Jan 2024 00:00:30 GMT", nowWall)
    check d == 30.0
  test "HTTP-date in the past clamps to 0":
    let d = parseRetryAfter("Sun, 31 Dec 2023 23:59:00 GMT", nowWall)
    check d == 0.0

suite "retryLoop control flow":
  test "200 on first attempt succeeds, no sleep":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}: (inc calls; SendAttempt(resp: resp(200), err: "")))
    check r.succeeded
    check r.attempts == 1
    check calls == 1
    check c.sleeps.len == 0

  test "400 returns immediately without retry":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}: (inc calls; SendAttempt(resp: resp(400), err: "")))
    check not r.succeeded
    check r.attempts == 1
    check calls == 1
    check c.sleeps.len == 0
    check r.errorMessage.contains("non-retryable")

  test "503 then 200 retries once and succeeds":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: SendAttempt(resp: resp(503), err: "")
        else:          SendAttempt(resp: resp(200), err: ""))
    check r.succeeded
    check r.attempts == 2
    check c.sleeps.len == 1
    check c.sleeps[0] == 1000          # initial 1s delay, identity jitter

  test "exponential backoff doubles each retry (1s, 2s, 4s)":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls <= 3: SendAttempt(resp: resp(503), err: "")
        else:          SendAttempt(resp: resp(200), err: ""))
    check r.succeeded
    check r.attempts == 4
    check c.sleeps == @[1000, 2000, 4000]

  test "single delay capped at 30s":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    # never succeed; with a huge budget the delays cap at 30s
    let r = retryLoop(100_000.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls > 12: SendAttempt(resp: resp(200), err: "")
        else:          SendAttempt(resp: resp(503), err: ""))
    check r.succeeded
    # delays: 1,2,4,8,16,30,30,... (capped) in ms
    check c.sleeps[0] == 1000
    check c.sleeps[4] == 16000
    check c.sleeps[5] == 30000
    check c.sleeps[6] == 30000

  test "Retry-After integer overrides computed backoff (~5s)":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: SendAttempt(resp: resp(503, "5"), err: "")
        else:          SendAttempt(resp: resp(200), err: ""))
    check r.succeeded
    check c.sleeps == @[5000]           # 5s from Retry-After, not the 1s backoff

  test "elapsed cap stops retries (gaveUp)":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    # budget 3s; delays 1s, 2s consume it, the next (4s) would exceed → give up
    let r = retryLoop(3.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}: (inc calls; SendAttempt(resp: resp(503), err: "")))
    check not r.succeeded
    check r.gaveUp
    check r.errorMessage.contains("budget exhausted")
    # slept 1s then 2s (total 3s); 3rd delay (4s) would blow the 3s budget
    check c.sleeps == @[1000, 2000]

  test "transport errors are retried then can succeed":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: SendAttempt(resp: ExportResponse(), err: "connection refused")
        else:          SendAttempt(resp: resp(200), err: ""))
    check r.succeeded
    check r.attempts == 2
    check c.sleeps.len == 1

  test "Retry-After is not jittered or capped (honored verbatim at 120s)":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(1000.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: SendAttempt(resp: resp(503, "120"), err: "")
        else:          SendAttempt(resp: resp(200), err: ""))
    check r.succeeded
    check c.sleeps == @[120000]

  test "Retry-After: 0 is floored (no busy-loop)":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    let r = retryLoop(300.0, hooks(c), proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls == 1: SendAttempt(resp: resp(503, "0"), err: "")
        else:          SendAttempt(resp: resp(200), err: ""))
    check r.succeeded
    check c.sleeps.len == 1
    check c.sleeps[0] == 50            # floored to minDelaySec (0.05s)

  test "jitter cannot push a single delay above the 30s cap":
    var c = FakeClock(nowSec: 0.0)
    var calls = 0
    # jitter that always inflates by 10% (the worst case)
    var h = hooks(c)
    h.jitter = proc (d: float): float {.gcsafe.} =
      {.cast(gcsafe).}: d * 1.1
    let r = retryLoop(100_000.0, h, proc (): SendAttempt {.gcsafe.} =
      {.cast(gcsafe).}:
        inc calls
        if calls > 10: SendAttempt(resp: resp(200), err: "")
        else:          SendAttempt(resp: resp(503), err: ""))
    check r.succeeded
    for ms in c.sleeps:
      check ms <= 30000              # cap applied AFTER jitter
