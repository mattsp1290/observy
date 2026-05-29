#!/usr/bin/env python3
"""
Generate golden binary proto3 fixtures and JSON fixtures for the observy test suite.

Proto fixtures: tests/fixtures/proto/*.bin  — individual signal message binary
JSON fixtures:  tests/fixtures/json/*.json  — OTLP-JSON encoded signal snippets

Usage:
    python3 tools/gen_fixtures.py
"""

import os
import json
import struct

PROTO_DIR = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "proto")
JSON_DIR  = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures", "json")

os.makedirs(PROTO_DIR, exist_ok=True)
os.makedirs(JSON_DIR,  exist_ok=True)

# ---------------------------------------------------------------------------
# Proto imports
# ---------------------------------------------------------------------------
from opentelemetry.proto.trace.v1.trace_pb2 import Span, Status
from opentelemetry.proto.metrics.v1.metrics_pb2 import (
    Metric, NumberDataPoint, Gauge, Sum, Histogram, HistogramDataPoint,
    ExponentialHistogram, ExponentialHistogramDataPoint, Summary, SummaryDataPoint,
    AggregationTemporality,
)
from opentelemetry.proto.logs.v1.logs_pb2 import LogRecord, SeverityNumber
from opentelemetry.proto.common.v1.common_pb2 import (
    KeyValue, AnyValue, ArrayValue, KeyValueList,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def kv_str(key, val):
    return KeyValue(key=key, value=AnyValue(string_value=val))

def kv_int(key, val):
    return KeyValue(key=key, value=AnyValue(int_value=val))

def kv_dbl(key, val):
    return KeyValue(key=key, value=AnyValue(double_value=val))

def kv_bool(key, val):
    return KeyValue(key=key, value=AnyValue(bool_value=val))

def kv_bytes(key, val):
    return KeyValue(key=key, value=AnyValue(bytes_value=val))

def write_bin(name, msg):
    path = os.path.join(PROTO_DIR, name)
    data = msg.SerializeToString()
    with open(path, "wb") as f:
        f.write(data)
    print(f"  {name}: {len(data)} bytes")

def write_json(name, obj):
    path = os.path.join(JSON_DIR, name)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
    print(f"  {name}")

# ---------------------------------------------------------------------------
# Proto fixtures
# ---------------------------------------------------------------------------

def gen_proto():
    print("Generating proto fixtures...")

    # minimal_span.bin — required fields only
    tid = bytes.fromhex("4bf92f3577b34da6a3ce929d0e0e4736")
    sid = bytes.fromhex("00f067aa0ba902b7")
    span = Span(
        trace_id=tid,
        span_id=sid,
        name="GET /api/users",
        kind=Span.SPAN_KIND_SERVER,
        start_time_unix_nano=1_000_000_000_000_000_000,
        end_time_unix_nano=1_000_000_001_000_000_000,
    )
    write_bin("minimal_span.bin", span)

    # full_span.bin — all fields
    parent_sid = bytes.fromhex("aabbccdd11223344")
    link_tid   = bytes.fromhex("ffffffffffffffffffffffffffffffff")
    link_sid   = bytes.fromhex("1122334455667788")
    span_full = Span(
        trace_id=tid,
        span_id=sid,
        parent_span_id=parent_sid,
        trace_state="rojo=00f067aa0ba902b7",
        name="POST /api/users",
        kind=Span.SPAN_KIND_SERVER,
        start_time_unix_nano=1_000_000_000_000_000_000,
        end_time_unix_nano=1_000_000_002_000_000_000,
        attributes=[
            kv_str("http.method", "POST"),
            kv_str("http.url", "https://api.example.com/users"),
            kv_int("http.status_code", 201),
            kv_dbl("latency.ms", 12.5),
            kv_bool("http.success", True),
            kv_bytes("request.id", b"\x01\x02\x03\x04"),
        ],
        dropped_attributes_count=0,
        events=[
            Span.Event(
                time_unix_nano=1_000_000_000_500_000_000,
                name="user.created",
                attributes=[kv_str("user.id", "u-12345")],
            ),
        ],
        dropped_events_count=0,
        links=[
            Span.Link(
                trace_id=link_tid,
                span_id=link_sid,
                trace_state="",
                attributes=[kv_str("link.type", "child_of")],
            ),
        ],
        dropped_links_count=0,
        status=Status(code=Status.STATUS_CODE_OK, message=""),
        flags=1,
    )
    write_bin("full_span.bin", span_full)

    # counter_metric.bin — Sum, monotonic, cumulative, one NumberDataPoint
    counter = Metric(
        name="http.requests.total",
        description="Total HTTP requests",
        unit="{request}",
        sum=Sum(
            data_points=[
                NumberDataPoint(
                    attributes=[kv_str("http.method", "GET")],
                    start_time_unix_nano=1_000_000_000_000_000_000,
                    time_unix_nano=1_001_000_000_000_000_000,
                    as_int=42,
                    flags=0,
                ),
            ],
            aggregation_temporality=AggregationTemporality.AGGREGATION_TEMPORALITY_CUMULATIVE,
            is_monotonic=True,
        ),
    )
    write_bin("counter_metric.bin", counter)

    # histogram_metric.bin — one HistogramDataPoint with explicit bounds
    histo = Metric(
        name="http.request.duration",
        description="Request latency",
        unit="ms",
        histogram=Histogram(
            data_points=[
                HistogramDataPoint(
                    attributes=[kv_str("http.method", "GET")],
                    start_time_unix_nano=1_000_000_000_000_000_000,
                    time_unix_nano=1_001_000_000_000_000_000,
                    count=10,
                    sum=250.0,
                    bucket_counts=[2, 3, 4, 1],
                    explicit_bounds=[10.0, 50.0, 200.0],
                    flags=0,
                    min=5.0,
                    max=190.0,
                ),
            ],
            aggregation_temporality=AggregationTemporality.AGGREGATION_TEMPORALITY_DELTA,
        ),
    )
    write_bin("histogram_metric.bin", histo)

    # exp_histogram_metric.bin — ExponentialHistogramDataPoint with scale and buckets
    exp_histo = Metric(
        name="request.size",
        description="Request size distribution",
        unit="By",
        exponential_histogram=ExponentialHistogram(
            data_points=[
                ExponentialHistogramDataPoint(
                    attributes=[kv_str("service", "api")],
                    start_time_unix_nano=1_000_000_000_000_000_000,
                    time_unix_nano=1_001_000_000_000_000_000,
                    count=7,
                    sum=1024.0,
                    scale=2,
                    zero_count=1,
                    positive=ExponentialHistogramDataPoint.Buckets(
                        offset=0,
                        bucket_counts=[2, 3, 1],
                    ),
                    negative=ExponentialHistogramDataPoint.Buckets(
                        offset=0,
                        bucket_counts=[],
                    ),
                    flags=0,
                    min=64.0,
                    max=512.0,
                    zero_threshold=0.5,
                ),
            ],
            aggregation_temporality=AggregationTemporality.AGGREGATION_TEMPORALITY_CUMULATIVE,
        ),
    )
    write_bin("exp_histogram_metric.bin", exp_histo)

    # summary_metric.bin — one SummaryDataPoint
    summary = Metric(
        name="response.time.summary",
        description="Response time summary",
        unit="s",
        summary=Summary(
            data_points=[
                SummaryDataPoint(
                    attributes=[kv_str("endpoint", "/api")],
                    start_time_unix_nano=1_000_000_000_000_000_000,
                    time_unix_nano=1_001_000_000_000_000_000,
                    count=100,
                    sum=45.7,
                    quantile_values=[
                        SummaryDataPoint.ValueAtQuantile(quantile=0.5,  value=0.35),
                        SummaryDataPoint.ValueAtQuantile(quantile=0.95, value=1.2),
                        SummaryDataPoint.ValueAtQuantile(quantile=0.99, value=2.5),
                    ],
                    flags=0,
                ),
            ],
        ),
    )
    write_bin("summary_metric.bin", summary)

    # log_record.bin — all LogRecord fields available in this SDK version
    # (event_name field 12 added in proto v1.10+ may not be in older SDK bundles)
    log = LogRecord(
        time_unix_nano=1_000_000_000_000_000_000,
        observed_time_unix_nano=1_000_000_000_100_000_000,
        severity_number=SeverityNumber.SEVERITY_NUMBER_INFO,
        severity_text="INFO",
        body=AnyValue(string_value="user login succeeded"),
        attributes=[
            kv_str("user.id", "u-99999"),
            kv_str("ip", "192.168.1.1"),
            kv_int("attempt", 1),
        ],
        dropped_attributes_count=0,
        flags=1,
        trace_id=tid,
        span_id=sid,
    )
    write_bin("log_record.bin", log)

    print("Proto fixtures done.\n")


# ---------------------------------------------------------------------------
# JSON fixtures — hand-authored reference documents for OTLP JSON encoding rules
# ---------------------------------------------------------------------------

def gen_json():
    print("Generating JSON fixtures...")

    # trace_id_hex.json — traceId must be 32-char lowercase hex (NOT base64)
    write_json("trace_id_hex.json", {
        "_comment": "traceId MUST be 32 lowercase hex chars, not base64",
        "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
        "spanId":  "00f067aa0ba902b7",
    })

    # span_id_hex.json — spanId is 16-char lowercase hex
    write_json("span_id_hex.json", {
        "_comment": "spanId MUST be 16 lowercase hex chars",
        "spanId": "00f067aa0ba902b7",
    })

    # bytes_base64.json — bytes attribute value is base64 (NOT hex)
    write_json("bytes_base64.json", {
        "_comment": "bytes attribute uses standard base64 (no URL-safe, no line breaks)",
        "attributes": [
            {"key": "request.id", "value": {"bytesValue": "AQIDBA=="}},
        ],
    })

    # int64_string.json — int64 fields are JSON strings, not numbers
    write_json("int64_string.json", {
        "_comment": "int64/uint64 fields MUST be JSON strings to preserve precision",
        "startTimeUnixNano": "1000000000000000000",
        "endTimeUnixNano":   "1000000001000000000",
        "intAttribute": {"intValue": "9223372036854775807"},
    })

    # full_span.json — complete span exercising all OTLP-JSON encoding rules
    write_json("full_span.json", {
        "traceId":       "4bf92f3577b34da6a3ce929d0e0e4736",
        "spanId":        "00f067aa0ba902b7",
        "parentSpanId":  "aabbccdd11223344",
        "traceState":    "rojo=00f067aa0ba902b7",
        "name":          "POST /api/users",
        "kind":          2,
        "startTimeUnixNano": "1000000000000000000",
        "endTimeUnixNano":   "1000000002000000000",
        "attributes": [
            {"key": "http.method",      "value": {"stringValue": "POST"}},
            {"key": "http.status_code", "value": {"intValue": "201"}},
            {"key": "latency.ms",       "value": {"doubleValue": 12.5}},
            {"key": "http.success",     "value": {"boolValue": True}},
            {"key": "request.id",       "value": {"bytesValue": "AQIDBA=="}},
        ],
        "droppedAttributesCount": 0,
        "events": [
            {
                "timeUnixNano": "1000000000500000000",
                "name": "user.created",
                "attributes": [
                    {"key": "user.id", "value": {"stringValue": "u-12345"}},
                ],
            },
        ],
        "links": [
            {
                "traceId": "ffffffffffffffffffffffffffffffff",
                "spanId":  "1122334455667788",
                "attributes": [],
            },
        ],
        "status": {"code": 1, "message": ""},
        "flags": 1,
    })

    print("JSON fixtures done.\n")


if __name__ == "__main__":
    gen_proto()
    gen_json()
    print("All fixtures generated.")
