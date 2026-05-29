# Minimal gzip compression via C FFI to zlib.
# Only compiled when -d:observyGzip is set.
# Link with: {.passL: "-lz".}
when defined(observyGzip):
  {.passL: "-lz".}

  # We only access a subset of z_stream fields; declare the full struct with
  # completeStruct so the C compiler lays it out correctly, even though Nim
  # only sees/uses the fields listed here.
  type
    ZStream {.importc: "z_stream", header: "<zlib.h>",
              completeStruct, bycopy.} = object
      nextIn   {.importc: "next_in".}:  pointer
      availIn  {.importc: "avail_in".}: cuint
      totalIn  {.importc: "total_in".}: culong
      nextOut  {.importc: "next_out".}: pointer
      availOut {.importc: "avail_out".}: cuint
      totalOut {.importc: "total_out".}: culong

  const
    ZOk          = 0
    ZStreamEnd   = 1
    ZFinish      = 4
    # windowBits = 15 + 16 → gzip format (as opposed to zlib or raw deflate)
    GzipWindowBits = 15 + 16
    DefaultMemLevel = 8
    ZDefaultStrategy = 0

  proc deflateInit2*(strm: ptr ZStream; level, comprMethod, windowBits,
                     memLevel, strategy: cint): cint
    {.importc: "deflateInit2", header: "<zlib.h>".}

  proc deflate*(strm: ptr ZStream; flush: cint): cint
    {.importc: "deflate", header: "<zlib.h>".}

  proc deflateEnd*(strm: ptr ZStream): cint
    {.importc: "deflateEnd", header: "<zlib.h>".}

  proc gzipCompress*(data: openArray[byte]): seq[byte] =
    ## Compress `data` into gzip format. Raises ValueError on zlib error.
    ## Linked via -lz (zlib must be installed: brew install zlib / apt-get install zlib1g-dev).
    var strm: ZStream
    var rc = deflateInit2(addr strm, 6, 8.cint, GzipWindowBits, DefaultMemLevel,
                          ZDefaultStrategy)
    if rc != ZOk:
      raise newException(ValueError, "deflateInit2 failed: rc=" & $rc)

    # Upper-bound output size: deflateBound gives a safe max.
    # For short payloads a simple 2× + 64 is sufficient.
    let outLen = max(data.len * 2 + 64, 256)
    var outBuf = newSeq[byte](outLen)

    strm.nextIn   = if data.len > 0: cast[pointer](unsafeAddr data[0]) else: nil
    strm.availIn  = cuint(data.len)
    strm.nextOut  = addr outBuf[0]
    strm.availOut = cuint(outLen)

    rc = deflate(addr strm, ZFinish)
    discard deflateEnd(addr strm)

    if rc != ZStreamEnd:
      raise newException(ValueError, "deflate failed: rc=" & $rc)

    outBuf.setLen(int(strm.totalOut))
    outBuf
