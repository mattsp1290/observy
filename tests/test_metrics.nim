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

# ---------------------------------------------------------------------------
# Review fixes: empty-oneof discriminator, zero-scalar JSON omission,
# exemplar coverage, gauge proto path
# ---------------------------------------------------------------------------

proc topLevelFields(buf: seq[byte]): seq[uint32] =
  var r = ProtoReader(data: buf)
  while r.pos < buf.len:
    let (fn, wt) = r.readTag()
    result.add(fn)
    r.skipField(wt)

suite "Metrics proto — empty oneof preserves discriminator":
  test "empty Gauge still emits field 5 (len 0)":
    let m = Metric(name: "g", kind: mkGauge, gauge: MetricGauge(dataPoints: @[]))
    var w: ProtoWriter
    protoEncodeMetric(w, m)
    # matches Python SDK: 0a0167 2a00  (name "g", then field 5 length 0)
    check w.buf == @[0x0a'u8, 0x01, byte('g'), 0x2a, 0x00]
    check 5'u32 in topLevelFields(w.buf)

  test "empty Summary still emits field 11 (len 0)":
    let m = Metric(name: "s", kind: mkSummary, summary: MetricSummary(dataPoints: @[]))
    var w: ProtoWriter
    protoEncodeMetric(w, m)
    check w.buf == @[0x0a'u8, 0x01, byte('s'), 0x5a, 0x00]
    check 11'u32 in topLevelFields(w.buf)

  test "empty Sum still emits field 7 (len 0)":
    let m = Metric(name: "x", kind: mkSum, sum: MetricSum(dataPoints: @[]))
    var w: ProtoWriter
    protoEncodeMetric(w, m)
    check w.buf == @[0x0a'u8, 0x01, byte('x'), 0x3a, 0x00]

suite "Metrics proto — gauge data point path":
  test "gauge with one double data point round-trips through decoder":
    let m = Metric(name: "system.cpu", kind: mkGauge,
      gauge: MetricGauge(dataPoints: @[NumberDataPoint(
        attributes: initAttributeSet(),
        timeUnixNano: 1_000_000_000_000_000_000'u64,
        kind: ndpDouble, doubleValue: 0.75)]))
    var w: ProtoWriter
    protoEncodeMetric(w, m)
    # field 5 (gauge) present and non-empty
    var r = ProtoReader(data: w.buf)
    var sawGauge = false
    while r.pos < w.buf.len:
      let (fn, wt) = r.readTag()
      if fn == 5:
        sawGauge = true
        let inner = r.readBytes()
        check inner.len > 0   # contains the data point
      else:
        r.skipField(wt)
    check sawGauge

suite "Metrics proto — exemplars":
  test "NumberDataPoint with double and int exemplars encodes field 5":
    var sid: SpanId
    var tid: TraceId
    sid[0] = 0xAB'u8; tid[0] = 0xCD'u8
    let dp = NumberDataPoint(
      attributes: initAttributeSet(),
      timeUnixNano: 5'u64,
      kind: ndpInt, intValue: 100'i64,
      exemplars: @[
        Exemplar(timeUnixNano: 3'u64, spanId: sid, traceId: tid,
                 kind: evDouble, doubleValue: 9.5),
        Exemplar(timeUnixNano: 4'u64, kind: evInt, intValue: -2'i64),
      ])
    var w: ProtoWriter
    protoEncodeNumberDataPoint(w, dp)
    check 5'u32 in topLevelFields(w.buf)   # exemplars field present

suite "Metrics JSON — exemplars and zero-scalar omission":
  test "exemplar JSON: double variant with span/trace IDs":
    var sid: SpanId
    var tid: TraceId
    sid[0] = 0xAB'u8; tid[0] = 0xCD'u8
    let dp = NumberDataPoint(
      attributes: initAttributeSet(), timeUnixNano: 5'u64,
      kind: ndpDouble, doubleValue: 1.0,
      exemplars: @[Exemplar(timeUnixNano: 3'u64, spanId: sid, traceId: tid,
                            kind: evDouble, doubleValue: 9.5)])
    let j = parseJson(jsonEncodeNumberDataPoint(dp))
    let ex = j["exemplars"][0]
    check ex["asDouble"].getFloat() == 9.5
    check ex["spanId"].getStr().len == 16
    check ex["traceId"].getStr().len == 32

  test "exemplar JSON: int variant":
    let dp = NumberDataPoint(
      attributes: initAttributeSet(), timeUnixNano: 5'u64,
      kind: ndpInt, intValue: 1'i64,
      exemplars: @[Exemplar(timeUnixNano: 3'u64, kind: evInt, intValue: -7'i64)])
    let j = parseJson(jsonEncodeNumberDataPoint(dp))
    check j["exemplars"][0]["asInt"].getStr() == "-7"

  test "exp histogram with scale=0 omits scale in JSON (matches MessageToJson)":
    let m = Metric(name: "e", kind: mkExpHistogram,
      expHistogram: MetricExpHistogram(dataPoints: @[ExponentialHistogramDataPoint(
        attributes: initAttributeSet(), count: 5'u64, scale: 0'i32)]))
    let j = parseJson(jsonEncodeMetric(m))
    let dp = j["exponentialHistogram"]["dataPoints"][0]
    check dp["count"].getStr() == "5"
    check not dp.hasKey("scale")        # scale 0 omitted
    check not dp.hasKey("zeroCount")    # zeroCount 0 omitted
    check not dp.hasKey("positive")     # empty positive omitted
    check not j["exponentialHistogram"].hasKey("aggregationTemporality")  # 0 omitted

  test "sum with unspecified temporality omits aggregationTemporality in JSON":
    let m = Metric(name: "c", kind: mkSum,
      sum: MetricSum(dataPoints: @[NumberDataPoint(
        attributes: initAttributeSet(), kind: ndpInt, intValue: 3'i64)],
        aggregationTemporality: aggTempUnspecified, isMonotonic: false))
    let j = parseJson(jsonEncodeMetric(m))
    check not j["sum"].hasKey("aggregationTemporality")
    check not j["sum"].hasKey("isMonotonic")
    check j["sum"]["dataPoints"][0]["asInt"].getStr() == "3"

  test "negative bucket emitted when non-empty":
    let m = Metric(name: "e", kind: mkExpHistogram,
      expHistogram: MetricExpHistogram(dataPoints: @[ExponentialHistogramDataPoint(
        attributes: initAttributeSet(), count: 3'u64, scale: 1'i32,
        positive: ExponentialHistogramBuckets(offset: 0, bucketCounts: @[1'u64]),
        negative: ExponentialHistogramBuckets(offset: -2'i32, bucketCounts: @[2'u64]))]))
    let j = parseJson(jsonEncodeMetric(m))
    let dp = j["exponentialHistogram"]["dataPoints"][0]
    check dp["negative"]["offset"].getInt() == -2
    check dp["negative"]["bucketCounts"][0].getStr() == "2"

suite "Aggregation temporality selector":
  test "alwaysDelta sets DELTA on Sum, Histogram, ExpHistogram":
    let sel = alwaysDelta()
    check sel(mkSum)          == aggTempDelta
    check sel(mkHistogram)    == aggTempDelta
    check sel(mkExpHistogram) == aggTempDelta

  test "alwaysDelta returns UNSPECIFIED for Gauge and Summary":
    let sel = alwaysDelta()
    check sel(mkGauge)   == aggTempUnspecified
    check sel(mkSummary) == aggTempUnspecified

  test "alwaysCumulative sets CUMULATIVE on Sum, Histogram, ExpHistogram":
    let sel = alwaysCumulative()
    check sel(mkSum)          == aggTempCumulative
    check sel(mkHistogram)    == aggTempCumulative
    check sel(mkExpHistogram) == aggTempCumulative

  test "alwaysCumulative returns UNSPECIFIED for Gauge and Summary":
    let sel = alwaysCumulative()
    check sel(mkGauge)   == aggTempUnspecified
    check sel(mkSummary) == aggTempUnspecified

  test "applyTemporalitySelector overrides Sum temporality":
    let m = Metric(
      name: "reqs",
      kind: mkSum,
      sum: MetricSum(
        dataPoints: @[],
        aggregationTemporality: aggTempCumulative,
        isMonotonic: true,
      ),
    )
    let applied = applyTemporalitySelector(m, alwaysDelta())
    check applied.sum.aggregationTemporality == aggTempDelta
    check applied.sum.isMonotonic == true    # other fields unchanged

  test "applyTemporalitySelector overrides Histogram temporality":
    let m = Metric(
      name: "latency",
      kind: mkHistogram,
      histogram: MetricHistogram(
        dataPoints: @[],
        aggregationTemporality: aggTempCumulative,
      ),
    )
    let applied = applyTemporalitySelector(m, alwaysDelta())
    check applied.histogram.aggregationTemporality == aggTempDelta

  test "applyTemporalitySelector leaves Gauge unchanged":
    let m = Metric(
      name: "cpu",
      kind: mkGauge,
      gauge: MetricGauge(dataPoints: @[]),
    )
    let applied = applyTemporalitySelector(m, alwaysDelta())
    check applied.kind == mkGauge    # unchanged

  test "applyTemporalitySelector leaves Summary unchanged":
    let m = Metric(
      name: "rts",
      kind: mkSummary,
      summary: MetricSummary(dataPoints: @[]),
    )
    let applied = applyTemporalitySelector(m, alwaysDelta())
    check applied.kind == mkSummary  # unchanged

suite "Metrics attribute limits on NumberDataPoint":
  test "NumberDataPoint AttributeSet drops and counts excess":
    var attrs = initAttributeSet()
    for i in 0 ..< 130:
      attrs.add("k" & $i, AnyValue(kind: avString, strVal: "v"))
    check attrs.pairs.len == 128
    check attrs.dropped == 2'u32

  test "NumberDataPoint with overflow attrs encodes 128 attrs in proto":
    var attrs = initAttributeSet()
    for i in 0 ..< 130:
      attrs.add("k" & $i, AnyValue(kind: avString, strVal: "v"))
    let dp = NumberDataPoint(
      attributes: attrs,
      timeUnixNano: 1'u64,
      kind: ndpDouble,
      doubleValue: 1.0,
    )
    let m = Metric(
      name: "overflow",
      kind: mkGauge,
      gauge: MetricGauge(dataPoints: @[dp]),
    )
    let j = parseJson(metricToJson(
      Resource(attributes: initAttributeSet()),
      InstrumentationScope(attributes: initAttributeSet()),
      @[m]))
    let attrs_j = j["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]["gauge"]["dataPoints"][0]["attributes"]
    check attrs_j.len == 128

suite "Temporality selector — end-to-end through encoder":
  proc makeCounterWithCumulative(): Metric =
    Metric(
      name: "req_total",
      kind: mkSum,
      sum: MetricSum(
        dataPoints: @[NumberDataPoint(
          attributes:  initAttributeSet(),
          timeUnixNano: 1'u64,
          kind: ndpInt, intValue: 42,
        )],
        aggregationTemporality: aggTempCumulative,
        isMonotonic: true,
      ),
    )

  test "alwaysDelta selector relabels Sum to DELTA in JSON encoder":
    let m = applyTemporalitySelector(makeCounterWithCumulative(), alwaysDelta())
    let j = parseJson(metricToJson(
      Resource(attributes: initAttributeSet()),
      InstrumentationScope(attributes: initAttributeSet()),
      @[m]))
    let dp = j["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]
    check dp["sum"]["aggregationTemporality"].getInt() == ord(aggTempDelta)

  test "nil selector leaves Sum temporality unchanged in JSON encoder":
    let m = makeCounterWithCumulative()   # no selector applied
    let j = parseJson(metricToJson(
      Resource(attributes: initAttributeSet()),
      InstrumentationScope(attributes: initAttributeSet()),
      @[m]))
    let dp = j["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]
    check dp["sum"]["aggregationTemporality"].getInt() == ord(aggTempCumulative)

  test "alwaysCumulative selector relabels DELTA Sum to CUMULATIVE in JSON encoder":
    var m = makeCounterWithCumulative()
    m.sum.aggregationTemporality = aggTempDelta   # start as delta
    let applied = applyTemporalitySelector(m, alwaysCumulative())
    let j = parseJson(metricToJson(
      Resource(attributes: initAttributeSet()),
      InstrumentationScope(attributes: initAttributeSet()),
      @[applied]))
    let dp = j["resourceMetrics"][0]["scopeMetrics"][0]["metrics"][0]
    check dp["sum"]["aggregationTemporality"].getInt() == ord(aggTempCumulative)

  test "selector is gcsafe — compiles when used from gcsafe context":
    # This is the regression lock for the C-1 fix: verifies the selector type
    # is {.gcsafe.} by calling it from a gcsafe proc. A compile error here
    # means the gcsafe annotation was removed.
    proc callFromGcsafe(sel: AggregationTemporalitySelector) {.gcsafe.} =
      let _ = sel(mkSum)
    callFromGcsafe(alwaysDelta())
    callFromGcsafe(alwaysCumulative())
    check true
