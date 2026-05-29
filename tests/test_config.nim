import unittest
import std/os
import ../src/observy/config

suite "loadFromEnv defaults":
  test "default endpoint is localhost:4318":
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    let cfg = loadFromEnv()
    check cfg.endpoint == "http://localhost:4318"

  test "default signal endpoints append correct paths":
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    delEnv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
    delEnv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
    delEnv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
    delEnv("OTEL_EXPORTER_OTLP_PROFILES_ENDPOINT")
    let cfg = loadFromEnv()
    check cfg.signalEndpoints[SigTraces]   == "http://localhost:4318/v1/traces"
    check cfg.signalEndpoints[SigMetrics]  == "http://localhost:4318/v1/metrics"
    check cfg.signalEndpoints[SigLogs]     == "http://localhost:4318/v1/logs"
    check cfg.signalEndpoints[SigProfiles] == "http://localhost:4318/v1development/profiles"

  test "default protocol is http/protobuf":
    delEnv("OTEL_EXPORTER_OTLP_PROTOCOL")
    let cfg = loadFromEnv()
    check cfg.protocol == otlpProtoHttp

  test "default headers is empty":
    delEnv("OTEL_EXPORTER_OTLP_HEADERS")
    let cfg = loadFromEnv()
    check cfg.headers.len == 0

  test "default serviceName is empty":
    delEnv("OTEL_SERVICE_NAME")
    let cfg = loadFromEnv()
    check cfg.serviceName == ""

  test "default maxRetryElapsed is 300":
    let cfg = loadFromEnv()
    check cfg.maxRetryElapsed == 300

suite "OTEL_EXPORTER_OTLP_ENDPOINT":
  test "base endpoint is stored and paths are appended":
    putEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    check cfg.endpoint == "http://collector:4318"
    check cfg.signalEndpoints[SigTraces]  == "http://collector:4318/v1/traces"
    check cfg.signalEndpoints[SigMetrics] == "http://collector:4318/v1/metrics"
    check cfg.signalEndpoints[SigLogs]    == "http://collector:4318/v1/logs"

  test "trailing slash on base endpoint is stripped before appending":
    putEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318/")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    check cfg.signalEndpoints[SigTraces] == "http://collector:4318/v1/traces"

suite "per-signal endpoint env vars":
  test "traces endpoint used verbatim — no path appended":
    putEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://base:4318")
    putEnv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://trace-collector:9999/custom")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    delEnv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
    check cfg.signalEndpoints[SigTraces] == "http://trace-collector:9999/custom"
    check cfg.signalEndpoints[SigMetrics] == "http://base:4318/v1/metrics"

  test "metrics endpoint used verbatim":
    putEnv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "http://metrics-collector:8080")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
    check cfg.signalEndpoints[SigMetrics] == "http://metrics-collector:8080"

  test "logs endpoint used verbatim":
    putEnv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://logs:7777/logs")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
    check cfg.signalEndpoints[SigLogs] == "http://logs:7777/logs"

  test "per-signal overrides base but other signals use base":
    putEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://base:4318")
    putEnv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", "http://log-only:5555")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    delEnv("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")
    check cfg.signalEndpoints[SigTraces] == "http://base:4318/v1/traces"
    check cfg.signalEndpoints[SigLogs]   == "http://log-only:5555"

suite "OTEL_EXPORTER_OTLP_HEADERS":
  test "single header parsed":
    putEnv("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Bearer token123")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_HEADERS")
    check cfg.headers.len == 1
    check cfg.headers[0][0] == "authorization"
    check cfg.headers[0][1] == "Bearer token123"

  test "multiple headers comma-separated":
    putEnv("OTEL_EXPORTER_OTLP_HEADERS", "x-tenant=acme,authorization=Bearer tok")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_HEADERS")
    check cfg.headers.len == 2
    check cfg.headers[0][0] == "x-tenant"
    check cfg.headers[0][1] == "acme"
    check cfg.headers[1][0] == "authorization"

  test "percent-encoded space in header value decoded":
    putEnv("OTEL_EXPORTER_OTLP_HEADERS", "authorization=Bearer%20mytoken")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_HEADERS")
    check cfg.headers.len == 1
    check cfg.headers[0][1] == "Bearer mytoken"

  test "percent-encoded comma in header value":
    putEnv("OTEL_EXPORTER_OTLP_HEADERS", "x-ids=a%2Cb")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_HEADERS")
    check cfg.headers.len == 1
    check cfg.headers[0][1] == "a,b"

suite "OTEL_EXPORTER_OTLP_PROTOCOL":
  test "http/protobuf maps to otlpProtoHttp":
    putEnv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_PROTOCOL")
    check cfg.protocol == otlpProtoHttp

  test "http/json maps to otlpJsonHttp":
    putEnv("OTEL_EXPORTER_OTLP_PROTOCOL", "http/json")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_PROTOCOL")
    check cfg.protocol == otlpJsonHttp

  test "unknown protocol defaults to otlpProtoHttp":
    putEnv("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc")
    let cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_PROTOCOL")
    check cfg.protocol == otlpProtoHttp

suite "OTEL_SERVICE_NAME":
  test "service name is read from env":
    putEnv("OTEL_SERVICE_NAME", "my-service")
    let cfg = loadFromEnv()
    delEnv("OTEL_SERVICE_NAME")
    check cfg.serviceName == "my-service"

suite "OTEL_RESOURCE_ATTRIBUTES":
  test "single k=v attribute parsed":
    putEnv("OTEL_RESOURCE_ATTRIBUTES", "service.version=1.0.0")
    let cfg = loadFromEnv()
    delEnv("OTEL_RESOURCE_ATTRIBUTES")
    check cfg.resourceAttributes.len == 1
    check cfg.resourceAttributes[0][0] == "service.version"
    check cfg.resourceAttributes[0][1] == "1.0.0"

  test "multiple resource attributes":
    putEnv("OTEL_RESOURCE_ATTRIBUTES", "env=prod,region=us-east-1")
    let cfg = loadFromEnv()
    delEnv("OTEL_RESOURCE_ATTRIBUTES")
    check cfg.resourceAttributes.len == 2
    check cfg.resourceAttributes[0] == ("env", "prod")
    check cfg.resourceAttributes[1] == ("region", "us-east-1")

suite "programmatic override":
  test "fields set after loadFromEnv take precedence":
    putEnv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://env-collector:4318")
    var cfg = loadFromEnv()
    delEnv("OTEL_EXPORTER_OTLP_ENDPOINT")
    cfg.endpoint = "http://programmatic:9999"
    check cfg.endpoint == "http://programmatic:9999"

  test "serviceName set after loadFromEnv overrides env var":
    putEnv("OTEL_SERVICE_NAME", "env-service")
    var cfg = loadFromEnv()
    delEnv("OTEL_SERVICE_NAME")
    cfg.serviceName = "my-service"
    check cfg.serviceName == "my-service"
