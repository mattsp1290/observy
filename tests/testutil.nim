# Shared helpers for the observy test suite.
import ../src/observy/proto

proc readBin*(path: string): seq[byte] =
  ## Read a binary fixture file into a byte sequence.
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc protoFieldNumbers*(buf: seq[byte]): seq[uint32] =
  ## Decode the top-level field numbers present in a proto message buffer.
  var r = ProtoReader(data: buf)
  while r.pos < buf.len:
    let (fn, wt) = r.readTag()
    result.add(fn)
    r.skipField(wt)
