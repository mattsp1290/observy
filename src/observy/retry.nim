# Retry policy with exponential backoff for the OTLP/HTTP exporter.
#
# Retries on HTTP 429, 502, 503, 504 and on transport errors (connection refused,
# timeout, TLS). Honors a Retry-After header (integer seconds or HTTP-date), which
# overrides the computed backoff. Computed backoff is exponential: 1s initial,
# x2 per attempt, ±10% jitter, capped at 30s per delay; the cumulative retry
# window is bounded by config.maxRetryElapsed (default 300s). All other statuses
# (e.g. 400/401/404) are non-retryable and return immediately.
#
# The core state machine (retryLoop) takes injectable clock/sleep/jitter hooks
# and a send thunk, so it is fully unit-testable with a fake clock and no network.
import std/httpcore
import std/strutils
import std/times
import std/monotimes
import std/random
import std/os
import ./config
import ./exporter_http

const
  initialDelaySec = 1.0
  backoffMultiplier = 2.0
  maxSingleDelaySec = 30.0
  minDelaySec = 0.05        ## floor so a Retry-After: 0 / past-date can't busy-loop
  maxAttempts = 1000        ## hard backstop independent of the time budget

type
  RetryHooks* = object
    ## Injection seam for deterministic testing. Defaults use the real monotonic
    ## clock, OS sleep, a ±10% thread-local random jitter, and the wall clock.
    nowSec*:  proc (): float {.gcsafe.}        ## monotonic seconds (elapsed budget)
    sleepMs*: proc (ms: int) {.gcsafe.}        ## block for ms milliseconds
    jitter*:  proc (delaySec: float): float {.gcsafe.}  ## apply ±10% to a delay
    nowWall*: proc (): Time {.gcsafe.}         ## wall clock (Retry-After HTTP-date)

  SendAttempt* = object
    ## One outcome from the send thunk: a response, or a transport-level error.
    resp*: ExportResponse
    err*:  string            ## non-empty => transport failure (retryable)

  ExportResult* = object
    response*:     ExportResponse  ## last response seen (code 0 if only errors)
    attempts*:     int             ## total send attempts made
    succeeded*:    bool            ## got a 2xx
    gaveUp*:       bool            ## stopped due to the elapsed-time budget
    errorMessage*: string          ## why it failed (empty on success)

proc isRetryableStatus*(code: int): bool =
  code == 429 or code == 502 or code == 503 or code == 504

proc parseRetryAfter*(headerVal: string; nowWall: Time): float =
  ## Parse a Retry-After header into a delay in seconds. Supports the integer
  ## "delta-seconds" form and the IMF HTTP-date form. Returns -1 when absent or
  ## unparseable (caller falls back to computed backoff). Never negative.
  let h = headerVal.strip()
  if h.len == 0: return -1.0
  try:
    return max(0.0, float(parseInt(h)))
  except ValueError:
    discard
  try:
    let t = parse(h, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc())
    return max(0.0, (t.toTime() - nowWall).inMilliseconds.float / 1000.0)
  except CatchableError:
    return -1.0

var jitterRng {.threadvar.}: Rand
var jitterRngReady {.threadvar.}: bool

proc defaultJitter(delaySec: float): float =
  ## ±10% uniform jitter using a THREAD-LOCAL RNG. std/random's default rand()
  ## mutates a process-global state (a data race once the batch worker owns the
  ## exporter under --threads:on), so each thread seeds its own Rand.
  if not jitterRngReady:
    jitterRng = initRand()
    jitterRngReady = true
  let factor = 0.9 + jitterRng.rand(0.2)   # [0.9, 1.1)
  delaySec * factor

proc defaultRetryHooks*(): RetryHooks =
  RetryHooks(
    nowSec:  proc (): float {.gcsafe.} =
               {.cast(gcsafe).}: getMonoTime().ticks.float / 1_000_000_000.0,
    sleepMs: proc (ms: int) {.gcsafe.} =
               {.cast(gcsafe).}: sleep(ms),
    jitter:  proc (d: float): float {.gcsafe.} =
               {.cast(gcsafe).}: defaultJitter(d),
    nowWall: proc (): Time {.gcsafe.} =
               {.cast(gcsafe).}: getTime(),
  )

proc retryLoop*(maxElapsedSec: float; hooks: RetryHooks;
                send: proc (): SendAttempt {.gcsafe.}): ExportResult =
  ## Pure backoff state machine. Calls `send` until it yields a 2xx, a
  ## non-retryable status, or the elapsed-time budget would be exceeded.
  let start = hooks.nowSec()
  var delay = initialDelaySec
  var attempt = 0
  while true:
    inc attempt
    let a = send()
    result.attempts = attempt
    result.response = a.resp
    if a.err.len == 0:
      let code = int(a.resp.code)
      if code >= 200 and code < 300:
        result.succeeded = true
        return
      if not isRetryableStatus(code):
        result.errorMessage = "non-retryable HTTP status " & $code
        return
      result.errorMessage = "retryable HTTP status " & $code
    else:
      result.errorMessage = "transport error: " & a.err

    # Hard attempt backstop independent of the time budget.
    if attempt >= maxAttempts:
      result.gaveUp = true
      result.errorMessage = "retry attempt cap (" & $maxAttempts &
                            ") reached; last: " & result.errorMessage
      return

    # Decide the next delay. Computed backoff: jitter then cap at 30s (cap AFTER
    # jitter so ±10% can never push a single delay above the ceiling).
    var sleepSec = min(hooks.jitter(delay), maxSingleDelaySec)
    # Retry-After (server-directed) overrides the computed backoff verbatim.
    if a.err.len == 0 and a.resp.retryAfter.len > 0:
      let ra = parseRetryAfter(a.resp.retryAfter, hooks.nowWall())
      if ra >= 0.0: sleepSec = ra
    # Floor every retry delay so a Retry-After: 0 / past HTTP-date can't busy-loop.
    sleepSec = max(sleepSec, minDelaySec)

    # Stop if sleeping would exceed the cumulative retry window.
    let elapsed = hooks.nowSec() - start
    if elapsed + sleepSec > maxElapsedSec:
      result.gaveUp = true
      result.errorMessage = "retry budget exhausted after " & $attempt &
                            " attempt(s); last: " & result.errorMessage
      return

    hooks.sleepMs(int(sleepSec * 1000.0))
    delay = delay * backoffMultiplier

proc retryWithBackoff*(e: var OtlpHttpExporter; url: string; payload: seq[byte];
                       contentType: string;
                       hooks: RetryHooks = defaultRetryHooks()): ExportResult =
  ## Send with retries. Thin adapter over retryLoop: wraps e.sendRequest so a
  ## transport exception becomes a retryable SendAttempt error.
  let maxElapsed = float(if e.config.maxRetryElapsed > 0: e.config.maxRetryElapsed else: 300)
  # Capture a ptr (a `var` param can't be captured in a closure). retryLoop calls
  # the thunk synchronously and never stores it, so the pointer stays valid.
  let ep = addr e
  retryLoop(maxElapsed, hooks, proc (): SendAttempt {.gcsafe.} =
    {.cast(gcsafe).}:
      try:
        SendAttempt(resp: ep[].sendRequest(url, payload, contentType), err: "")
      except CatchableError as ex:
        SendAttempt(resp: ExportResponse(), err: ex.msg))
