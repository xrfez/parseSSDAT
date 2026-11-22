## Decoder of a vibrator controller's `.dat` signature file.
##
## A file is a sequence of 512-byte blocks, one record each: a header record, a
## position record, full data records, one last data record and a trailer. The
## samples are three channels (reference, reaction-mass force, baseplate force),
## interleaved, as signed 24-bit big-endian counts. `parseDat` checks every block
## (length, checksum, header, order) and raises `DatFormatError` for bytes that break
## the format; it never reads outside its input and never sizes an allocation from a
## number the file states.
##
## For a list of many files, `readDatInfo` reads three blocks of a file and never its
## samples. For decoding many files, `decodeInto` and `readDatInto` fill a `DatShot`
## and a byte buffer the caller keeps: after the first files they allocate nothing.
## Every proc here is safe to call from several threads on different files and
## objects (there is no global state).

import std/[math, os, strutils]
import ./[blocks, types]

const
  HeaderMinLength = 504 ## the header record holds fields up to block offset 505
  PositionMinLength = 165
  TrailerMinLength = 53
  TextStart = 280
  TextEnd = 491
  QcStart = 97          ## the first block offset where the QC record may begin
  QcBytes = 240
  MaxBlocks = MaxDatBytes div DatBlockBytes
  Pow10 = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13,
    1e14, 1e15]

type DatBlock = array[DatBlockBytes, byte]

func blockAt(data: openArray[byte]; k: int): DatBlock =
  ## A copy of block `k` (0-based) of `data`, which must hold it whole.
  for i in 0 ..< DatBlockBytes:
    result[i] = data[k * DatBlockBytes + i]

func looksLikeDat*(head: openArray[byte]): bool =
  ## True when the first block of `head` is a valid header record: length 20 to
  ## 510, kind 0x80, byte sum 0, block number 1, and a block count of at least 3 and
  ## less than `MaxDatBytes div 512`. Needs the first 512 bytes. Never raises. For a
  ## file list that only has the start of each file.
  if head.len >= DatBlockBytes:
    let b = blockAt(head, 0)
    let h = readHead(b)
    result = h.length in 20 .. MaxLength and h.kind == KindHeader and
      sumIsZero(b, h.length) and h.blockNumber == 1 and h.blockCount >= 3 and
      h.blockCount < MaxBlocks

func isLeapYear(y: int): bool =
  (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

func daysInMonth(y, m: int): int =
  case m
  of 2: (if isLeapYear(y): 29 else: 28)
  of 4, 6, 9, 11: 30
  else: 31

func posixTime*(t: DatTime): float64 =
  ## UTC POSIX seconds of `t`, with its nanoseconds as a fraction (a `float64` holds
  ## about 0.2 microseconds of a time near now: keep `t` where an exact time matters).
  let y = if t.month <= 2: t.year - 1 else: t.year
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let mp = if t.month > 2: t.month - 3 else: t.month + 9
  let doy = (153 * mp + 2) div 5 + t.day - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  let days = era * 146097 + doe - 719468
  float64(days) * 86400.0 + float64(t.hour * 3600 + t.minute * 60 + t.second) +
    float64(t.nanosecond) / 1e9

func `$`*(t: DatTime): string =
  ## ISO 8601 with microseconds, `2001-02-03T04:05:06.789000Z`.
  intToStr(t.year, 4) & "-" & intToStr(t.month, 2) & "-" & intToStr(t.day, 2) & "T" &
    intToStr(t.hour, 2) & ":" & intToStr(t.minute, 2) & ":" & intToStr(t.second, 2) &
    "." & intToStr(t.nanosecond div 1000, 6) & "Z"

func datFileStem*(s: DatInfo): string =
  ## A file name (without extension) for output made from `s`: the controller's
  ## serial number in four digits and the exact trigger time, UTC, to the
  ## nanosecond: `0042_20010203T040506.789000000Z`. It sorts by controller, then
  ## time, and holds no character Windows forbids.
  let t = s.trigger
  intToStr(int(s.controllerSerial mod 10_000_000_000'i64), 4) & "_" &
    intToStr(t.year, 4) & intToStr(t.month, 2) & intToStr(t.day, 2) & "T" &
    intToStr(t.hour, 2) & intToStr(t.minute, 2) & intToStr(t.second, 2) & "." &
    intToStr(t.nanosecond, 9) & "Z"

func len*(s: DatShot): int =
  ## Samples per channel present.
  s.data[dcReference].len

func samples*(s: DatShot; c: DatChannel): seq[float32] =
  ## The counts of channel `c` as `float32`; every 24-bit count is exact.
  result = newSeq[float32](s.data[c].len)
  for i, v in s.data[c]:
    result[i] = float32(v)

func groundForce*(s: DatShot): seq[int32] =
  ## The controller's ground force, estimated: the plain sum of its two force
  ## channels (reaction mass and baseplate), in counts. Each channel is below
  ## 2^23 in magnitude, so the sum cannot overflow.
  result = newSeq[int32](s.len)
  for i in 0 ..< result.len:
    result[i] = s.data[dcMass][i] + s.data[dcBaseplate][i]

# ------------------------------------------------------------------- GGA --

func decimal(t: string; a, b: int; signed: bool; v: var float64): bool =
  ## `t[a ..< b]` as a plain decimal number: digits, one point, a sign when
  ## `signed`, at most 15 digits. Exact: the quotient of two exactly held numbers.
  result = false
  var i = a
  var neg = false
  if signed and i < b and t[i] in {'-', '+'}:
    neg = t[i] == '-'
    inc i
  var mant = 0'i64
  var digits = 0
  var frac = 0
  var point = false
  var ok = true
  while i < b and ok:
    let c = t[i]
    if c in Digits:
      inc digits
      ok = digits <= 15
      if ok:
        mant = mant * 10 + int64(ord(c) - ord('0'))
        if point: inc frac
    elif c == '.' and not point:
      point = true
    else:
      ok = false
    inc i
  if ok and digits > 0:
    v = float64(mant) / Pow10[frac]
    if neg: v = -v
    result = true

func fieldAt(t: string; s0, stop, i: int; a, b: var int): bool =
  ## The range `a ..< b` of comma-separated field `i` of `t[s0 ..< stop]`.
  var idx = 0
  var j = s0
  a = s0
  result = false
  while j <= stop and not result:
    if j == stop or t[j] == ',':
      if idx == i:
        b = j
        result = true
      else:
        inc idx
        a = j + 1
    inc j

func degMin(t: string; a, b, degDigits, maxDeg: int; v: var float64): bool =
  ## `ddmm.mmmm` (or `dddmm.mmmm`) as unsigned decimal degrees.
  result = false
  if b - a >= degDigits + 2 and b - a <= 24 and t[a + degDigits] in Digits:
    var deg = 0
    var ok = true
    for i in a ..< a + degDigits:
      if t[i] in Digits: deg = deg * 10 + (ord(t[i]) - ord('0'))
      else: ok = false
    var minutes = 0.0
    if ok and decimal(t, a + degDigits, b, false, minutes) and minutes < 60 and
        deg <= maxDeg and (deg < maxDeg or minutes == 0):
      v = float64(deg) + minutes / 60
      result = true

func optDecimal(t: string; s0, stop, i: int; v: var float64): bool =
  ## Field `i` as a signed number; an empty or absent field is 0 and fine.
  var a, b: int
  v = 0
  result = not fieldAt(t, s0, stop, i, a, b) or a == b or decimal(t, a, b, true, v)

func optCount(t: string; s0, stop, i: int; v: var int): bool =
  var a, b: int
  v = 0
  result = true
  if fieldAt(t, s0, stop, i, a, b) and a < b:
    result = b - a <= 6
    for j in a ..< b:
      if t[j] in Digits: v = v * 10 + (ord(t[j]) - ord('0'))
      else: result = false

func hemisphere(t: string; s0, stop, i: int; plus, minus: char): int =
  ## 1 for `plus`, -1 for `minus`, 0 when field `i` is neither.
  var a, b: int
  result = 0
  if fieldAt(t, s0, stop, i, a, b) and b - a == 1:
    if t[a] == plus: result = 1
    elif t[a] == minus: result = -1

func parseGga*(text: string): DatGga =
  ## The first well-formed GGA sentence in `text` (the GNSS text of the header
  ## record). A sentence that is missing, cut off or malformed gives `valid = false`;
  ## the sentence's own checksum is not checked. An empty altitude, geoid
  ## separation, satellite count or HDOP field reads as 0. Allocates nothing.
  result = DatGga()
  var at = text.find("GGA,")
  while at >= 0 and not result.valid:
    if at >= 3 and text[at - 3] == '$':
      let s0 = at + 4
      var stop = s0
      while stop < text.len and text[stop] notin {'*', '\r', '\n', '$'}:
        inc stop
      # fields: 0 time, 1 latitude, 2 N/S, 3 longitude, 4 E/W, 5 quality, 6 satellites,
      # 7 HDOP, 8 altitude, 9 unit, 10 geoid separation
      var g = DatGga()
      var lat, lon: float64
      var a, b, c, d: int
      let ns = hemisphere(text, s0, stop, 2, 'N', 'S')
      let ew = hemisphere(text, s0, stop, 4, 'E', 'W')
      if ns != 0 and ew != 0 and fieldAt(text, s0, stop, 5, a, b) and a < b and
          fieldAt(text, s0, stop, 1, c, d) and degMin(text, c, d, 2, 90, lat):
        var e, f: int
        if fieldAt(text, s0, stop, 3, e, f) and degMin(text, e, f, 3, 180, lon) and
            optCount(text, s0, stop, 5, g.fixQuality) and
            optCount(text, s0, stop, 6, g.satellites) and
            optDecimal(text, s0, stop, 7, g.hdop) and
            optDecimal(text, s0, stop, 8, g.altitudeM) and
            optDecimal(text, s0, stop, 10, g.geoidSeparationM):
          g.latitudeDeg = float64(ns) * lat
          g.longitudeDeg = float64(ew) * lon
          g.valid = true
          result = g
    at = text.find("GGA,", at + 1)

# ------------------------------------------------------------ the fields --

func sanitizedInto(dst: var string; b: openArray[byte]; first, last: int) =
  ## The text of `b[first .. last]` up to the first NUL into `dst`; bytes of 0x80 and
  ## above and control characters other than CR and LF become `?`.
  dst.setLen(0)
  var i = first
  while i <= last and b[i] != 0:
    let c = b[i]
    dst.add(if (c >= 32 and c < 127) or c == 13 or c == 10: char(c) else: '?')
    inc i

func timeProblem(t: DatTime): bool =
  ## True when `t` is not a date and time of day.
  t.year notin 1970 .. 9999 or t.month notin 1 .. 12 or
    t.day notin 1 .. daysInMonth(t.year, t.month) or t.hour > 23 or t.minute > 59 or
    t.second > 60 or t.nanosecond notin 0 .. 999_999_999

proc triggerTime(b: openArray[byte]; offset: int64): DatTime =
  ## The header record's trigger time; `DatFormatError` when it is not a time.
  let ns = u32le(b, 492)
  if ns > 999_999_999:
    raiseFormat("the trigger time is not a valid date (nanoseconds " & $ns & ")", offset)
  result = DatTime(nanosecond: int(ns), second: int(b[496]), minute: int(b[497]),
    hour: int(b[498]), day: int(b[499]), month: int(b[500]), year: u16le(b, 501))
  if timeProblem(result):
    raiseFormat("the trigger time is not a valid date", offset)

func hemi(b: openArray[byte]; deg, minutes, letter: int; plus, minus: char;
    maxDeg: int): float64 =
  ## A coordinate of the position record: degrees, millionths of minutes, letter.
  let letterOk = char(b[letter]) in {plus, minus}
  let minutesE6 = u32le(b, minutes)
  if letterOk and int(b[deg]) <= maxDeg and minutesE6 < 60_000_000 and
      not (int(b[deg]) == maxDeg and minutesE6 != 0):
    result = float64(b[deg]) + float64(minutesE6) / 60e6
    if char(b[letter]) == minus: result = -result
  else:
    result = NaN

func positionFix(b: openArray[byte]): DatFix =
  DatFix(latitudeDeg: hemi(b, 135, 136, 140, 'N', 'S', 90),
    longitudeDeg: hemi(b, 141, 142, 146, 'E', 'W', 180), heightDm: i16le(b, 147),
    fixQuality: int(b[149]), satellites: int(b[150]), hdop: float64(b[151]) / 10)

func ns32(v: int64): int =
  ## A QC nanosecond field as an `int`: -1 when it is not below a second.
  if v in 0 .. 999_999_999: int(v) else: -1

func fillQc(q: var DatQc; b: openArray[byte]; length: int) =
  ## The embedded QC record: the first `46 33 00 E7` from block offset 97 whose 240
  ## bytes end within the record.
  q.valid = false
  q.raw.setLen(0)
  var at = QcStart
  while at + QcBytes <= length + 2 and not q.valid:
    if b[at] == 0x46 and b[at + 1] == 0x33 and b[at + 2] == 0 and b[at + 3] == 0xE7:
      q.valid = true
      q.raw.setLen(QcBytes)
      for i in 0 ..< QcBytes:
        q.raw[i] = b[at + i]
      q.crew = int(b[at + 4])
      q.vibratorId = int(b[at + 6])
      q.sweepId = u32be(b, at + 9)
      q.sweepNumber = int(b[at + 13])
      q.sweepChecksum = u16be(b, at + 24)
      q.paramChecksum = u16be(b, at + 26)
      q.trigger = DatTime(year: 2000 + int(b[at + 166]), month: int(b[at + 167]),
        day: int(b[at + 168]), hour: int(b[at + 169]), minute: int(b[at + 170]),
        second: int(b[at + 171]), nanosecond: ns32(u32be(b, at + 172)))
      q.shotId = u32be(b, at + 218)
      q.sourceLine = u32be(b, at + 222)
      q.sourceStation = u32be(b, at + 226)
    inc at

proc fillHeader(s: var DatInfo; b: openArray[byte]; offset: int64) =
  s.firmware = (int(b[20]), int(b[21]))
  s.trigger = triggerTime(b, offset)
  sanitizedInto(s.headerText, b, TextStart, TextEnd)
  s.gga = parseGga(s.headerText)

proc fillTrailer(s: var DatInfo; b: openArray[byte]; length: int) =
  s.sourceLine = u32be(b, 30)
  s.sourceStation = u32be(b, 34)
  s.shotId = u32be(b, 38)
  s.sourceIndex = u32be(b, 42)
  s.trailerCounter = u32be(b, 46)
  s.sweepId = u32be(b, 50)
  fillQc(s.qc, b, length)

func headerProblem(b: openArray[byte]): string =
  ## Why block `b` (512 bytes) is not a valid header record; "" when it is.
  let h = readHead(b)
  if h.length notin 20 .. MaxLength:
    "its length field is " & $h.length
  elif h.kind != KindHeader:
    "its record kind is 0x" & toHex(int(h.kind), 2) & ", not 0x80"
  elif not sumIsZero(b, h.length):
    "its checksum fails"
  elif h.blockNumber != 1:
    "its block number is " & $h.blockNumber & ", not 1"
  elif h.blockCount < 3 or h.blockCount >= MaxBlocks:
    "it announces " & $h.blockCount & " blocks"
  else:
    ""

func expectedKind(k, n: int): uint8 =
  ## The record kind block `k` (0-based) of a file of `n` blocks must hold.
  if k == 0: KindHeader
  elif k == 1: KindPosition
  elif k == n - 1: KindTrailer
  elif k == n - 2: KindLast
  else: KindData

func blockName(k, n: int): string =
  "block " & $(k + 1) & " of " & $n

proc checkBlock(b: openArray[byte]; k, n: int; first: RecordHead; offset: int64):
    RecordHead =
  ## The header of block `k` once it passed every check of its place in the file.
  let h = readHead(b)
  if h.length notin MinLength .. MaxLength:
    raiseFormat(blockName(k, n) & " has the record length " & $h.length, offset)
  if not sumIsZero(b, h.length):
    raiseFormat(blockName(k, n) & " fails its checksum", offset)
  let want = expectedKind(k, n)
  if h.kind != want:
    raiseFormat(blockName(k, n) & " is a " & kindName(h.kind) & " (0x" &
      toHex(int(h.kind), 2) & "), but a " & kindName(want) & " belongs there", offset)
  if h.blockNumber != k + 1:
    raiseFormat(blockName(k, n) & " is numbered " & $h.blockNumber, offset)
  if h.blockCount != n:
    raiseFormat(blockName(k, n) & " announces " & $h.blockCount &
      " blocks, the first block " & $n, offset)
  if h.fileNumber != first.fileNumber:
    raiseFormat(blockName(k, n) & " is from file " & $h.fileNumber & ", not " &
      $first.fileNumber, offset)
  if h.unit != first.unit:
    raiseFormat(blockName(k, n) & " is from controller " & $h.unit & ", not " &
      $first.unit, offset)
  case want
  of KindHeader:
    if h.length < HeaderMinLength:
      raiseFormat(blockName(k, n) & " is too short for a header record", offset)
  of KindPosition:
    if h.length < PositionMinLength:
      raiseFormat(blockName(k, n) & " is too short for a position record", offset)
  of KindTrailer:
    if h.length < TrailerMinLength:
      raiseFormat(blockName(k, n) & " is too short for a trailer", offset)
  of KindData:
    if framesIn(h.length) != FullFrames:
      raiseFormat(blockName(k, n) & " does not hold a full data record of " &
        $FullFrames & " frames", offset)
  else: # the last data record: 0 to a full record's frames
    let f = framesIn(h.length)
    if f < 0 or f > FullFrames:
      raiseFormat(blockName(k, n) & " does not hold a whole number of sample frames",
        offset)
  result = h

func sample24(b: openArray[byte]; at: int): int32 {.inline.} =
  let v = (int32(b[at]) shl 16) or (int32(b[at + 1]) shl 8) or int32(b[at + 2])
  if v >= 0x800000: v - 0x1000000 else: v

proc checkInterval(v: float64) =
  if not (v > 0 and v < Inf):
    raise newException(ValueError, "the sample interval must be positive and finite, " &
      "not " & $v)

proc firstBlock(b0: openArray[byte]; fileSize: int64): tuple[head: RecordHead; declared: int] =
  ## The checks of block 0 every reader makes.
  if fileSize < DatBlockBytes:
    raiseFormat("the file is " & $fileSize & " bytes, shorter than one " &
      $DatBlockBytes & "-byte block: not a .dat signature file", 0)
  let why = headerProblem(b0)
  if why.len > 0:
    raiseFormat("not a .dat signature file: the first block is not its header record (" &
      why & ")", 0)
  result.head = readHead(b0)
  let n = int(result.head.blockCount) # 3 .. MaxBlocks - 1
  let declared = u32be(b0, 46)
  if declared == 0 or declared > int64(n - 3) * FullFrames:
    raiseFormat("the header announces " & $declared & " samples, " &
      (if declared == 0: "none" else: "more than its " & $n & " blocks can hold"), 0)
  result.declared = int(declared)

proc cutWords(valid, n: int): string =
  "the file holds " & $valid & " of the " & $n &
    " blocks its header announces: the recording stopped or the copy was cut short"

proc beginInfo(s: var DatInfo; head: RecordHead; declared: int; interval: float64) =
  ## Sets every field of `s` that blocks 0 and 1 do not; keeps its buffers.
  s.controllerSerial = head.unit
  s.fileNumber = head.fileNumber
  s.sampleIntervalUs = interval
  s.blocks = int(head.blockCount)
  s.declaredSamples = declared
  s.samples = 0
  s.complete = true
  s.incompleteWhy.setLen(0)
  s.gga = DatGga()
  s.fix = DatFix()
  s.sourceLine = 0
  s.sourceStation = 0
  s.shotId = 0
  s.sourceIndex = 0
  s.sweepId = 0
  s.trailerCounter = 0
  s.qc.valid = false
  s.qc.raw.setLen(0)
  s.qc.crew = 0
  s.qc.vibratorId = 0
  s.qc.sweepId = 0
  s.qc.sweepNumber = 0
  s.qc.sweepChecksum = 0
  s.qc.paramChecksum = 0
  s.qc.trigger = DatTime()
  s.qc.shotId = 0
  s.qc.sourceLine = 0
  s.qc.sourceStation = 0

# ------------------------------------------------------------- the info --

proc parseDatInfo*(first, last: openArray[byte]; fileSize: int64;
    sampleIntervalUs = 1000.0): DatInfo =
  ## Everything about a file but its samples, from `first` (the file's first
  ## `min(fileSize, 1024)` bytes: header and position record), `last` (its last whole
  ## block, the one at `fileSize div 512 - 1`; may be empty when the file is shorter
  ## than a block) and the file's size. A file with every announced block, a valid
  ## trailer and no bytes after it is `complete`; one that is shorter is not, with
  ## the reason in words and `samples` an upper bound (a last block of zeros is not
  ## counted). Only those three blocks are looked at: a damaged data block is not
  ## found, `parseDat` finds it. Raises `DatFormatError` as `parseDat` does for the
  ## blocks it reads, `DatIncompleteError` for a file that ends before its position
  ## record, and `ValueError` for a bad interval or too short a `first` or `last`.
  checkInterval(sampleIntervalUs)
  if first.len < int(min(fileSize, 2 * DatBlockBytes)):
    raise newException(ValueError, "the first bytes of the file are missing")
  if fileSize < DatBlockBytes:
    discard firstBlock(first, fileSize) # raises: shorter than a block
  let b0 = blockAt(first, 0)
  let (head, declared) = firstBlock(b0, fileSize)
  let n = int(head.blockCount)
  beginInfo(result, head, declared, sampleIntervalUs)
  fillHeader(result, b0, 0)
  if fileSize < 2 * DatBlockBytes:
    raiseIncomplete(cutWords(1, n) & ", and the position record is missing", 512)
  let b1 = blockAt(first, 1)
  discard checkBlock(b1, 1, n, head, DatBlockBytes)
  result.fix = positionFix(b1)
  let present = int(min(fileSize div DatBlockBytes, int64(n)))
  if present >= n:
    if fileSize > int64(n) * DatBlockBytes:
      raiseFormat("the file holds " & $(fileSize - int64(n) * DatBlockBytes) &
        " bytes after the trailer", int64(n) * DatBlockBytes)
    if last.len < DatBlockBytes:
      raise newException(ValueError, "the last block of the file is missing")
    let bl = blockAt(last, 0)
    if isZeroBlock(bl):
      # a file of its full size whose end was never written: how far the data go is
      # not known without reading them
      result.complete = false
      result.incompleteWhy = cutWords(n - 1, n)
      result.samples = min(declared, (n - 3) * FullFrames)
    else:
      let h = checkBlock(bl, n - 1, n, head, int64(n - 1) * DatBlockBytes)
      fillTrailer(result, bl, h.length)
      result.samples = declared
  else:
    var valid = present
    if valid > 2 and last.len >= DatBlockBytes and isZeroBlock(last.toOpenArray(0,
        DatBlockBytes - 1)):
      dec valid
    result.complete = false
    result.incompleteWhy = cutWords(valid, n)
    result.samples = min(declared, max(0, valid - 2) * FullFrames)

proc parseDatInfo*(data: openArray[byte]; sampleIntervalUs = 1000.0): DatInfo =
  ## `parseDatInfo` of a whole file held in memory.
  let blocks = data.len div DatBlockBytes
  let lastAt = max(0, blocks - 1) * DatBlockBytes
  let lastEnd = if blocks > 0: lastAt + DatBlockBytes - 1 else: -1
  result = parseDatInfo(data.toOpenArray(0, min(data.len, 2 * DatBlockBytes) - 1),
    data.toOpenArray(lastAt, lastEnd), int64(data.len), sampleIntervalUs)

proc readDatInfo*(path: string; sampleIntervalUs = 1000.0): DatInfo =
  ## The `DatInfo` of the file at `path`, reading its first two blocks and its last
  ## (whole) block and nothing else; see `parseDatInfo`. A file larger than
  ## `MaxDatBytes` raises `DatFormatError`; one that cannot be read, `IOError` with
  ## the path.
  var head: array[2 * DatBlockBytes, byte]
  var tail: array[DatBlockBytes, byte]
  var size = 0'i64
  var nHead = 0
  var nTail = 0
  try:
    size = getFileSize(path)
    if size > MaxDatBytes:
      raiseFormat(path & " is larger than any .dat signature file", 0)
    let f = open(path, fmRead)
    try:
      nHead = f.readBuffer(addr head[0], int(min(size, int64(head.len))))
      let blocks = size div DatBlockBytes
      if blocks >= 1 and nHead == int(min(size, int64(head.len))):
        f.setFilePos((blocks - 1) * DatBlockBytes)
        nTail = f.readBuffer(addr tail[0], DatBlockBytes)
    finally:
      f.close()
  except OSError as e:
    raise newException(IOError, "cannot read " & path & ": " & e.msg)
  except IOError as e:
    raise newException(IOError, "cannot read " & path & ": " & e.msg)
  if nHead != int(min(size, int64(head.len))) or (size >= DatBlockBytes and
      nTail != DatBlockBytes):
    raise newException(IOError, "cannot read " & path & ": the file changed while it was read")
  result = parseDatInfo(head.toOpenArray(0, nHead - 1), tail.toOpenArray(0, nTail - 1),
    size, sampleIntervalUs)

# ------------------------------------------------------------ the shot --

proc decodeInto*(s: var DatShot; data: openArray[byte]; allowIncomplete = false;
    sampleIntervalUs = 1000.0) =
  ## Decodes the bytes of a `.dat` file into `s`, which a caller keeps between files:
  ## its sample arrays, strings and records are reused, so after the first few files
  ## nothing is allocated. `s` holds nothing useful after an exception.
  ##
  ## Raises `DatFormatError` for a file that is not one or whose bytes break the
  ## format (the message names the block) and `DatIncompleteError` for a file that
  ## ends or turns to zeros before the blocks its header announces, unless
  ## `allowIncomplete` is set: then such a file gives the shot with the samples of the
  ## records before the cut (`complete = false`, `incompleteWhy` in words, the trailer
  ## fields 0), provided its header and position records and at least one sample are
  ## there (else `DatIncompleteError` too). `ValueError` for an interval that is not
  ## positive and finite. A zero block followed by a block that holds data is corruption,
  ## not an ending. No input makes it raise a `Defect` or allocate more than a small
  ## multiple of `data.len`.
  checkInterval(sampleIntervalUs)
  if data.len < DatBlockBytes:
    discard firstBlock(data.toOpenArray(0, -1), data.len) # raises: shorter than a block
  let b0 = blockAt(data, 0)
  let (first, wanted) = firstBlock(b0, data.len)
  let n = int(first.blockCount)
  beginInfo(s, first, wanted, sampleIntervalUs)
  let present = min(n, data.len div DatBlockBytes)
  # Never size from a stated number: at most the frames the present blocks can hold.
  let room = min(wanted, present * FullFrames)
  for c in DatChannel:
    s.data[c].setLen(room)
  var got = 0
  var valid = 0 # blocks that passed
  var cut = false
  var keptNow = 0
  while valid < present and not cut:
    let k = valid
    let b = blockAt(data, k)
    let offset = int64(k) * DatBlockBytes
    if k >= 2 and isZeroBlock(b):
      for j in k + 1 ..< present:
        if not isZeroBlock(blockAt(data, j)):
          raiseFormat(blockName(k, n) & " is all zeros, but " & blockName(j, n) &
            " after it holds data", offset)
      cut = true
    else:
      let h = checkBlock(b, k, n, first, offset)
      case h.kind
      of KindHeader:
        fillHeader(s, b, offset)
      of KindPosition:
        s.fix = positionFix(b)
      of KindData, KindLast:
        let frames = framesIn(h.length)
        if got + frames > wanted:
          raiseFormat("the data records hold more than the " & $wanted &
            " samples the header announces", offset)
        for i in 0 ..< frames:
          let at = PayloadStart + i * FrameBytes
          s.data[dcReference][got + i] = sample24(b, at)
          s.data[dcMass][got + i] = sample24(b, at + 3)
          s.data[dcBaseplate][got + i] = sample24(b, at + 6)
        got += frames
      else: # the trailer
        fillTrailer(s, b, h.length)
      if h.kind in {KindHeader, KindPosition, KindTrailer}:
        if keptNow >= s.records.len:
          s.records.add DatRawRecord()
        s.records[keptNow].kind = h.kind
        s.records[keptNow].offset = offset
        s.records[keptNow].bytes.setLen(DatBlockBytes)
        for i in 0 ..< DatBlockBytes:
          s.records[keptNow].bytes[i] = b[i]
        inc keptNow
      inc valid
  for c in DatChannel:
    s.data[c].setLen(got)
  if s.records.len != keptNow:
    s.records.setLen(keptNow)
  s.samples = got
  if valid < n:
    let why = cutWords(valid, n)
    if not allowIncomplete:
      raiseIncomplete(why, int64(valid) * DatBlockBytes)
    if valid < 2:
      raiseIncomplete(why & ", and the position record is missing",
        int64(valid) * DatBlockBytes)
    if got == 0:
      raiseIncomplete(why & ": no samples were recorded", int64(valid) * DatBlockBytes)
    s.complete = false
    s.incompleteWhy = why
  else:
    if data.len > n * DatBlockBytes:
      raiseFormat("the file holds " & $(data.len - n * DatBlockBytes) &
        " bytes after the trailer", int64(n) * DatBlockBytes)
    if got != wanted:
      raiseFormat("the data records hold " & $got & " samples, the header announces " &
        $wanted, 0)

proc parseDat*(data: openArray[byte]; allowIncomplete = false;
    sampleIntervalUs = 1000.0): DatShot =
  ## Decodes the bytes of a `.dat` file; see `decodeInto`. `sampleIntervalUs` is the
  ## interval of the samples: the file does not state it, so this is an assumption of
  ## the caller (1 ms for every file seen).
  result = DatShot()
  decodeInto(result, data, allowIncomplete, sampleIntervalUs)

proc readDatInto*(path: string; s: var DatShot; buffer: var seq[byte];
    allowIncomplete = false; sampleIntervalUs = 1000.0) =
  ## Reads the file at `path` into `buffer` (which the caller keeps for the next
  ## file) and decodes it into `s`; see `decodeInto`. A file larger than `MaxDatBytes`
  ## raises `DatFormatError` before it is read; one that cannot be read, `IOError`
  ## with the path.
  try:
    let size = getFileSize(path)
    if size > MaxDatBytes:
      raiseFormat(path & " is larger than any .dat signature file", 0)
    buffer.setLen(int(size))
    let f = open(path, fmRead)
    try:
      if size > 0 and f.readBuffer(addr buffer[0], int(size)) != int(size):
        raise newException(IOError, "the file is shorter than its size says")
    finally:
      f.close()
  except OSError as e:
    raise newException(IOError, "cannot read " & path & ": " & e.msg)
  except IOError as e:
    raise newException(IOError, "cannot read " & path & ": " & e.msg)
  decodeInto(s, buffer, allowIncomplete, sampleIntervalUs)

proc readDat*(path: string; allowIncomplete = false; sampleIntervalUs = 1000.0): DatShot =
  ## Reads and decodes the file at `path` (see `parseDat`).
  var buffer: seq[byte] = @[]
  result = DatShot()
  readDatInto(path, result, buffer, allowIncomplete, sampleIntervalUs)
