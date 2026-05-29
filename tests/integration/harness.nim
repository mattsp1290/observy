## Integration-test harness for exercising observy against a live OpenTelemetry
## Collector (see docker-compose.yml / collector-config.yml).
##
## The collector's `file` exporter writes newline-delimited JSON to
## ./collector-output/signals.json — each line is one OTLP-JSON
## Export{Trace,Metrics,Logs}ServiceRequest. These helpers wait for the collector
## to be healthy, read/clear that output, and assert on its contents. The actual
## per-signal integration tests (observy-1yo/39x/xj4) build on these.
import std/httpclient
import std/httpcore
import std/json
import std/os
import std/strutils
import std/monotimes
import std/times

const
  defaultHealthUrl* = "http://localhost:13133/"
  collectorOutputPath* = "collector-output/signals.json"

proc waitForCollector*(timeoutMs = 30000; healthUrl = defaultHealthUrl) =
  ## Poll the collector health-check endpoint every 500ms until it returns 200,
  ## or raise IOError once timeoutMs elapses.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var client = newHttpClient(timeout = 1000)
  defer: client.close()
  while true:
    var healthy = false
    try:
      healthy = client.get(healthUrl).code == Http200
    except CatchableError:
      healthy = false
    if healthy: return
    if getMonoTime() >= deadline:
      raise newException(IOError,
        "collector not healthy at " & healthUrl & " within " & $timeoutMs & "ms")
    sleep(500)

proc readCollectorOutput*(): string =
  ## Read the collector's signals output file (empty string if absent).
  if fileExists(collectorOutputPath): readFile(collectorOutputPath) else: ""

proc clearCollectorOutput*() =
  ## Truncate the collector's signals output file to empty.
  writeFile(collectorOutputPath, "")

# ---------------------------------------------------------------------------
# Assertion helpers. The output may contain several newline-delimited JSON
# objects (one per export request); each helper scans all of them.
# ---------------------------------------------------------------------------

proc parseLines(jsonStr: string): seq[JsonNode] =
  for line in jsonStr.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    try: result.add(parseJson(t))
    except CatchableError: discard

iterator resourceBlocks(docs: seq[JsonNode]): JsonNode =
  ## Yield each ResourceSpans/ResourceMetrics/ResourceLogs object across all docs.
  for d in docs:
    if d.kind != JObject: continue
    for key in ["resourceSpans", "resourceMetrics", "resourceLogs"]:
      if d.hasKey(key) and d[key].kind == JArray:
        for rb in d[key]: yield rb

proc collectAttrStrings(node: JsonNode; key: string): seq[string] =
  ## Recursively collect string values of attributes whose `key` matches.
  if node.kind == JObject:
    if node.hasKey("key") and node.hasKey("value") and
       node["key"].kind == JString and node["key"].getStr() == key and
       node["value"].kind == JObject and node["value"].hasKey("stringValue"):
      result.add(node["value"]["stringValue"].getStr())
    for _, v in node: result.add(collectAttrStrings(v, key))
  elif node.kind == JArray:
    for v in node: result.add(collectAttrStrings(v, key))

proc assertServiceName*(jsonStr, name: string) =
  let docs = parseLines(jsonStr)
  var found = false
  for rb in resourceBlocks(docs):
    if name in collectAttrStrings(rb, "service.name"): found = true
  doAssert found, "service.name '" & name & "' not found in collector output"

proc assertSpanCount*(jsonStr: string; n: int) =
  let docs = parseLines(jsonStr)
  var count = 0
  for d in docs:
    if d.kind == JObject and d.hasKey("resourceSpans"):
      for rs in d["resourceSpans"]:
        if rs.hasKey("scopeSpans"):
          for ss in rs["scopeSpans"]:
            if ss.hasKey("spans"): count += ss["spans"].len
  doAssert count == n, "expected " & $n & " spans, found " & $count

proc collectByField(node: JsonNode; parent, field: string): seq[string] =
  ## Collect string values of `field` inside objects under arrays named `parent`.
  if node.kind == JObject:
    for k, v in node:
      if k == parent and v.kind == JArray:
        for item in v:
          if item.kind == JObject and item.hasKey(field) and item[field].kind == JString:
            result.add(item[field].getStr())
      result.add(collectByField(v, parent, field))
  elif node.kind == JArray:
    for v in node: result.add(collectByField(v, parent, field))

proc assertMetricName*(jsonStr, name: string) =
  let docs = parseLines(jsonStr)
  var found = false
  for d in docs:
    if name in collectByField(d, "metrics", "name"): found = true
  doAssert found, "metric '" & name & "' not found in collector output"

proc collectLogBodies(node: JsonNode): seq[string] =
  ## Collect logRecord body.stringValue values.
  if node.kind == JObject:
    for k, v in node:
      if k == "logRecords" and v.kind == JArray:
        for lr in v:
          if lr.kind == JObject and lr.hasKey("body") and
             lr["body"].kind == JObject and lr["body"].hasKey("stringValue"):
            result.add(lr["body"]["stringValue"].getStr())
      result.add(collectLogBodies(v))
  elif node.kind == JArray:
    for v in node: result.add(collectLogBodies(v))

proc assertLogBody*(jsonStr, body: string) =
  let docs = parseLines(jsonStr)
  var found = false
  for d in docs:
    if body in collectLogBodies(d): found = true
  doAssert found, "log body '" & body & "' not found in collector output"

proc isHex32(s: string): bool =
  s.len == 32 and (block:
    var ok = true
    for c in s:
      if c notin {'0'..'9', 'a'..'f'}: ok = false; break
    ok)

proc collectTraceIds(node: JsonNode): seq[string] =
  if node.kind == JObject:
    for k, v in node:
      if k == "traceId" and v.kind == JString:
        result.add(v.getStr())
      result.add(collectTraceIds(v))
  elif node.kind == JArray:
    for v in node: result.add(collectTraceIds(v))

proc assertTraceIdHex*(jsonStr, traceId: string) =
  ## Assert the given traceId appears and is a 32-char lowercase hex string.
  doAssert isHex32(traceId), "expected a 32-char lowercase hex traceId, got '" & traceId & "'"
  let docs = parseLines(jsonStr)
  var found = false
  for d in docs:
    if traceId in collectTraceIds(d): found = true
  doAssert found, "traceId '" & traceId & "' not found in collector output"
