## A decoded `.dat` shot as SEG-Y or SEG-D, through parseSEG's writers.
##
## `toTraceKeys` and `DatShot.samples` give the shape parseSEG's `writeTrace` takes;
## `writeSegyTraces` and `writeSegdTraces` hand every trace of a shot to an open
## writer, so several shots can go into one file, a record each (the record is the
## file number). The `.dat` holds raw counts: the options of `DatWriteOptions` decide
## any scaling, mean removal and derived trace.
##
## **Traces.** 1 reference (SEG-Y code 21, SEG-D channel type 0x96), 2 the
## controller's reaction-mass force channel (18, 0x99), 3 its baseplate force channel
## (19, 0x95) and, unless switched off, 4 the controller's ground force, estimated as
## the plain sum of traces 2 and 3 (20, 0x93). The external converter that some sites
## use labels the two force channels the other way round.
##
## **The shot block.** With `vendorLayout` (the default) every decoded value of the shot
## goes into the file too, as a 2048-byte block (`shotBlock`): in SEG-Y the stanza
## `parseSSDAT:Shot v1`, in SEG-D the record's external header. The vendor maps in
## `vendormaps/` decode it by name through parseSEG. Nothing in it changes a sign.
##
## **Errors.** A value the format cannot hold or an option that makes no sense raises
## `DatWriteError` with plain words that name the value: a source index above 255, a
## file number above 16777215, or a line without a station, in SEG-D; a weight that is
## not above 0; an interval that is not a whole number of microseconds for SEG-D; an
## existing file in the folder forms. Whatever else parseSEG refuses for a shot (a
## station too wide for SEG-D, say) is translated into the same error, with parseSEG's
## words after the shot's file number. Problems with the file system, and diagnostics
## the writer reports when it closes, are `IOError`.

import std/[math, options, os, strutils]
when defined(windows):
  import std/winlean
else:
  import std/posix
import parseSEG
import ./[decode, types]

const
  PackageVersion = "0.1.1"
  CodeGroundForce = 20'i16 ## SEG-Y trace code of the controller's ground force
  CardWidth = 76           ## parseSEG puts "C nn " before each textual header card of 80
  RecognitionCard = 37     ## the textual header card that names the shot stanzas
  ShotLayoutVersion = 1
  QcRecordBytes = 240      ## the QC record the block holds
  RawRecordBytes = 512     ## each of the three raw records (one block of the file)
  MaxCards = 38            ## textual header cards a writer takes
  MaxSegdSourceIndex = 255
  MaxSegdFileNumber = 16_777_215

const
  ShotCardText* = "PARSESSDAT SHOT STANZAS VERSION 1 (MAP PARSESSDAT-SEGY-1)"
    ## Card 37 of a SEG-Y file written with `vendorLayout`: what the vendor map
    ## `parseSSDAT-segy-1` recognises the file by.
  ShotBlockBytes* = 2048 ## the size of the shot block
  ShotMagic* = "SSDATSHT" ## its first eight bytes, which the SEG-D map recognises it by

type
  DatPositions* = enum
    ## Which position goes into the SEG-Y trace keys.
    dpNone ## no coordinates in the keys
    dpGga  ## the GGA sentence of the header text
    dpFix  ## the position record's binary fix

  DatConverterUnit* = object
    ## What a user types to get the external converter's four traces (see
    ## `DatWriteOptions.externalConverter`). Nothing here has a built-in value: the weights
    ## are the vibrator's, the two constants are the converter's own.
    reactionMassWeight*, baseplateWeight*, holdDownWeight*: float64 ## pounds
    k*, s0*: float64 ## the converter's constants for the force channels and the reference

  DatWriteOptions* = object
    ## What the writers do with a shot.
    positions*: DatPositions = dpGga
      ## SEG-Y only: coordinates of the keys, in arc seconds (units 2). SEG-D has no
      ## field for geographic coordinates (its position blocks take projected units),
      ## so `writeSegdTraces` writes none and ignores this.
    scale*: array[DatChannel, float64] = [1.0, 1.0, 1.0] ## multiplies the counts
    removeMean*: bool = false ## subtract each channel's mean (before scaling)
    groundForce*: bool = true
      ## Add the fourth trace: the controller's ground force, estimated as the sum of
      ## the two force traces as written (so after scaling and mean removal).
    swapForces*: bool = false
      ## An escape for a unit wired the other way round: write the second channel of
      ## the file as the baseplate force and the third as the reaction-mass force.
    segdReference*: SegdChannelType = sctSourceRefSweep
      ## The SEG-D channel type of the reference: `sctSourceRefSweep` (0x96) or
      ## `sctSourceRefPilot` (0x98).
    vendorLayout*: bool = true
      ## Write the whole shot into the file as a shot block (`shotBlock`): in SEG-Y one
      ## binary stanza `parseSSDAT:Shot v1` in the extended textual header, found by
      ## card 37 of the textual header; in SEG-D the record's external header. False
      ## writes a plain file with only the standard fields and traces (the same traces).
      ## SEG-Y Rev 0 has no stanzas: `writeSegy` refuses it with `vendorLayout`.
    lbfPerCount*: float64 = 0.0
      ## Pounds-force per count, written into the shot block as given, never computed
      ## (about 1/8, but not exactly known). 0 means none given.
    externalConverter*: Option[DatConverterUnit]
      ## When set, the writers produce the four traces of the external converter
      ## instead (this replaces `scale`, `removeMean` and `groundForce`): trace 1 is
      ## `s0 * (reference - mean)`, trace 2 `k / reactionMassWeight * (channel 2 -
      ## mean)`, trace 3 `k / baseplateWeight * (channel 3 - mean)`, trace 4
      ## `holdDownWeight * (trace 2 + trace 3)`. Trace 4 is an equal-weight sum of two
      ## accelerations times the hold-down weight. It is not a mass-weighted sum and
      ## not the controller's ground force. All five numbers must be above 0.

  OutTrace = object
    keys: TraceKeys
    samples: seq[float32]
    channelType: SegdChannelType

func segyTraceCode*(c: DatChannel): int16 =
  ## The SEG-Y trace identification code of a channel: 21 reference, 18 reaction-mass
  ## force, 19 baseplate force.
  case c
  of dcReference: 21
  of dcMass: 18
  of dcBaseplate: 19

func segdChannelType*(c: DatChannel; reference = sctSourceRefSweep): SegdChannelType =
  ## The SEG-D Rev 3 channel type: source reference sweep (0x96, or `reference`),
  ## source reaction mass (0x99), source baseplate (0x95).
  case c
  of dcReference: reference
  of dcMass: sctSourceMass
  of dcBaseplate: sctSourceBasePlate

func arcSeconds(deg: float64): float64 =
  deg * 3600

func toTraceKeys*(s: DatInfo; c: DatChannel; positions = dpNone): TraceKeys =
  ## The geometry of channel `c` of `s` in parseSEG's shape: the record is the file
  ## number, the channel number is the file order from 1, the trace code
  ## `segyTraceCode`, the status auxiliary, the time the trigger time as seconds, the
  ## interval as `s` says, the source line and point the trailer's (NaN when 0). With
  ## a position the source and receiver coordinates are longitude and latitude in arc
  ## seconds, and with `dpGga` the elevations are the GGA altitude in metres.
  result = initTraceKeys()
  result.record = float64(s.fileNumber)
  result.channel = float64(ord(c) + 1)
  result.traceCode = segyTraceCode(c)
  result.status = tsAuxiliary
  result.intervalUs = s.sampleIntervalUs
  result.t0Ms = 0
  result.time = posixTime(s.trigger)
  if s.sourceLine != 0: result.srcLine = float64(s.sourceLine)
  if s.sourceStation != 0: result.srcPoint = float64(s.sourceStation)
  if s.sourceIndex in 1 .. int64(high(int16)): result.srcIndex = int16(s.sourceIndex)
  case positions
  of dpNone:
    discard
  of dpGga:
    if s.gga.valid:
      result.srcX = arcSeconds(s.gga.longitudeDeg)
      result.srcY = arcSeconds(s.gga.latitudeDeg)
      result.srcZ = s.gga.altitudeM
  of dpFix:
    if not s.fix.longitudeDeg.isNaN and not s.fix.latitudeDeg.isNaN:
      result.srcX = arcSeconds(s.fix.longitudeDeg)
      result.srcY = arcSeconds(s.fix.latitudeDeg)
  result.rcvX = result.srcX
  result.rcvY = result.srcY
  result.rcvZ = result.srcZ

func writtenPositions*(s: DatInfo; positions: DatPositions): DatPositions =
  ## The positions that are written for `s` when `positions` is asked: `dpNone` when the
  ## shot has none of that kind (`dpGga` without a valid GGA sentence, `dpFix` with no
  ## fix).
  result = positions
  if (positions == dpGga and not s.gga.valid) or (positions == dpFix and
      (s.fix.latitudeDeg.isNaN or s.fix.longitudeDeg.isNaN)):
    result = dpNone

func incompleteWords(why: string): string =
  ## `why` cut at the last space within 76 characters: the room the block has.
  if why.len <= 76:
    result = why
  else:
    let at = why.rfind(' ', 0, 76)
    result = if at > 0: why[0 ..< at] else: why[0 ..< 76]

proc putBe(b: var seq[byte]; at, width: int; v: uint64) =
  for i in 0 ..< width:
    b[at + i] = byte((v shr (8 * (width - 1 - i))) and 0xFF)

proc putFloat(b: var seq[byte]; at: int; v: float64) =
  putBe(b, at, 8, cast[uint64](v))

proc putFloat32(b: var seq[byte]; at: int; v: float32) =
  putBe(b, at, 4, uint64(cast[uint32](v)))

func clampTo(v: int; hi: int): uint64 =
  uint64(max(0, min(v, hi)))

func recordBytes(s: DatShot; kind: uint8): seq[byte] =
  ## The raw block of the header, position or trailer record; empty when `s` has none.
  result = @[]
  for r in s.records:
    if r.kind == kind: result = r.bytes

proc fail(s: DatInfo; what: string) {.noinline, noreturn.} =
  raise newException(DatWriteError, "file number " & $s.fileNumber & ": " & what)

proc checkBlockFields(s: DatShot) =
  ## The shot block holds 32-bit fields and a 240-byte QC record and three 512-byte
  ## records: refuse a shot that does not fit them, in words, rather than wrap or
  ## overwrite.
  for (name, v) in [("controller serial", s.controllerSerial),
      ("file number", s.fileNumber), ("declared samples", int64(s.declaredSamples)),
      ("samples", int64(s.len)), ("source line", s.sourceLine),
      ("source station", s.sourceStation), ("shot id", s.shotId),
      ("source index", s.sourceIndex), ("trailer counter", s.trailerCounter),
      ("sweep id", s.sweepId)]:
    if v < 0 or v > 4_294_967_295'i64:
      fail(s, "the " & name & " " & $v & " does not fit the 32 bits of the shot block " &
        "(set vendorLayout to false to write the file without it)")
  let t = s.trigger
  if t.year notin 0 .. 65535 or t.month notin 0 .. 255 or t.day notin 0 .. 255 or
      t.hour notin 0 .. 255 or t.minute notin 0 .. 255 or t.second notin 0 .. 255 or
      t.nanosecond notin 0 .. 999_999_999:
    fail(s, "the trigger time " & $t.year & "-" & $t.month & "-" & $t.day & " " & $t.hour &
      ":" & $t.minute & ":" & $t.second & "." & $t.nanosecond &
      " does not fit the shot block")
  if s.firmware.major notin 0 .. 255 or s.firmware.minor notin 0 .. 255:
    fail(s, "the firmware version does not fit the shot block")
  if s.qc.raw.len notin [0, QcRecordBytes]:
    fail(s, "the QC record has " & $s.qc.raw.len & " bytes, not " & $QcRecordBytes)
  if s.fix.heightDm notin -32768 .. 32767:
    fail(s, "the fix height " & $s.fix.heightDm & " does not fit the 16 bits of the shot block")
  if s.fix.fixQuality notin 0 .. 255 or s.fix.satellites notin 0 .. 255:
    fail(s, "the fix quality or satellite count does not fit the shot block")
  if not (s.fix.hdop >= 0 and s.fix.hdop * 10 < 255.5):
    fail(s, "the fix HDOP " & $s.fix.hdop & " does not fit the shot block (0 to 25.5)")
  for r in s.records:
    if r.bytes.len != RawRecordBytes:
      fail(s, "a raw record of the file has " & $r.bytes.len & " bytes, not " &
        $RawRecordBytes)

proc shotBlock*(s: DatShot; opts: DatWriteOptions): seq[byte] =
  ## The 2048-byte shot block: every decoded value of `s`, the controller's 240-byte QC
  ## record and the file's header, position and trailer records, verbatim (so the bytes
  ## nobody has decoded survive). Big-endian, laid out as the vendor maps in
  ## `vendormaps/` say (byte 1 `SSDATSHT`, layout version 1, block length 2048). Unused
  ## bytes are 0 (the 76 of `incompleteWhy` are blanks, and the words are cut at the last
  ## space within 76 characters: the block has no more room for them); a latitude or longitude that is NaN means none; a record the shot has
  ## not got (a stopped recording has no trailer) is zeros. `opts` supplies what the
  ## shot does not hold: the scale factors, mean removal, ground force trace, the
  ## positions that are written (`writtenPositions`) and `lbfPerCount`. The samples are not in it, and no sign is
  ## changed anywhere. Raises `DatWriteError`, in words, when a value does not fit its
  ## place in the block (a number above 32 bits or below 0, a date field above 255, a
  ## record of the wrong length): nothing is wrapped (the GGA fix quality and satellite count, which a
  ## sentence can give above 255, are held at 255 as in 0.1.0).
  checkBlockFields(s)
  result = newSeq[byte](ShotBlockBytes)
  for i, c in ShotMagic:
    result[i] = byte(c)
  putBe(result, 8, 2, ShotLayoutVersion)
  putBe(result, 10, 2, ShotBlockBytes)
  putBe(result, 12, 4, uint64(s.controllerSerial))
  putBe(result, 16, 4, uint64(s.fileNumber))
  result[20] = byte(clampTo(s.firmware.major, 255))
  result[21] = byte(clampTo(s.firmware.minor, 255))
  result[22] = byte(ord(s.complete))
  result[23] = byte(ord(high(DatChannel)) + 1)
  putBe(result, 24, 4, uint64(s.len))
  putBe(result, 28, 4, uint64(s.declaredSamples))
  putFloat(result, 32, s.sampleIntervalUs)
  putBe(result, 40, 2, clampTo(s.trigger.year, 65535))
  result[42] = byte(clampTo(s.trigger.month, 255))
  result[43] = byte(clampTo(s.trigger.day, 255))
  result[44] = byte(clampTo(s.trigger.hour, 255))
  result[45] = byte(clampTo(s.trigger.minute, 255))
  result[46] = byte(clampTo(s.trigger.second, 255))
  putBe(result, 48, 4, clampTo(s.trigger.nanosecond, 999_999_999))
  putBe(result, 52, 4, uint64(s.sourceLine))
  putBe(result, 56, 4, uint64(s.sourceStation))
  putBe(result, 60, 4, uint64(s.shotId))
  putBe(result, 64, 4, uint64(s.sourceIndex))
  putBe(result, 68, 4, uint64(s.trailerCounter))
  putBe(result, 72, 4, uint64(s.sweepId))
  if s.gga.valid:
    putFloat(result, 76, s.gga.latitudeDeg)
    putFloat(result, 84, s.gga.longitudeDeg)
    putFloat(result, 92, s.gga.altitudeM)
    putFloat(result, 100, s.gga.geoidSeparationM)
    putFloat32(result, 108, float32(s.gga.hdop))
    result[112] = byte(clampTo(s.gga.fixQuality, 255))
    result[113] = byte(clampTo(s.gga.satellites, 255))
    result[114] = 1
  else:
    putFloat(result, 76, NaN)
    putFloat(result, 84, NaN)
  putFloat(result, 116, s.fix.latitudeDeg)
  putFloat(result, 124, s.fix.longitudeDeg)
  putBe(result, 132, 2, uint64(max(-32768, min(s.fix.heightDm, 32767)) and 0xFFFF))
  result[134] = byte(clampTo(s.fix.fixQuality, 255))
  result[135] = byte(clampTo(s.fix.satellites, 255))
  result[136] = byte(clampTo(int(round(s.fix.hdop * 10)), 255))
  putFloat(result, 144, opts.lbfPerCount)
  putFloat(result, 152, opts.scale[dcReference])
  putFloat(result, 160, opts.scale[dcMass])
  putFloat(result, 168, opts.scale[dcBaseplate])
  result[176] = byte(ord(opts.removeMean or opts.externalConverter.isSome))
  result[177] = byte(ord(opts.groundForce or opts.externalConverter.isSome))
  result[178] = 0 # polarity: always as recorded
  result[179] = byte(ord(writtenPositions(s, opts.positions)))
  let why = incompleteWords(s.incompleteWhy)
  for i in 0 ..< 76: # blanks, so that the map's `(trim right)` gives the words alone
    result[180 + i] = if i < why.len: byte(why[i]) else: 0x20
  for i, v in s.qc.raw:
    result[256 + i] = v
  for (kind, at) in [(0x80'u8, 512), (0x87'u8, 1024), (0x84'u8, 1536)]:
    for i, v in recordBytes(s, kind):
      result[at + i] = v

func meanOf(v: openArray[int32]): float64 =
  var sum = 0'i64
  for x in v:
    sum += int64(x)
  if v.len > 0: float64(sum) / float64(v.len) else: 0.0

func source(c: DatChannel; swap: bool): DatChannel =
  ## The channel of the file that is written as role `c`.
  if swap and c == dcMass: dcBaseplate
  elif swap and c == dcBaseplate: dcMass
  else: c

func positive(v: float64): bool =
  v > 0 and v < Inf

proc checkOptions(s: DatShot; opts: DatWriteOptions; segd: bool) =
  ## Everything that makes a shot or the options unwritable and that parseSEG would
  ## say in its own words, said in ours.
  if s.len == 0:
    fail(s, "the shot holds no samples")
  for c in DatChannel:
    if s.data[c].len != s.len:
      fail(s, "the " & $c & " channel has " & $s.data[c].len & " samples, the " &
        "reference " & $s.len)
  if not (opts.lbfPerCount >= 0 and opts.lbfPerCount < Inf):
    fail(s, "the pound-force per count is " & $opts.lbfPerCount &
      ", not a number of 0 or more (0 means none given)")
  if opts.vendorLayout:
    checkBlockFields(s)
  if opts.externalConverter.isSome:
    let c = opts.externalConverter.get
    for (name, v) in [("reaction-mass weight", c.reactionMassWeight),
        ("baseplate weight", c.baseplateWeight), ("hold-down weight", c.holdDownWeight),
        ("k", c.k), ("s0", c.s0)]:
      if not positive(v):
        fail(s, "the converter's " & name & " is " & $v & ", not above 0")
  else:
    for c in DatChannel:
      if not (opts.scale[c] > -Inf and opts.scale[c] < Inf):
        fail(s, "the scale of the " & $c & " is " & $opts.scale[c])
  if segd:
    if opts.segdReference notin {sctSourceRefSweep, sctSourceRefPilot}:
      fail(s, "the SEG-D reference channel type is 0x" &
        toHex(ord(opts.segdReference), 2) & ", not 0x96 or 0x98")
    if s.sampleIntervalUs != floor(s.sampleIntervalUs):
      fail(s, "the sample interval " & $s.sampleIntervalUs &
        " us is not a whole number of microseconds, which SEG-D needs")
    if s.fileNumber > MaxSegdFileNumber:
      fail(s, "the file number " & $s.fileNumber & " is above " & $MaxSegdFileNumber &
        ", the most SEG-D can number")
    if (s.sourceLine != 0) != (s.sourceStation != 0):
      fail(s, "SEG-D needs both a source line and a station, this file has only " &
        (if s.sourceLine != 0: "a line (" & $s.sourceLine & ")" else:
        "a station (" & $s.sourceStation & ")"))
    if s.sourceIndex > MaxSegdSourceIndex:
      fail(s, "the source index " & $s.sourceIndex & " is above " &
        $MaxSegdSourceIndex & ", the most SEG-D can hold")

proc outTraces(s: DatShot; opts: DatWriteOptions; segd, exactTime: bool): seq[OutTrace] =
  ## The traces to write: keys, samples and SEG-D channel type of each.
  let positions = if segd: dpNone else: opts.positions
  var scaled: array[DatChannel, seq[float64]]
  var gf: seq[float64] = @[]
  if opts.externalConverter.isSome:
    let cv = opts.externalConverter.get
    let factor = [cv.s0, cv.k / cv.reactionMassWeight, cv.k / cv.baseplateWeight]
    for c in DatChannel:
      let d = source(c, opts.swapForces)
      let m = meanOf(s.data[d])
      scaled[c] = newSeq[float64](s.len)
      for i, x in s.data[d]:
        scaled[c][i] = factor[ord(c)] * (float64(x) - m)
    gf = newSeq[float64](s.len)
    for i in 0 ..< s.len:
      gf[i] = cv.holdDownWeight * (scaled[dcMass][i] + scaled[dcBaseplate][i])
  else:
    for c in DatChannel:
      let d = source(c, opts.swapForces)
      let m = if opts.removeMean: meanOf(s.data[d]) else: 0.0
      scaled[c] = newSeq[float64](s.len)
      for i, x in s.data[d]:
        scaled[c][i] = opts.scale[c] * (float64(x) - m)
    if opts.groundForce:
      gf = newSeq[float64](s.len)
      for i in 0 ..< s.len:
        gf[i] = scaled[dcMass][i] + scaled[dcBaseplate][i]
  var secondsOnly = s.trigger
  secondsOnly.nanosecond = 0
  for c in DatChannel:
    var k = toTraceKeys(s, c, positions)
    if exactTime: k.time = posixTime(secondsOnly)
    if segd and k.srcIndex > MaxSegdSourceIndex: k.srcIndex = 0
    var v = newSeq[float32](s.len)
    for i in 0 ..< s.len:
      v[i] = float32(scaled[c][i])
    result.add OutTrace(keys: k, samples: v,
      channelType: segdChannelType(c, opts.segdReference))
  if gf.len > 0:
    var k = toTraceKeys(s, dcReference, positions)
    if exactTime: k.time = posixTime(secondsOnly)
    k.channel = 4
    k.traceCode = CodeGroundForce
    var v = newSeq[float32](s.len)
    for i in 0 ..< s.len:
      v[i] = float32(gf[i])
    result.add OutTrace(keys: k, samples: v, channelType: sctSourceSigEstimated)

template translating(s: DatInfo; what: string; body: untyped) =
  try:
    body
  except IOError:
    raise
  except DatWriteError:
    raise
  except CatchableError as e:
    fail(s, "cannot be written as " & what & ": " & e.msg)

proc writeSegyTraces*(w: var SeismicWriter; s: DatShot; opts = DatWriteOptions();
    extHeader = false) =
  ## Appends the traces of `s` to the open SEG-Y writer `w`: one record, numbered by
  ## the file number. `extHeader` must be set only for a Rev 2 or later writer (the
  ## default, false, suits every revision): the trigger time's nanoseconds then go
  ## exactly into Trace Header Extension 1, which a Rev 1 or Rev 0 writer has not
  ## got (it would refuse them). Without it the time goes in as seconds with a
  ## fraction, as far as the format and the writer keep one. `writeSegy` sets it from
  ## its options. The controller's vibrator ID goes into the trace
  ## header's device trace identifier when the file has a QC record and the ID fits
  ## 16 bits. Raises `DatWriteError` (see the module's text).
  checkOptions(s, opts, false)
  var overrides: seq[HeaderOverride] = @[]
  if writtenPositions(s, opts.positions) != dpNone:
    overrides.add headerOverride("trace.coordinateUnits", 2)
  if s.qc.valid and s.qc.vibratorId <= int(high(int16)):
    overrides.add headerOverride("trace.deviceTraceId", s.qc.vibratorId)
  if extHeader:
    overrides.add headerOverride("ext1.nanoseconds", s.trigger.nanosecond)
  for t in outTraces(s, opts, false, extHeader):
    translating(s, "SEG-Y"):
      w.writeTrace(t.keys, t.samples, overrides, t.channelType)

proc writeSegdTraces*(w: var SeismicWriter; s: DatShot; opts = DatWriteOptions()) =
  ## Appends the traces of `s` to the open SEG-D Rev 3 writer `w`, one record numbered
  ## by the file number (records must not go backwards: sort shots by file number).
  ## No position is written: SEG-D has no place for geographic coordinates, and
  ## `opts.positions` is ignored. The trigger time is kept to the microsecond, the
  ## resolution of SEG-D's timestamps. With `vendorLayout` the first trace of the
  ## record carries the shot block as the record's external header. Raises
  ## `DatWriteError` (see the module's text).
  checkOptions(s, opts, true)
  var block0: seq[byte] = @[]
  if opts.vendorLayout:
    var o = opts
    o.positions = dpNone # none is written in SEG-D, and the block says so
    block0 = shotBlock(s, o)
  var first = true
  for t in outTraces(s, opts, true, false):
    translating(s, "SEG-D"):
      w.writeTrace(t.keys, t.samples, [], t.channelType,
        externalHeader = (if first: block0 else: @[]))
    first = false

func wrapped(cards: var seq[string]; text: string) =
  ## Adds `text` as cards of at most `CardWidth` characters, broken at spaces.
  var rest = text
  while rest.len > CardWidth:
    var at = rest.rfind(' ', 0, CardWidth)
    if at <= 2: at = CardWidth # no space to break at (the indent counts): cut the word
    cards.add rest[0 ..< at]
    rest = "  " & rest[at .. ^1].strip(trailing = false)
  cards.add rest

func withShotCard*(cards: seq[string]): seq[string] =
  ## `cards` as the first 36 cards (blank ones added) and card 37 `ShotCardText`, which
  ## a SEG-Y file with shot stanzas must carry. Cards beyond the 36th are dropped.
  result = cards
  if result.len > RecognitionCard - 1:
    result.setLen(RecognitionCard - 1)
  while result.len < RecognitionCard - 1:
    result.add ""
  result.add ShotCardText

func textCards*(s: DatInfo; opts: DatWriteOptions; positions = dpGga): seq[string] =
  ## The textual header cards of a SEG-Y file written from `s`: each at most 76
  ## characters (parseSEG adds a card number), longer lines continued on the next card.
  var cards: seq[string] = @[]
  cards.wrapped "vibrator controller .dat signature file"
  cards.wrapped "controller serial " & $s.controllerSerial & ", file " & $s.fileNumber
  if s.qc.valid:
    cards.wrapped "vibrator ID " & $s.qc.vibratorId & ", crew " & $s.qc.crew &
      ", sweep number " & $s.qc.sweepNumber
  cards.wrapped "sweep id " & $s.sweepId & ", shot id " & $s.shotId
  cards.wrapped "source line " & $s.sourceLine & " station " & $s.sourceStation &
    " index " & $s.sourceIndex
  cards.wrapped "trigger " & $s.trigger & ", sample interval " & $s.sampleIntervalUs &
    " us (assumed)"
  cards.wrapped "trace 1 reference, 2 reaction-mass force, 3 baseplate force " &
    "(the controller's channels)"
  if opts.externalConverter.isSome:
    let c = opts.externalConverter.get
    cards.wrapped "converter-compatible traces: mean removed, scaled"
    cards.wrapped "reaction-mass weight " & $c.reactionMassWeight & " lb"
    cards.wrapped "baseplate weight " & $c.baseplateWeight & " lb"
    cards.wrapped "hold-down weight " & $c.holdDownWeight & " lb"
    cards.wrapped "k " & $c.k & ", s0 " & $c.s0
    cards.wrapped "trace 4 is hold-down weight x (trace 2 + trace 3): an equal-weight " &
      "sum of accelerations, not a mass-weighted sum"
  else:
    if opts.removeMean or opts.scale != [1.0, 1.0, 1.0]:
      for c in DatChannel:
        cards.wrapped "scale " & $c & " " & $opts.scale[c]
      if opts.removeMean: cards.wrapped "mean removed"
    else:
      cards.wrapped "raw counts"
    if opts.groundForce:
      cards.wrapped "trace 4 controller ground force (estimated): sum of traces 2 and 3"
      cards.wrapped "as recorded: opposite in sign to the reference, which the " &
        "controller reads as 0 degrees"
  if opts.swapForces:
    cards.wrapped "traces 2 and 3 swapped against the file's channel order"
  case positions
  of dpNone: cards.wrapped "no coordinates written"
  of dpGga: discard
  of dpFix: cards.wrapped "coordinates of the position record; no elevation given"
  if not s.complete:
    cards.wrapped "incomplete recording: " & s.incompleteWhy
  cards.wrapped "written by parseSSDAT " & PackageVersion
  if cards.len > MaxCards: cards.setLen(MaxCards)
  if opts.vendorLayout:
    cards = withShotCard(cards)
  cards

proc finish(w: var SeismicWriter) =
  ## Closes the writer; its diagnostics, if any, become an `IOError`.
  var problems: seq[string] = @[]
  for d in w.close():
    problems.add d.msg
  if problems.len > 0:
    raise newException(IOError, problems.join("; "))

proc addShotBlock*(w: var SeismicWriter; s: DatShot; opts = DatWriteOptions()) =
  ## Adds the shot block of `s` to the open SEG-Y writer `w` as the stanza
  ## `parseSSDAT:Shot v1`. Call it for every shot to go into the file, before the first
  ## trace of any (parseSEG takes stanzas only then), and open the writer with a text
  ## header that holds card 37 (`withShotCard`, which `textCards` applies with
  ## `vendorLayout`). `writeSegy` does all of it for one shot. Raises `DatWriteError`.
  checkOptions(s, opts, false)
  translating(s, "SEG-Y"):
    w.addStanza("parseSSDAT", "Shot v1", shotBlock(s, opts))

proc writeSegy*(s: DatShot; path: string; opts = SegyOutputOptions();
    dat = DatWriteOptions()) =
  ## Writes `s` as a SEG-Y file at `path`, replacing a file there: one record, a trace
  ## per channel and the controller's ground force (see `DatWriteOptions`). When
  ## `opts.text` is empty the textual header names the file, the shot and the
  ## channels, and says so for an incomplete recording. With `dat.vendorLayout` the
  ## shot block goes in as a stanza and card 37 names it (a text header of your own
  ## keeps its first 36 cards and gets that card); Rev 0 has no stanzas and is
  ## refused. Raises `DatWriteError`, and `IOError` with the writer's diagnostics when
  ## it reports any.
  checkOptions(s, dat, false)
  if dat.vendorLayout and opts.revision.major < 1:
    fail(s, "the vendor layout needs SEG-Y Rev 1 or later (Rev 0 has no extended " &
      "textual header): choose a later revision or set vendorLayout to false")
  var o = opts
  if o.text.len == 0:
    o.text = textCards(s, dat, writtenPositions(s, dat.positions))
  elif dat.vendorLayout:
    o.text = withShotCard(o.text)
  var w: SeismicWriter
  translating(s, "SEG-Y"):
    w = openSeismicWriter(path, o)
  if dat.vendorLayout:
    w.addShotBlock(s, dat)
  w.writeSegyTraces(s, dat, opts.revision.major >= 2)
  translating(s, "SEG-Y"):
    w.finish()

proc writeSegd*(s: DatShot; path: string; dat = DatWriteOptions()) =
  ## Writes `s` as a SEG-D Rev 3 file at `path`, replacing a file there: one record, a
  ## channel set per channel type, 32-bit float samples, the trigger time as the
  ## recording time. No position is written; with `dat.vendorLayout` the shot block is
  ## the record's external header, and it says whether the recording is complete (SEG-D
  ## has no free text). See `writeSegdTraces`. Raises
  ## `DatWriteError`, and `IOError` with the writer's diagnostics when it reports any.
  checkOptions(s, dat, true)
  var w: SeismicWriter
  translating(s, "SEG-D"):
    w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: s.sampleIntervalUs,
      numSamples: s.len, time: posixTime(s.trigger)))
  w.writeSegdTraces(s, dat)
  translating(s, "SEG-D"):
    w.finish()

proc createExclusively(path: string): bool =
  ## Creates an empty file at `path` unless a file is there, in one step the file
  ## system makes atomic (`O_EXCL`, `CREATE_NEW`): false when `path` exists. Raises
  ## `OSError` for any other failure.
  when defined(windows):
    const alreadyExists = [80'i32, 183] # ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS
    let h = createFileW(newWideCString(path), GENERIC_WRITE, 0, nil, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL, 0)
    result = h != INVALID_HANDLE_VALUE
    if result:
      discard closeHandle(h)
    elif getLastError() notin alreadyExists:
      raiseOSError(osLastError())
  else:
    let fd = posix.open(path.cstring, O_CREAT or O_EXCL or O_WRONLY, Mode(0o644))
    result = fd >= 0
    if result:
      discard posix.close(fd)
    elif errno != EEXIST:
      raiseOSError(osLastError())

proc claimedPath(s: DatInfo; folder, ext: string; overwrite: bool): string =
  ## The output path `folder / datFileStem(s) & ext`, with the folder made. Unless
  ## `overwrite`, the path is claimed by creating an empty file there, exclusively: of
  ## several writers after one name exactly one gets it, the others `DatWriteError`.
  ## (The winner's finished file replaces the empty one.)
  result = folder / (datFileStem(s) & ext)
  try:
    createDir(folder)
    if not overwrite and not createExclusively(result):
      fail(s, "the output file " & result & " exists and is not overwritten")
  except OSError as e:
    raise newException(IOError, "cannot create " & result & ": " & e.msg)

template writeClaimed(s: DatInfo; path: string; overwrite: bool; body: untyped) =
  ## Runs `body`, which writes `path`; a failure removes the empty file claimed for it.
  try:
    body
  except CatchableError:
    if not overwrite:
      try:
        removeFile(path)
      except OSError:
        discard # the first failure is the one to report
    raise

proc writeSegyTo*(s: DatShot; folder: string; opts = SegyOutputOptions();
    dat = DatWriteOptions(); overwrite = false): string =
  ## `writeSegy` into `folder` (made when missing) under the name `datFileStem(s)` and
  ## `.sgy`; returns the path. An existing file raises `DatWriteError` unless
  ## `overwrite`: the name is claimed exclusively (see `claimedPath`), so two writers
  ## after the same name cannot both succeed. While the file is being written an empty
  ## file stands at the name. A folder that cannot be made is an `IOError`.
  checkOptions(s, dat, false)
  result = claimedPath(s, folder, ".sgy", overwrite)
  writeClaimed(s, result, overwrite):
    s.writeSegy(result, opts, dat)

proc writeSegdTo*(s: DatShot; folder: string; dat = DatWriteOptions();
    overwrite = false): string =
  ## `writeSegd` into `folder` (made when missing) under the name `datFileStem(s)` and
  ## `.sgd`; returns the path. As `writeSegyTo`.
  checkOptions(s, dat, true)
  result = claimedPath(s, folder, ".sgd", overwrite)
  writeClaimed(s, result, overwrite):
    s.writeSegd(result, dat)
