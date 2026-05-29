# Metrics signal data model
import std/options
import ./anyvalue
import ./traces

# opentelemetry-proto v1.10.0 field numbers
# metrics/v1/metrics.proto
#   Metric: name=1, description=2, unit=3, gauge=5, sum=7, histogram=9,
#           exponential_histogram=10, summary=11, metadata=12
#   Gauge: data_points=1
#   Sum: data_points=1, aggregation_temporality=2, is_monotonic=3
#   Histogram: data_points=1, aggregation_temporality=2
#   ExponentialHistogram: data_points=1, aggregation_temporality=2
#   Summary: data_points=1
#   NumberDataPoint: attributes=7, start_time_unix_nano=2, time_unix_nano=3,
#                    as_double=4, as_int=6, exemplars=5, flags=8
#   HistogramDataPoint: attributes=9, start_time_unix_nano=2, time_unix_nano=3,
#                       count=4, sum=5, bucket_counts=6, explicit_bounds=7,
#                       exemplars=8, flags=10, min=11, max=12
#   ExponentialHistogramDataPoint: attributes=1, start_time_unix_nano=2,
#     time_unix_nano=3, count=4, sum=5, scale=6, zero_count=7, positive=8,
#     negative=9, flags=10, exemplars=11, min=12, max=13, zero_threshold=14
#   ExponentialHistogramBuckets: offset=1, bucket_counts=2
#   SummaryDataPoint: attributes=1, start_time_unix_nano=2, time_unix_nano=3,
#                     count=4, sum=5, quantile_values=6, flags=7
#   SummaryDataPoint.ValueAtQuantile: quantile=1, value=2
#   Exemplar: filtered_attributes=7, time_unix_nano=2, as_double=3, as_int=6,
#             span_id=4, trace_id=5

type
  AggregationTemporality* = enum
    aggTempUnspecified = 0
    aggTempDelta       = 1
    aggTempCumulative  = 2

  ExemplarValueKind* = enum
    evDouble
    evInt

  Exemplar* = object
    filteredAttributes*: seq[KeyValue]
    timeUnixNano*:       uint64
    spanId*:             SpanId
    traceId*:            TraceId
    case kind*:          ExemplarValueKind
    of evDouble: doubleValue*: float64
    of evInt:    intValue*:    int64

  NumberDataPointValueKind* = enum
    ndpDouble
    ndpInt

  NumberDataPoint* = object
    attributes*:        AttributeSet
    startTimeUnixNano*: uint64
    timeUnixNano*:      uint64
    exemplars*:         seq[Exemplar]
    flags*:             uint32
    case kind*:         NumberDataPointValueKind
    of ndpDouble: doubleValue*: float64
    of ndpInt:    intValue*:    int64

  HistogramDataPoint* = object
    attributes*:        AttributeSet
    startTimeUnixNano*: uint64
    timeUnixNano*:      uint64
    count*:             uint64
    sum*:               Option[float64]
    bucketCounts*:      seq[uint64]
    explicitBounds*:    seq[float64]
    exemplars*:         seq[Exemplar]
    flags*:             uint32
    min*:               Option[float64]
    max*:               Option[float64]

  ExponentialHistogramBuckets* = object
    offset*:       int32
    bucketCounts*: seq[uint64]

  ExponentialHistogramDataPoint* = object
    attributes*:        AttributeSet
    startTimeUnixNano*: uint64
    timeUnixNano*:      uint64
    count*:             uint64
    sum*:               Option[float64]
    scale*:             int32
    zeroCount*:         uint64
    positive*:          ExponentialHistogramBuckets
    negative*:          ExponentialHistogramBuckets
    flags*:             uint32
    exemplars*:         seq[Exemplar]
    min*:               Option[float64]
    max*:               Option[float64]
    zeroThreshold*:     float64

  ValueAtQuantile* = object
    quantile*: float64
    value*:    float64

  SummaryDataPoint* = object
    attributes*:        AttributeSet
    startTimeUnixNano*: uint64
    timeUnixNano*:      uint64
    count*:             uint64
    sum*:               float64
    quantileValues*:    seq[ValueAtQuantile]
    flags*:             uint32

  MetricGauge* = object
    dataPoints*: seq[NumberDataPoint]

  MetricSum* = object
    dataPoints*:             seq[NumberDataPoint]
    aggregationTemporality*: AggregationTemporality
    isMonotonic*:            bool

  MetricHistogram* = object
    dataPoints*:             seq[HistogramDataPoint]
    aggregationTemporality*: AggregationTemporality

  MetricExpHistogram* = object
    dataPoints*:             seq[ExponentialHistogramDataPoint]
    aggregationTemporality*: AggregationTemporality

  MetricSummary* = object
    dataPoints*: seq[SummaryDataPoint]

  MetricKind* = enum
    mkGauge
    mkSum
    mkHistogram
    mkExpHistogram
    mkSummary

  Metric* = object
    name*:        string
    description*: string
    unit*:        string
    metadata*:    seq[KeyValue]
    case kind*:   MetricKind
    of mkGauge:        gauge*:        MetricGauge
    of mkSum:          sum*:          MetricSum
    of mkHistogram:    histogram*:    MetricHistogram
    of mkExpHistogram: expHistogram*: MetricExpHistogram
    of mkSummary:      summary*:      MetricSummary
