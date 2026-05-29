import unittest
import std/os
import std/strutils
import ./harness

# Sample OTLP-JSON as the collector's file exporter writes it (newline-delimited
# Export*ServiceRequest objects). Used to unit-test the assertion helpers without
# needing a live collector.
const traceDoc = """{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"itest"}}]},"scopeSpans":[{"scope":{"name":"harness"},"spans":[{"traceId":"0102030405060708090a0b0c0d0e0f10","spanId":"0102030405060708","name":"s1"},{"traceId":"0102030405060708090a0b0c0d0e0f10","spanId":"1112131415161718","name":"s2"}]}]}]}"""
const metricDoc = """{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"msvc"}}]},"scopeMetrics":[{"scope":{"name":"m"},"metrics":[{"name":"http.requests.total","sum":{"dataPoints":[]}}]}]}]}"""
const logDoc = """{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"lsvc"}}]},"scopeLogs":[{"scope":{"name":"l"},"logRecords":[{"body":{"stringValue":"hello world"}}]}]}]}"""

suite "harness assertion helpers":
  test "assertServiceName finds the resource attribute":
    assertServiceName(traceDoc, "itest")
    assertServiceName(metricDoc, "msvc")
    assertServiceName(logDoc, "lsvc")

  test "assertServiceName fails for a missing name":
    expect AssertionDefect:
      assertServiceName(traceDoc, "nope")

  test "assertSpanCount counts spans across scopeSpans":
    assertSpanCount(traceDoc, 2)

  test "assertSpanCount fails on wrong count":
    expect AssertionDefect:
      assertSpanCount(traceDoc, 3)

  test "assertMetricName finds a metric by name":
    assertMetricName(metricDoc, "http.requests.total")

  test "assertMetricName fails for a missing metric":
    expect AssertionDefect:
      assertMetricName(metricDoc, "absent.metric")

  test "assertLogBody finds the log body":
    assertLogBody(logDoc, "hello world")

  test "assertTraceIdHex validates a present 32-char hex id":
    assertTraceIdHex(traceDoc, "0102030405060708090a0b0c0d0e0f10")

  test "assertTraceIdHex rejects a non-hex / wrong-length id":
    expect AssertionDefect:
      assertTraceIdHex(traceDoc, "not-hex")
    expect AssertionDefect:
      assertTraceIdHex(traceDoc, "0102")          # too short

  test "multi-line (newline-delimited) output is scanned across all docs":
    let combined = traceDoc & "\n" & metricDoc & "\n" & logDoc
    assertServiceName(combined, "itest")
    assertMetricName(combined, "http.requests.total")
    assertLogBody(combined, "hello world")

suite "harness output file IO":
  test "clear then read round-trips empty (temp path, not the live file)":
    let tmp = getTempDir() / "observy_harness_io.json"
    writeFile(tmp, "stale")
    clearCollectorOutput(tmp)
    check readCollectorOutput(tmp) == ""
    removeFile(tmp)

  test "readCollectorOutput returns empty for a missing file":
    let tmp = getTempDir() / "observy_harness_absent.json"
    removeFile(tmp)
    check readCollectorOutput(tmp) == ""

  test "waitForOutput returns as soon as the predicate matches":
    let tmp = getTempDir() / "observy_harness_wait.json"
    writeFile(tmp, "{\"resourceSpans\":[]}\n")
    let got = waitForOutput(proc (c: string): bool {.gcsafe.} = c.contains("resourceSpans"),
                            timeoutMs = 2000, path = tmp)
    check got.contains("resourceSpans")
    removeFile(tmp)

  test "waitForOutput returns last content on timeout (no match)":
    let tmp = getTempDir() / "observy_harness_wait2.json"
    writeFile(tmp, "nothing useful")
    let got = waitForOutput(proc (c: string): bool {.gcsafe.} = c.contains("never"),
                            timeoutMs = 400, path = tmp)
    check got == "nothing useful"
    removeFile(tmp)

suite "harness waitForCollector":
  test "raises on timeout against a dead endpoint":
    expect IOError:
      waitForCollector(timeoutMs = 600, healthUrl = "http://127.0.0.1:1/")

  # Live check: only runs when the collector is up. Enable with -d:liveCollector.
  # Uses the shipped default healthUrl (127.0.0.1) so CI exercises it directly.
  when defined(liveCollector):
    test "returns promptly when the collector is healthy":
      waitForCollector(timeoutMs = 30000)
      check true
