import unittest
import ../src/observy/anyvalue
import ../src/observy/traces
import ../src/observy/metrics

suite "Metrics data model":
  test "AggregationTemporality values match OTLP spec":
    check ord(aggTempUnspecified) == 0
    check ord(aggTempDelta)       == 1
    check ord(aggTempCumulative)  == 2

  test "Exemplar construction":
    var sid: SpanId
    var tid: TraceId
    sid[0] = 0x01'u8
    tid[0] = 0x02'u8
    let ex = Exemplar(
      filteredAttributes: @[KeyValue(key: "k", value: AnyValue(kind: avInt, intVal: 1))],
      timeUnixNano: 1000'u64,
      value: 3.14,
      spanId: sid,
      traceId: tid,
    )
    check ex.value == 3.14
    check ex.spanId[0] == 0x01'u8
    check ex.traceId[0] == 0x02'u8
    check ex.filteredAttributes.len == 1

  test "NumberDataPoint double variant":
    let dp = NumberDataPoint(
      attributes: @[],
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
      attributes: @[],
      startTimeUnixNano: 100'u64,
      timeUnixNano: 200'u64,
      exemplars: @[],
      flags: 0'u32,
      kind: ndpInt,
      intValue: -7'i64,
    )
    check dp.kind == ndpInt
    check dp.intValue == -7'i64

  test "HistogramDataPoint construction":
    let dp = HistogramDataPoint(
      attributes: @[],
      startTimeUnixNano: 0'u64,
      timeUnixNano: 1000'u64,
      count: 10'u64,
      sum: 100.0,
      bucketCounts: @[2'u64, 3'u64, 5'u64],
      explicitBounds: @[1.0, 10.0],
      exemplars: @[],
      flags: 0'u32,
      min: 1.0,
      max: 50.0,
    )
    check dp.count == 10'u64
    check dp.bucketCounts.len == 3
    check dp.explicitBounds.len == 2

  test "Buckets construction":
    let b = Buckets(offset: -5'i32, bucketCounts: @[1'u64, 2'u64, 3'u64])
    check b.offset == -5'i32
    check b.bucketCounts.len == 3

  test "ExponentialHistogramDataPoint construction":
    let dp = ExponentialHistogramDataPoint(
      attributes: @[],
      startTimeUnixNano: 0'u64,
      timeUnixNano: 1000'u64,
      count: 5'u64,
      sum: 25.5,
      scale: 2'i32,
      zeroCount: 0'u64,
      positive: Buckets(offset: 0'i32, bucketCounts: @[1'u64, 2'u64]),
      negative: Buckets(offset: 0'i32, bucketCounts: @[]),
      flags: 0'u32,
      exemplars: @[],
      min: 1.0,
      max: 10.0,
      zeroThreshold: 0.0,
    )
    check dp.scale == 2'i32
    check dp.positive.bucketCounts.len == 2
    check dp.zeroCount == 0'u64

  test "SummaryDataPoint construction":
    let dp = SummaryDataPoint(
      attributes: @[],
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
      attributes: @[], startTimeUnixNano: 0'u64, timeUnixNano: 100'u64,
      exemplars: @[], flags: 0'u32,
      kind: ndpDouble, doubleValue: 1.5,
    )
    let g = MetricGauge(dataPoints: @[dp])
    check g.dataPoints.len == 1

  test "MetricSum construction":
    let dp = NumberDataPoint(
      attributes: @[], startTimeUnixNano: 0'u64, timeUnixNano: 100'u64,
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
