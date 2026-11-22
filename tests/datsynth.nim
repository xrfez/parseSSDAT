## Test fixture: writes synthetic `.dat` signature files. The library reads this
## format and does not author it, so the writer lives with the tests. The unknown
## and constant bytes of the format are filled with made-up values: the decoder
## must not depend on them.

import std/[math, strutils]
import parseSSDAT/types

type
  Place* = tuple[deg: int, minE6: int, hemi: char]

  SynthDat* = object
    serial*: int64 = 4321                              ## the controller serial number
    fileNumber*: int64 = 7001
    firmware*: tuple[major, minor: int] = (1, 2)
    trigger*: DatTime = DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5,
      second: 6, nanosecond: 789_000_000)
    samples*: int = 120                                ## per channel
    data*: array[DatChannel, seq[int32]]               ## empty: a deterministic chirp with noise
    text*: string = "9600 bps;$GPGGA,040506.00,1230.500000,N,04530.250000,E,1,8,0.9," &
      "100.0,M,10.0,M,,*hh\r\n"                        ## `*hh` becomes the NMEA checksum
    fixLat*: Place = (12, 30_500_000, 'N')
    fixLon*: Place = (45, 30_250_000, 'E')
    line*, station*, shotId*, index*, counter*, sweepId*: int64
    qcOffset*: int = 97                                ## 97, 99 or 100: the trailer's first-message variants
    noQc*: bool                                        ## no QC record in the trailer (made-up bytes instead)
    crew*: int = 3
    vibrator*: int = 12                                ## the vibrator ID of the QC record
    sweepNumber*: int = 2
    sweepChecksum*: int = 0x1234
    paramChecksum*: int = 0x5678
    phaseByte*: int = 12                               ## QC byte 16
    forceMax*: int = 61                                ## QC bytes 19 to 21, in percent
    forceMin*: int = 58
    forceAvg*: int = 59
    thdMax*: int = 9                                   ## QC bytes 22 and 23
    thdAvg*: int = 4
    status*: array[4, byte] = [17'u8, 34, 51, 0b10101] ## QC bytes 28 to 31
    corrMagnitude*: int = 777                          ## QC bytes 36-37
    corr*: seq[int8]                                   ## the 128 values; empty: a made-up series, unless `noCorr`
    noCorr*: bool                                      ## the series is not stored: every value 1, magnitude 0
    heightCm*: int64 = 1_234_567                       ## QC bytes 185-188
    qcSatellites*: int = 11
    dops*: array[3, int] = [15, 9, 12]                 ## PDOP, HDOP, VDOP times 10
    correctionAge*: int = 3
    stiffness*: array[3, int] = [250, 100, 180]        ## maximum, minimum, average
    viscosity*: array[3, int] = [90, 20, 55]
    targetForce*: int = 4242                           ## QC bytes 209-210
    qcTrigger*: DatTime = DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5,
      second: 7, nanosecond: 790_000_000)
    staleTail*: bool = true ## the last data record's padding is the previous block's tail
    truncateAfter*: int = -1                           ## >= 2: the file ends after that many blocks
    zeroBlockAtCut*: bool = false                      ## and one all-zero block follows
    lastFrames*: int = -1 ## samples a multiple of 54: 54 (default) or 0 frames in 0x82

const Block = 512

func blockOffset*(k: int): int =
  ## File offset of block `k` (0-based).
  k * Block

proc put32le(d: var seq[byte]; at: int; v: int64) =
  for i in 0 .. 3:
    d[at + i] = byte((v shr (8 * i)) and 0xFF)

proc put32be(d: var seq[byte]; at: int; v: int64) =
  for i in 0 .. 3:
    d[at + 3 - i] = byte((v shr (8 * i)) and 0xFF)

proc put16be(d: var seq[byte]; at: int; v: int) =
  d[at] = byte((v shr 8) and 0xFF)
  d[at + 1] = byte(v and 0xFF)

proc put16le(d: var seq[byte]; at: int; v: int) =
  d[at] = byte(v and 0xFF)
  d[at + 1] = byte((v shr 8) and 0xFF)

proc fixChecksum*(data: var seq[byte]; k: int) =
  ## Sums block `k` again after an edit: the record's last byte is set so that the
  ## record's bytes sum to 0 modulo 256.
  let o = blockOffset(k)
  let l = int(data[o]) or (int(data[o + 1]) shl 8)
  if l in 1 .. Block - 2: # a length no block can hold has no checksum to set
    data[o + l + 1] = 0
    var sum = 0
    for i in 2 .. l:
      sum += int(data[o + i])
    data[o + l + 1] = byte((256 - sum mod 256) mod 256)

func nmeaChecksum(body: string): string =
  var x = 0
  for c in body:
    x = x xor ord(c)
  const hex = "0123456789ABCDEF"
  $hex[x shr 4] & $hex[x and 15]

proc withChecksum(text: string): string =
  ## Replaces `*hh` by the checksum of the sentence before it.
  result = text
  let star = text.find("*hh")
  let dollar = if star > 0: text.rfind('$', 0, star - 1) else: -1
  if star >= 0 and dollar >= 0:
    result = text[0 ..< star + 1] & nmeaChecksum(text[dollar + 1 ..< star]) &
      text[star + 3 .. ^1]

proc chirp(c: DatChannel; i, total: int): int32 =
  ## A deterministic made-up signal in 24-bit range.
  let t = float64(i) / float64(max(total, 1))
  let amp = [800_000.0, 300_000.0, 150_000.0][ord(c)]
  let x = (((i * 2654435761 + ord(c) * 40503) and 0xFFFFFF00) shr 8) mod 2001
  int32(amp * sin(2 * PI * (5 + 40 * t) * t * 3) + float64(x - 1000) + float64(ord(c)) * 100)

proc header(d: var seq[byte]; o, length: int; kind: byte; s: SynthDat; k, n: int) =
  d[o] = byte(length and 0xFF)
  d[o + 1] = byte(length shr 8)
  d[o + 2] = kind
  d[o + 3] = byte(0x11 + k mod 3) # made up
  put32le(d, o + 4, s.serial)
  put32le(d, o + 8, s.fileNumber)
  put32le(d, o + 12, k + 1)
  put32le(d, o + 16, n)

proc synthDat*(s: SynthDat): seq[byte] =
  ## A complete file (or, with `truncateAfter`, a cut one).
  let ns = if s.data[dcReference].len > 0: s.data[dcReference].len else: s.samples
  var d: array[DatChannel, seq[int32]]
  for c in DatChannel:
    d[c] = if s.data[c].len > 0: s.data[c] else: newSeq[int32](ns)
    if s.data[c].len == 0:
      for i in 0 ..< ns:
        d[c][i] = chirp(c, i, ns)
  var lastFrames = ns mod 54
  if lastFrames == 0:
    lastFrames = if s.lastFrames == 0: 0 else: 54
  let full = (ns - lastFrames) div 54
  let n = 2 + full + 2
  var f = newSeq[byte](n * Block)
  # block 0: the header record
  var o = blockOffset(0)
  header(f, o, 507, 0x80, s, 0, n)
  f[o + 20] = byte(s.firmware.major)
  f[o + 21] = byte(s.firmware.minor)
  for i in 22 .. 25:
    f[o + i] = byte(0x31 * i) # made up
  for i in 0 .. 5:
    f[o + 26 + i] = f[o + 20 + i]
  f[o + 32] = byte((s.serial mod 100) and 0xFF)
  f[o + 33] = byte((s.serial div 100) and 0xFF)
  for i in 34 .. 45:
    f[o + i] = byte(7 * i + 1)
  put32be(f, o + 46, ns)
  for i in 50 .. 69:
    f[o + i] = byte(5 * i + 3)
  for i in 184 .. 195:
    f[o + i] = byte(3 * i)
  let text = withChecksum(s.text)
  for i in 0 ..< min(text.len, 212):
    f[o + 280 + i] = byte(text[i])
  put32le(f, o + 492, s.trigger.nanosecond)
  f[o + 496] = byte(s.trigger.second)
  f[o + 497] = byte(s.trigger.minute)
  f[o + 498] = byte(s.trigger.hour)
  f[o + 499] = byte(s.trigger.day)
  f[o + 500] = byte(s.trigger.month)
  put16le(f, o + 501, s.trigger.year)
  f[o + 503] = 0x5A
  f[o + 504] = 0xA5
  f[o + 505] = 0x77
  fixChecksum(f, 0)
  # block 1: the position record
  o = blockOffset(1)
  header(f, o, 167, 0x87, s, 1, n)
  f[o + 20] = 3
  put16le(f, o + 121, 9000)
  f[o + 124] = 91
  f[o + 125] = 5
  f[o + 126] = byte(s.trigger.year mod 100)
  f[o + 127] = byte(s.trigger.month)
  f[o + 128] = byte(s.trigger.day)
  f[o + 129] = byte(s.trigger.hour)
  f[o + 130] = byte(s.trigger.minute)
  f[o + 131] = byte(s.trigger.second)
  f[o + 135] = byte(s.fixLat.deg)
  put32le(f, o + 136, s.fixLat.minE6)
  f[o + 140] = byte(s.fixLat.hemi)
  f[o + 141] = byte(s.fixLon.deg)
  put32le(f, o + 142, s.fixLon.minE6)
  f[o + 146] = byte(s.fixLon.hemi)
  put16le(f, o + 147, 1234)
  f[o + 149] = 2
  f[o + 150] = 9
  f[o + 151] = 11
  for i in 161 .. 165:
    f[o + i] = byte(17 * i)
  fixChecksum(f, 1)
  # data records
  var at = 0
  for r in 0 ..< full + 1:
    let k = 2 + r
    let frames = if r < full: 54 else: lastFrames
    let kind = if r < full: 0x81'u8 else: 0x82'u8
    o = blockOffset(k)
    let length = 19 + 9 * frames
    header(f, o, length, kind, s, k, n)
    for i in 0 ..< frames:
      for c in DatChannel:
        let v = int64(d[c][at + i]) and 0xFFFFFF
        let p = o + 20 + i * 9 + ord(c) * 3
        f[p] = byte(v shr 16)
        f[p + 1] = byte((v shr 8) and 0xFF)
        f[p + 2] = byte(v and 0xFF)
    at += frames
    if kind == 0x82 and s.staleTail:
      for i in length + 2 ..< Block:
        f[o + i] = f[blockOffset(k - 1) + i]
    fixChecksum(f, k)
  # the trailer
  let k = n - 1
  o = blockOffset(k)
  header(f, o, 509, 0x84, s, k, n)
  f[o + 20] = byte('Q')
  f[o + 21] = byte('X')
  put32be(f, o + 22, 29)
  for i in 24 .. 29:
    f[o + i] = byte(9 * i)
  put32be(f, o + 30, s.line)
  put32be(f, o + 34, s.station)
  put32be(f, o + 38, s.shotId)
  put32be(f, o + 42, s.index)
  put32be(f, o + 46, s.counter)
  put32be(f, o + 50, s.sweepId)
  f[o + 54] = 0x42
  for i in 55 ..< s.qcOffset:
    f[o + i] = byte(1 + (i * 13) mod 60) # no 0x46 (the QC record's first byte)
  let q = o + s.qcOffset
  for i in 0 ..< 240:
    f[q + i] = byte(1 + (i * 29) mod 200) # made-up fill, never 0x46 at the start
  if not s.noQc:
    f[q] = 0x46
    f[q + 1] = 0x33
    f[q + 2] = 0
    f[q + 3] = 0xE7
    f[q + 4] = byte(s.crew)
    f[q + 5] = 0x22 # made-up constants
    f[q + 6] = byte(s.vibrator)
    f[q + 7] = 1
    f[q + 8] = 0x33
    put32be(f, q + 9, s.sweepId)
    f[q + 13] = byte(s.sweepNumber)
    f[q + 16] = byte(s.phaseByte)
    f[q + 19] = byte(s.forceMax)
    f[q + 20] = byte(s.forceMin)
    f[q + 21] = byte(s.forceAvg)
    f[q + 22] = byte(s.thdMax)
    f[q + 23] = byte(s.thdAvg)
    for i in 0 .. 3:
      f[q + 28 + i] = s.status[i]
    if s.noCorr:
      put16be(f, q + 36, 0)
      for i in 0 ..< 128:
        f[q + 38 + i] = 1
    else:
      put16be(f, q + 36, s.corrMagnitude)
      for i in 0 ..< 128:
        f[q + 38 + i] = byte(if s.corr.len == 128: int(s.corr[i]) and 0xFF
          else: (i * 7 + 3) mod 256)
    put32be(f, q + 185, s.heightCm)
    f[q + 189] = byte(s.qcSatellites)
    for i in 0 .. 2:
      f[q + 190 + i] = byte(s.dops[i])
    f[q + 193] = byte(s.correctionAge)
    for i in 0 .. 2:
      f[q + 203 + i] = byte(s.stiffness[i])
      f[q + 206 + i] = byte(s.viscosity[i])
    put16be(f, q + 209, s.targetForce)
    f[q + 24] = byte(s.sweepChecksum shr 8)
    f[q + 25] = byte(s.sweepChecksum and 0xFF)
    f[q + 26] = byte(s.paramChecksum shr 8)
    f[q + 27] = byte(s.paramChecksum and 0xFF)
    f[q + 166] = byte(s.qcTrigger.year mod 100)
    f[q + 167] = byte(s.qcTrigger.month)
    f[q + 168] = byte(s.qcTrigger.day)
    f[q + 169] = byte(s.qcTrigger.hour)
    f[q + 170] = byte(s.qcTrigger.minute)
    f[q + 171] = byte(s.qcTrigger.second)
    put32be(f, q + 172, s.qcTrigger.nanosecond)
    put32be(f, q + 218, s.shotId)
    put32be(f, q + 222, s.line)
    put32be(f, q + 226, s.station)
  fixChecksum(f, k)
  result = f
  if s.truncateAfter >= 2 and s.truncateAfter < n:
    result.setLen(s.truncateAfter * Block)
    if s.zeroBlockAtCut:
      result.setLen((s.truncateAfter + 1) * Block)
