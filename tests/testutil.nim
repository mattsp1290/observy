# Shared helpers for the observy test suite.

proc readBin*(path: string): seq[byte] =
  ## Read a binary fixture file into a byte sequence.
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)
