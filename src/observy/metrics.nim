# Metrics signal data model and OTLP encoding
import std/options
import ./anyvalue
import ./traces
import ./proto
import ./resource
import ./json_encode

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

# ---------------------------------------------------------------------------
# Proto encoding
#
# Wire-type notes (opentelemetry-proto v1.10.0 metrics.proto):
#   count / zero_count / bucket_counts(Histogram) : fixed64
#   Buckets.bucket_counts                          : packed uint64 varint
#   scale / Buckets.offset                         : sint32 (zigzag)
#   as_int / Exemplar.as_int                       : sfixed64
#   flags                                          : uint32 varint
#   sum / min / max                                : optional double (force-emit when set)
# ---------------------------------------------------------------------------

proc protoEncodeExemplar*(w: var ProtoWriter; e: Exemplar) =
  # ascending: time(2), as_double(3), span_id(4), trace_id(5), as_int(6), filtered_attributes(7)
  w.writeFixed64(2, e.timeUnixNano)
  if e.kind == evDouble:
    w.writeDoubleForce(3, e.doubleValue)
  if not isAllZero(e.spanId):  w.writeBytes(4, e.spanId)
  if not isAllZero(e.traceId): w.writeBytes(5, e.traceId)
  if e.kind == evInt:
    w.writeFixed64Force(6, cast[uint64](e.intValue))
  protoEncodeKeyValues(w, 7, e.filteredAttributes)

proc protoEncodeNumberDataPoint*(w: var ProtoWriter; dp: NumberDataPoint) =
  # ascending: start(2), time(3), as_double(4), exemplars(5), as_int(6), attributes(7), flags(8)
  w.writeFixed64(2, dp.startTimeUnixNano)
  w.writeFixed64(3, dp.timeUnixNano)
  if dp.kind == ndpDouble:
    w.writeDoubleForce(4, dp.doubleValue)
  for ex in dp.exemplars:
    var exW: ProtoWriter
    protoEncodeExemplar(exW, ex)
    w.writeEmbedded(5, exW)
  if dp.kind == ndpInt:
    w.writeFixed64Force(6, cast[uint64](dp.intValue))
  protoEncodeKeyValues(w, 7, dp.attributes.pairs)
  w.writeUint32(8, dp.flags)

proc protoEncodeHistogramDataPoint*(w: var ProtoWriter; dp: HistogramDataPoint) =
  # ascending: start(2),time(3),count(4),sum(5),bucket_counts(6),explicit_bounds(7),
  #            exemplars(8),attributes(9),flags(10),min(11),max(12)
  w.writeFixed64(2, dp.startTimeUnixNano)
  w.writeFixed64(3, dp.timeUnixNano)
  w.writeFixed64(4, dp.count)
  if dp.sum.isSome: w.writeDoubleForce(5, dp.sum.get)
  w.writePackedFixed64(6, dp.bucketCounts)
  w.writePackedDouble(7, dp.explicitBounds)
  for ex in dp.exemplars:
    var exW: ProtoWriter
    protoEncodeExemplar(exW, ex)
    w.writeEmbedded(8, exW)
  protoEncodeKeyValues(w, 9, dp.attributes.pairs)
  w.writeUint32(10, dp.flags)
  if dp.min.isSome: w.writeDoubleForce(11, dp.min.get)
  if dp.max.isSome: w.writeDoubleForce(12, dp.max.get)

proc protoEncodeBuckets*(w: var ProtoWriter; b: ExponentialHistogramBuckets) =
  w.writeSint32(1, b.offset)
  w.writePackedUint64(2, b.bucketCounts)

proc protoEncodeExpHistogramDataPoint*(w: var ProtoWriter;
                                       dp: ExponentialHistogramDataPoint) =
  # ascending: attributes(1),start(2),time(3),count(4),sum(5),scale(6),zero_count(7),
  #            positive(8),negative(9),flags(10),exemplars(11),min(12),max(13),zero_threshold(14)
  protoEncodeKeyValues(w, 1, dp.attributes.pairs)
  w.writeFixed64(2, dp.startTimeUnixNano)
  w.writeFixed64(3, dp.timeUnixNano)
  w.writeFixed64(4, dp.count)
  if dp.sum.isSome: w.writeDoubleForce(5, dp.sum.get)
  w.writeSint32(6, dp.scale)
  w.writeFixed64(7, dp.zeroCount)
  var posW: ProtoWriter
  protoEncodeBuckets(posW, dp.positive)
  w.writeEmbedded(8, posW)
  var negW: ProtoWriter
  protoEncodeBuckets(negW, dp.negative)
  w.writeEmbedded(9, negW)
  w.writeUint32(10, dp.flags)
  for ex in dp.exemplars:
    var exW: ProtoWriter
    protoEncodeExemplar(exW, ex)
    w.writeEmbedded(11, exW)
  if dp.min.isSome: w.writeDoubleForce(12, dp.min.get)
  if dp.max.isSome: w.writeDoubleForce(13, dp.max.get)
  w.writeDouble(14, dp.zeroThreshold)

proc protoEncodeValueAtQuantile*(w: var ProtoWriter; v: ValueAtQuantile) =
  w.writeDouble(1, v.quantile)
  w.writeDouble(2, v.value)

proc protoEncodeSummaryDataPoint*(w: var ProtoWriter; dp: SummaryDataPoint) =
  # ascending: start(2),time(3),count(4),sum(5),quantile_values(6),attributes(7),flags(8)
  w.writeFixed64(2, dp.startTimeUnixNano)
  w.writeFixed64(3, dp.timeUnixNano)
  w.writeFixed64(4, dp.count)
  w.writeDouble(5, dp.sum)
  for q in dp.quantileValues:
    var qW: ProtoWriter
    protoEncodeValueAtQuantile(qW, q)
    w.writeEmbedded(6, qW)
  protoEncodeKeyValues(w, 7, dp.attributes.pairs)
  w.writeUint32(8, dp.flags)

proc protoEncodeMetric*(w: var ProtoWriter; m: Metric) =
  # Metric: name(1), description(2), unit(3), gauge(5)/sum(7)/histogram(9)/
  #         exponential_histogram(10)/summary(11), metadata(12)
  w.writeString(1, m.name)
  w.writeString(2, m.description)
  w.writeString(3, m.unit)
  case m.kind
  of mkGauge:
    var g: ProtoWriter
    for dp in m.gauge.dataPoints:
      var d: ProtoWriter
      protoEncodeNumberDataPoint(d, dp)
      g.writeEmbedded(1, d)
    w.writeEmbedded(5, g)
  of mkSum:
    var s: ProtoWriter
    for dp in m.sum.dataPoints:
      var d: ProtoWriter
      protoEncodeNumberDataPoint(d, dp)
      s.writeEmbedded(1, d)
    s.writeInt32(2, int32(m.sum.aggregationTemporality))
    s.writeBool(3, m.sum.isMonotonic)
    w.writeEmbedded(7, s)
  of mkHistogram:
    var h: ProtoWriter
    for dp in m.histogram.dataPoints:
      var d: ProtoWriter
      protoEncodeHistogramDataPoint(d, dp)
      h.writeEmbedded(1, d)
    h.writeInt32(2, int32(m.histogram.aggregationTemporality))
    w.writeEmbedded(9, h)
  of mkExpHistogram:
    var h: ProtoWriter
    for dp in m.expHistogram.dataPoints:
      var d: ProtoWriter
      protoEncodeExpHistogramDataPoint(d, dp)
      h.writeEmbedded(1, d)
    h.writeInt32(2, int32(m.expHistogram.aggregationTemporality))
    w.writeEmbedded(10, h)
  of mkSummary:
    var s: ProtoWriter
    for dp in m.summary.dataPoints:
      var d: ProtoWriter
      protoEncodeSummaryDataPoint(d, dp)
      s.writeEmbedded(1, d)
    w.writeEmbedded(11, s)
  protoEncodeKeyValues(w, 12, m.metadata)

# ---------------------------------------------------------------------------
# JSON encoding
#
# OTLP-JSON number/string rules:
#   count / asInt / zeroCount / bucketCounts(both) : JSON string (64-bit ints)
#   scale / offset / flags / aggregationTemporality: JSON number
#   sum / min / max / explicitBounds / quantile / value / zeroThreshold: JSON number
# ---------------------------------------------------------------------------

proc jsonU64Array(vs: openArray[uint64]): string =
  result = "["
  for i, v in vs:
    if i > 0: result.add(",")
    result.add(jsonEncodeUint64(v))   # quoted strings
  result.add("]")

proc jsonF64Array(vs: openArray[float64]): string =
  result = "["
  for i, v in vs:
    if i > 0: result.add(",")
    result.add(jsonEncodeDouble(v))   # numbers (or "NaN"/"Infinity")
  result.add("]")

proc jsonEncodeExemplar(e: Exemplar): string =
  result = "{\"timeUnixNano\":" & jsonEncodeUint64(e.timeUnixNano)
  case e.kind
  of evDouble: result.add(",\"asDouble\":" & jsonEncodeDouble(e.doubleValue))
  of evInt:    result.add(",\"asInt\":" & jsonEncodeInt64(e.intValue))
  if not isAllZero(e.spanId):
    result.add(",\"spanId\":\"" & hexEncodeSpanId(e.spanId) & "\"")
  if not isAllZero(e.traceId):
    result.add(",\"traceId\":\"" & hexEncodeTraceId(e.traceId) & "\"")
  if e.filteredAttributes.len > 0:
    result.add(",\"filteredAttributes\":" & jsonEncodeKVList(e.filteredAttributes))
  result.add("}")

proc jsonExemplars(exs: openArray[Exemplar]): string =
  result = "["
  for i, e in exs:
    if i > 0: result.add(",")
    result.add(jsonEncodeExemplar(e))
  result.add("]")

proc jsonEncodeNumberDataPoint(dp: NumberDataPoint): string =
  result = "{\"startTimeUnixNano\":" & jsonEncodeUint64(dp.startTimeUnixNano)
  result.add(",\"timeUnixNano\":" & jsonEncodeUint64(dp.timeUnixNano))
  case dp.kind
  of ndpDouble: result.add(",\"asDouble\":" & jsonEncodeDouble(dp.doubleValue))
  of ndpInt:    result.add(",\"asInt\":" & jsonEncodeInt64(dp.intValue))
  if dp.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(dp.attributes.pairs))
  if dp.exemplars.len > 0:
    result.add(",\"exemplars\":" & jsonExemplars(dp.exemplars))
  if dp.flags != 0:
    result.add(",\"flags\":" & $dp.flags)
  result.add("}")

proc jsonEncodeHistogramDataPoint(dp: HistogramDataPoint): string =
  result = "{\"startTimeUnixNano\":" & jsonEncodeUint64(dp.startTimeUnixNano)
  result.add(",\"timeUnixNano\":" & jsonEncodeUint64(dp.timeUnixNano))
  result.add(",\"count\":" & jsonEncodeUint64(dp.count))
  if dp.sum.isSome: result.add(",\"sum\":" & jsonEncodeDouble(dp.sum.get))
  if dp.bucketCounts.len > 0:
    result.add(",\"bucketCounts\":" & jsonU64Array(dp.bucketCounts))
  if dp.explicitBounds.len > 0:
    result.add(",\"explicitBounds\":" & jsonF64Array(dp.explicitBounds))
  if dp.exemplars.len > 0:
    result.add(",\"exemplars\":" & jsonExemplars(dp.exemplars))
  if dp.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(dp.attributes.pairs))
  if dp.flags != 0:
    result.add(",\"flags\":" & $dp.flags)
  if dp.min.isSome: result.add(",\"min\":" & jsonEncodeDouble(dp.min.get))
  if dp.max.isSome: result.add(",\"max\":" & jsonEncodeDouble(dp.max.get))
  result.add("}")

proc jsonEncodeBuckets(b: ExponentialHistogramBuckets): string =
  result = "{"
  var n = 0
  if b.offset != 0:
    result.add("\"offset\":" & $b.offset); inc n
  if b.bucketCounts.len > 0:
    if n > 0: result.add(",")
    result.add("\"bucketCounts\":" & jsonU64Array(b.bucketCounts))
  result.add("}")

proc jsonEncodeExpHistogramDataPoint(dp: ExponentialHistogramDataPoint): string =
  result = "{\"startTimeUnixNano\":" & jsonEncodeUint64(dp.startTimeUnixNano)
  result.add(",\"timeUnixNano\":" & jsonEncodeUint64(dp.timeUnixNano))
  result.add(",\"count\":" & jsonEncodeUint64(dp.count))
  if dp.sum.isSome: result.add(",\"sum\":" & jsonEncodeDouble(dp.sum.get))
  result.add(",\"scale\":" & $dp.scale)
  result.add(",\"zeroCount\":" & jsonEncodeUint64(dp.zeroCount))
  result.add(",\"positive\":" & jsonEncodeBuckets(dp.positive))
  if dp.negative.offset != 0 or dp.negative.bucketCounts.len > 0:
    result.add(",\"negative\":" & jsonEncodeBuckets(dp.negative))
  if dp.exemplars.len > 0:
    result.add(",\"exemplars\":" & jsonExemplars(dp.exemplars))
  if dp.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(dp.attributes.pairs))
  if dp.flags != 0:
    result.add(",\"flags\":" & $dp.flags)
  if dp.min.isSome: result.add(",\"min\":" & jsonEncodeDouble(dp.min.get))
  if dp.max.isSome: result.add(",\"max\":" & jsonEncodeDouble(dp.max.get))
  if dp.zeroThreshold != 0.0:
    result.add(",\"zeroThreshold\":" & jsonEncodeDouble(dp.zeroThreshold))
  result.add("}")

proc jsonEncodeSummaryDataPoint(dp: SummaryDataPoint): string =
  result = "{\"startTimeUnixNano\":" & jsonEncodeUint64(dp.startTimeUnixNano)
  result.add(",\"timeUnixNano\":" & jsonEncodeUint64(dp.timeUnixNano))
  result.add(",\"count\":" & jsonEncodeUint64(dp.count))
  result.add(",\"sum\":" & jsonEncodeDouble(dp.sum))
  if dp.quantileValues.len > 0:
    var qs = "["
    for i, q in dp.quantileValues:
      if i > 0: qs.add(",")
      qs.add("{\"quantile\":" & jsonEncodeDouble(q.quantile) &
             ",\"value\":" & jsonEncodeDouble(q.value) & "}")
    qs.add("]")
    result.add(",\"quantileValues\":" & qs)
  if dp.attributes.pairs.len > 0:
    result.add(",\"attributes\":" & jsonEncodeKVList(dp.attributes.pairs))
  if dp.flags != 0:
    result.add(",\"flags\":" & $dp.flags)
  result.add("}")

proc numberDataPointsJson(dps: openArray[NumberDataPoint]): string =
  result = "["
  for i, dp in dps:
    if i > 0: result.add(",")
    result.add(jsonEncodeNumberDataPoint(dp))
  result.add("]")

proc jsonEncodeMetric*(m: Metric): string =
  result = "{\"name\":" & jsonEscape(m.name)
  if m.description.len > 0:
    result.add(",\"description\":" & jsonEscape(m.description))
  if m.unit.len > 0:
    result.add(",\"unit\":" & jsonEscape(m.unit))
  case m.kind
  of mkGauge:
    result.add(",\"gauge\":{\"dataPoints\":" &
               numberDataPointsJson(m.gauge.dataPoints) & "}")
  of mkSum:
    result.add(",\"sum\":{\"dataPoints\":" & numberDataPointsJson(m.sum.dataPoints))
    result.add(",\"aggregationTemporality\":" & $int(m.sum.aggregationTemporality))
    if m.sum.isMonotonic: result.add(",\"isMonotonic\":true")
    result.add("}")
  of mkHistogram:
    var dps = "["
    for i, dp in m.histogram.dataPoints:
      if i > 0: dps.add(",")
      dps.add(jsonEncodeHistogramDataPoint(dp))
    dps.add("]")
    result.add(",\"histogram\":{\"dataPoints\":" & dps)
    result.add(",\"aggregationTemporality\":" & $int(m.histogram.aggregationTemporality))
    result.add("}")
  of mkExpHistogram:
    var dps = "["
    for i, dp in m.expHistogram.dataPoints:
      if i > 0: dps.add(",")
      dps.add(jsonEncodeExpHistogramDataPoint(dp))
    dps.add("]")
    result.add(",\"exponentialHistogram\":{\"dataPoints\":" & dps)
    result.add(",\"aggregationTemporality\":" & $int(m.expHistogram.aggregationTemporality))
    result.add("}")
  of mkSummary:
    var dps = "["
    for i, dp in m.summary.dataPoints:
      if i > 0: dps.add(",")
      dps.add(jsonEncodeSummaryDataPoint(dp))
    dps.add("]")
    result.add(",\"summary\":{\"dataPoints\":" & dps & "}")
  if m.metadata.len > 0:
    result.add(",\"metadata\":" & jsonEncodeKVList(m.metadata))
  result.add("}")

proc metricToJson*(res: Resource; scope: InstrumentationScope;
                   metrics: seq[Metric]): string =
  ## Encode metrics as an OTLP ExportMetricsServiceRequest JSON body.
  var metricsArr = "["
  for i, m in metrics:
    if i > 0: metricsArr.add(",")
    metricsArr.add(jsonEncodeMetric(m))
  metricsArr.add("]")
  let scopeMetrics = "{\"scope\":" & jsonEncode(scope) & ",\"metrics\":" & metricsArr & "}"
  let resourceMetrics = "{\"resource\":" & jsonEncode(res) & ",\"scopeMetrics\":[" & scopeMetrics & "]}"
  "{\"resourceMetrics\":[" & resourceMetrics & "]}"
