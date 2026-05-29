import unittest
import std/options
import std/json
import ../src/observy/anyvalue
import ../src/observy/proto
import ../src/observy/resource
import ../src/observy/traces
import ../src/observy/metrics
import ./testutil

suite "Metrics data model":
  test "AggregationTemporality values match OTLP spec":
    check ord(aggTempUnspecified) == 0
    check ord(aggTempDelta)       == 1
    check ord(aggTempCumulative)  == 2

  test "Exemplar double variant":
    var sid: SpanId
    var tid: TraceId
    sid[0] = 0x01'u8
    tid[0] = 0x02'u8
    let ex = Exemplar(
      filteredAttributes: @[KeyValue(key: "k", value: AnyValue(kind: avInt, intVal: 1))],
      timeUnixNano: 1000'u64,
      spanId: sid,
      traceId: tid,
      kind: evDouble,
      doubleValue: 3.14,
    )
    check ex.kind == evDouble
    check ex.doubleValue == 3.14
    check ex.spanId[0] == 0x01'u8
    check ex.traceId[0] == 0x02'u8
    check ex.filteredAttributes.len == 1

  test "Exemplar int variant":
    let ex = Exemplar(
      filteredAttributes: @[],
      timeUnixNano: 500'u64,
      kind: evInt,
      intValue: -42'i64,
    )
    check ex.kind == evInt
    check ex.intValue == -42'i64

  test "NumberDataPoint double variant":
    let dp = NumberDataPoint(
      attributes: initAttributeSet(),
      startTimeUnixNano: 100'u64,
      timeUnixNano: 200'u64,
      exemplars: @[],
      flags: 0'u32,
      kind: ndpDouble,
      doubleValue: 42.0,
    )
    check dp.kind == ndpDouble
    check dp.doubleValue == 42.0

  test "NumberDataPoint int variant":
    let dp = NumberDataPoint(
      attributes: initAttributeSet(),
      startTimeUnixNano: 100'u64,
      timeUnixNano: 200'u64,
      exemplars: @[],
      flags: 0'u32,
      kind: ndpInt,
      intValue: -7'i64,
    )
    check dp.kind == ndpInt
    check dp.intValue == -7'i64

  test "HistogramDataPoint construction with optional sum/min/max":
    let dp = HistogramDataPoint(
      attributes: initAttributeSet(),
      startTimeUnixNano: 0'u64,
      timeUnixNano: 1000'u64,
      count: 10'u64,
      sum: some(100.0),
      bucketCounts: @[2'u64, 3'u64, 5'u64],
      explicitBounds: @[1.0, 10.0],
      exemplars: @[],
      flags: 0'u32,
      min: some(1.0),
      max: some(50.0),
    )
    check dp.count == 10'u64
    check dp.bucketCounts.len == 3
    check dp.explicitBounds.len == 2
    check dp.sum == some(100.0)
    check dp.min == some(1.0)
    check dp.max == some(50.0)

  test "HistogramDataPoint with absent sum/min/max":
    let dp = HistogramDataPoint(
      attributes: initAttributeSet(),
      startTimeUnixNano: 0'u64,
      timeUnixNano: 1000'u64,
      count: 5'u64,
      bucketCounts: @[2'u64, 3'u64],
      explicitBounds: @[5.0],
      exemplars: @[],
      flags: 0'u32,
    )
    check dp.sum.isNone
    check dp.min.isNone
    check dp.max.isNone

  test "ExponentialHistogramBuckets construction":
    let b = ExponentialHistogramBuckets(offset: -5'i32, bucketCounts: @[1'u64, 2'u64, 3'u64])
    check b.offset == -5'i32
    check b.bucketCounts.len == 3

  test "ExponentialHistogramDataPoint construction":
    let dp = ExponentialHistogramDataPoint(
      attributes: initAttributeSet(),
      startTimeUnixNano: 0'u64,
      timeUnixNano: 1000'u64,
      count: 5'u64,
      sum: some(25.5),
      scale: 2'i32,
      zeroCount: 0'u64,
      positive: ExponentialHistogramBuckets(offset: 0'i32, bucketCounts: @[1'u64, 2'u64]),
      negative: ExponentialHistogramBuckets(offset: 0'i32, bucketCounts: @[]),
      flags: 0'u32,
      exemplars: @[],
      min: some(1.0),
      max: some(10.0),
      zeroThreshold: 0.0,
    )
    check dp.scale == 2'i32
    check dp.positive.bucketCounts.len == 2
    check dp.zeroCount == 0'u64
    check dp.sum == some(25.5)

  test "SummaryDataPoint construction":
    let dp = SummaryDataPoint(
      attributes: initAttributeSet(),
      startTimeUnixNano: 0'u64,
      timeUnixNano: 1000'u64,
      count: 100'u64,
      sum: 500.0,
      quantileValues: @[
        ValueAtQuantile(quantile: 0.5, value: 4.5),
        ValueAtQuantile(quantile: 0.99, value: 9.9),
      ],
      flags: 0'u32,
    )
    check dp.count == 100'u64
    check dp.quantileValues.len == 2
    check dp.quantileValues[0].quantile == 0.5

  test "MetricGauge construction":
    let dp = NumberDataPoint(
      attributes: initAttributeSet(), startTimeUnixNano: 0'u64, timeUnixNano: 100'u64,
      exemplars: @[], flags: 0'u32,
      kind: ndpDouble, doubleValue: 1.5,
    )
    let g = MetricGauge(dataPoints: @[dp])
    check g.dataPoints.len == 1

  test "MetricSum construction":
    let dp = NumberDataPoint(
      attributes: initAttributeSet(), startTimeUnixNano: 0'u64, timeUnixNano: 100'u64,
      exemplars: @[], flags: 0'u32,
      kind: ndpInt, intValue: 42'i64,
    )
    let s = MetricSum(
      dataPoints: @[dp],
      aggregationTemporality: aggTempCumulative,
      isMonotonic: true,
    )
    check s.isMonotonic == true
    check s.aggregationTemporality == aggTempCumulative

  test "Metric case object - gauge kind":
    let m = Metric(
      name: "system.cpu.usage",
      description: "CPU usage",
      unit: "1",
      kind: mkGauge,
      gauge: MetricGauge(dataPoints: @[]),
    )
    check m.name == "system.cpu.usage"
    check m.kind == mkGauge
    check m.gauge.dataPoints.len == 0

  test "Metric case object - sum kind":
    let m = Metric(
      name: "http.requests",
      description: "Total HTTP requests",
      unit: "{request}",
      kind: mkSum,
      sum: MetricSum(
        dataPoints: @[],
        aggregationTemporality: aggTempCumulative,
        isMonotonic: true,
      ),
    )
    check m.kind == mkSum
    check m.sum.isMonotonic == true

  test "Metric case object - histogram kind":
    let m = Metric(
      name: "http.request.duration",
      description: "Request latency",
      unit: "ms",
      kind: mkHistogram,
      histogram: MetricHistogram(
        dataPoints: @[],
        aggregationTemporality: aggTempDelta,
      ),
    )
    check m.kind == mkHistogram
    check m.histogram.aggregationTemporality == aggTempDelta

  test "Metric case object - exp histogram kind":
    let m = Metric(
      name: "latency",
      description: "",
      unit: "s",
      kind: mkExpHistogram,
      expHistogram: MetricExpHistogram(
        dataPoints: @[],
        aggregationTemporality: aggTempCumulative,
      ),
    )
    check m.kind == mkExpHistogram

  test "Metric case object - summary kind":
    let m = Metric(
      name: "response_size",
      description: "",
      unit: "By",
      kind: mkSummary,
      summary: MetricSummary(dataPoints: @[]),
    )
    check m.kind == mkSummary

  test "Metric metadata field":
    let m = Metric(
      name: "custom.metric",
      description: "",
      unit: "1",
      metadata: @[KeyValue(key: "team", value: AnyValue(kind: avString, strVal: "ops"))],
      kind: mkGauge,
      gauge: MetricGauge(dataPoints: @[]),
    )
    check m.metadata.len == 1
    check m.metadata[0].key == "team"

# ---------------------------------------------------------------------------
# Proto encoding — golden-byte fixture tests
# Construct the same metric as tools/gen_fixtures.py and compare byte-for-byte.
# ---------------------------------------------------------------------------

proc makeCounter(): Metric =
  var attrs = initAttributeSet()
  attrs.add("http.method", AnyValue(kind: avString, strVal: "GET"))
  Metric(
    name: "http.requests.total",
    description: "Total HTTP requests",
    unit: "{request}",
    kind: mkSum,
    sum: MetricSum(
      dataPoints: @[NumberDataPoint(
        attributes: attrs,
        startTimeUnixNano: 1_000_000_000_000_000_000'u64,
        timeUnixNano: 1_001_000_000_000_000_000'u64,
        kind: ndpInt, intValue: 42'i64,
      )],
      aggregationTemporality: aggTempCumulative,
      isMonotonic: true,
    ),
  )

proc makeHistogram(): Metric =
  var attrs = initAttributeSet()
  attrs.add("http.method", AnyValue(kind: avString, strVal: "GET"))
  Metric(
    name: "http.request.duration",
    description: "Request latency",
    unit: "ms",
    kind: mkHistogram,
    histogram: MetricHistogram(
      dataPoints: @[HistogramDataPoint(
        attributes: attrs,
        startTimeUnixNano: 1_000_000_000_000_000_000'u64,
        timeUnixNano: 1_001_000_000_000_000_000'u64,
        count: 10'u64,
        sum: some(250.0),
        bucketCounts: @[2'u64, 3, 4, 1],
        explicitBounds: @[10.0, 50.0, 200.0],
        min: some(5.0),
        max: some(190.0),
      )],
      aggregationTemporality: aggTempDelta,
    ),
  )

proc makeExpHistogram(): Metric =
  var attrs = initAttributeSet()
  attrs.add("service", AnyValue(kind: avString, strVal: "api"))
  Metric(
    name: "request.size",
    description: "Request size distribution",
    unit: "By",
    kind: mkExpHistogram,
    expHistogram: MetricExpHistogram(
      dataPoints: @[ExponentialHistogramDataPoint(
        attributes: attrs,
        startTimeUnixNano: 1_000_000_000_000_000_000'u64,
        timeUnixNano: 1_001_000_000_000_000_000'u64,
        count: 7'u64,
        sum: some(1024.0),
        scale: 2'i32,
        zeroCount: 1'u64,
        positive: ExponentialHistogramBuckets(offset: 0'i32, bucketCounts: @[2'u64, 3, 1]),
        negative: ExponentialHistogramBuckets(offset: 0'i32, bucketCounts: @[]),
        flags: 1'u32,
        min: some(64.0),
        max: some(512.0),
        zeroThreshold: 0.5,
      )],
      aggregationTemporality: aggTempCumulative,
    ),
  )

proc makeSummary(): Metric =
  var attrs = initAttributeSet()
  attrs.add("endpoint", AnyValue(kind: avString, strVal: "/api"))
  Metric(
    name: "response.time.summary",
    description: "Response time summary",
    unit: "s",
    kind: mkSummary,
    summary: MetricSummary(
      dataPoints: @[SummaryDataPoint(
        attributes: attrs,
        startTimeUnixNano: 1_000_000_000_000_000_000'u64,
        timeUnixNano: 1_001_000_000_000_000_000'u64,
        count: 100'u64,
        sum: 45.7,
        quantileValues: @[
          ValueAtQuantile(quantile: 0.5,  value: 0.35),
          ValueAtQuantile(quantile: 0.95, value: 1.2),
          ValueAtQuantile(quantile: 0.99, value: 2.5),
        ],
      )],
    ),
  )

suite "Metrics proto golden-byte fixtures":
  test "counter_metric.bin — Sum, sfixed64 as_int, cumulative, monotonic":
    var w: ProtoWriter
    protoEncodeMetric(w, makeCounter())
    check w.buf == readBin("tests/fixtures/proto/counter_metric.bin")

  test "histogram_metric.bin — fixed64 count, packed-fixed64 buckets, packed-double bounds, optional min/max":
    var w: ProtoWriter
    protoEncodeMetric(w, makeHistogram())
    check w.buf == readBin("tests/fixtures/proto/histogram_metric.bin")

  test "exp_histogram_metric.bin — sint32 scale, fixed64 zeroCount, packed-varint buckets, omitted empty negative":
    var w: ProtoWriter
    protoEncodeMetric(w, makeExpHistogram())
    check w.buf == readBin("tests/fixtures/proto/exp_histogram_metric.bin")

  test "summary_metric.bin — fixed64 count, quantile values":
    var w: ProtoWriter
    protoEncodeMetric(w, makeSummary())
    check w.buf == readBin("tests/fixtures/proto/summary_metric.bin")

suite "Metrics JSON encoding":
  test "counter (Sum) — asInt is quoted string, temporality is int, isMonotonic bool":
    let j = parseJson(jsonEncodeMetric(makeCounter()))
    let dp = j["sum"]["dataPoints"][0]
    check dp["asInt"].kind == JString
    check dp["asInt"].getStr() == "42"
    check dp["startTimeUnixNano"].kind == JString
    check j["sum"]["aggregationTemporality"].getInt() == 2
    check j["sum"]["isMonotonic"].getBool() == true

  test "histogram — count/bucketCounts are strings, sum/bounds are numbers":
    let j = parseJson(jsonEncodeMetric(makeHistogram()))
    let dp = j["histogram"]["dataPoints"][0]
    check dp["count"].kind == JString
    check dp["count"].getStr() == "10"
    check dp["bucketCounts"][0].kind == JString
    check dp["bucketCounts"].len == 4
    check dp["sum"].getFloat() == 250.0
    check dp["explicitBounds"][0].getFloat() == 10.0
    check dp["min"].getFloat() == 5.0
    check dp["max"].getFloat() == 190.0

  test "exp histogram — scale is number, zeroCount string, positive buckets, omitted negative":
    let j = parseJson(jsonEncodeMetric(makeExpHistogram()))
    let dp = j["exponentialHistogram"]["dataPoints"][0]
    check dp["scale"].kind == JInt
    check dp["scale"].getInt() == 2
    check dp["zeroCount"].kind == JString
    check dp["zeroCount"].getStr() == "1"
    check dp["positive"]["bucketCounts"].len == 3
    check dp["positive"]["bucketCounts"][0].getStr() == "2"
    check not dp.hasKey("negative")    # empty negative omitted
    check dp["flags"].getInt() == 1
    check dp["zeroThreshold"].getFloat() == 0.5

  test "summary — count string, quantile values are numbers":
    let j = parseJson(jsonEncodeMetric(makeSummary()))
    let dp = j["summary"]["dataPoints"][0]
    check dp["count"].kind == JString
    check dp["count"].getStr() == "100"
    check dp["quantileValues"].len == 3
    check dp["quantileValues"][0]["quantile"].getFloat() == 0.5
    check dp["quantileValues"][0]["value"].getFloat() == 0.35

  test "metricToJson produces ExportMetricsServiceRequest structure":
    let j = parseJson(metricToJson(
      Resource(attributes: initAttributeSet()),
      InstrumentationScope(attributes: initAttributeSet()),
      @[makeCounter()]))
    check j.hasKey("resourceMetrics")
    check j["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["name"].getStr() == "http.requests.total"

  test "gauge JSON uses asDouble number":
    let m = Metric(name: "temp", kind: mkGauge,
      gauge: MetricGauge(dataPoints: @[NumberDataPoint(
        attributes: initAttributeSet(), timeUnixNano: 5'u64,
        kind: ndpDouble, doubleValue: 21.5)]))
    let j = parseJson(jsonEncodeMetric(m))
    let dp = j["gauge"]["dataPoints"][0]
    check dp["asDouble"].getFloat() == 21.5
    check dp["timeUnixNano"].getStr() == "5"
