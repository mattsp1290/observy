# OTEL_* environment variable configuration parser
import std/os
import std/strutils
import std/uri

type
  OtlpProtocol* = enum
    otlpProtoHttp  ## http/protobuf (default)
    otlpJsonHttp   ## http/json

  CompressionType* = enum
    compNone
    compGzip

  ExporterConfig* = object
    endpoint*:            string            ## base OTLP HTTP endpoint URL
    signalEndpoints*:     array[4, string]  ## [traces, metrics, logs, profiles]
    headers*:             seq[(string, string)]
    protocol*:            OtlpProtocol
    serviceName*:         string
    resourceAttributes*:  seq[(string, string)]
    compression*:         CompressionType
    maxRetryElapsed*:     int               ## max cumulative retry window in seconds

const
  SigTraces*   = 0
  SigMetrics*  = 1
  SigLogs*     = 2
  SigProfiles* = 3

  defaultEndpoint = "http://localhost:4318"
  # Profiles uses /v1development/profiles (experimental path, not /v1/profiles).
  signalPaths     = ["/v1/traces", "/v1/metrics", "/v1/logs", "/v1development/profiles"]
  signalEnvKeys   = [
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROFILES_ENDPOINT",
  ]

proc parseKVPairs(raw: string; percentDecodeValues: bool): seq[(string, string)] =
  if raw.len == 0: return
  for token in raw.split(','):
    let t = token.strip()
    if t.len == 0: continue
    let eqPos = t.find('=')
    if eqPos < 0: continue
    let key = t[0 ..< eqPos].strip()
    let rawVal = t[eqPos + 1 .. ^1]
    let val = if percentDecodeValues: decodeUrl(rawVal, decodePlus = false)
              else: rawVal.strip()
    if key.len > 0:
      result.add((key, val))

proc loadFromEnv*(): ExporterConfig =
  ## Return an ExporterConfig populated from OTEL_* env vars and defaults.
  ## Call this first, then override any fields programmatically.

  let baseEnv = getEnv("OTEL_EXPORTER_OTLP_ENDPOINT").strip()
  let base = if baseEnv.len > 0: baseEnv.strip(chars = {'/'}, trailing = true)
             else: defaultEndpoint
  result.endpoint = base

  for i in 0 ..< 4:
    result.signalEndpoints[i] = base & signalPaths[i]

  for i in 0 ..< 4:
    let v = getEnv(signalEnvKeys[i]).strip()
    if v.len > 0:
      result.signalEndpoints[i] = v

  result.headers = parseKVPairs(getEnv("OTEL_EXPORTER_OTLP_HEADERS"), percentDecodeValues = true)

  result.protocol = case getEnv("OTEL_EXPORTER_OTLP_PROTOCOL").strip().toLowerAscii()
    of "http/json": otlpJsonHttp
    else:           otlpProtoHttp

  result.serviceName = getEnv("OTEL_SERVICE_NAME").strip()

  # OTEL_RESOURCE_ATTRIBUTES: plain k=v (no percent-encoding per spec).
  # OTEL_EXPORTER_OTLP_HEADERS uses percent-encoding (W3C Baggage convention).
  result.resourceAttributes = parseKVPairs(getEnv("OTEL_RESOURCE_ATTRIBUTES"), percentDecodeValues = false)

  result.compression = case getEnv("OTEL_EXPORTER_OTLP_COMPRESSION").strip().toLowerAscii()
    of "gzip": compGzip
    else:      compNone

  # 300 s (5 min) is the OTLP spec default; not wired to an env var intentionally.
  result.maxRetryElapsed = 300
