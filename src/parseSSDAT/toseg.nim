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
## **Errors.** A value the format cannot hold or an option that makes no sense raises
## `DatWriteError` with plain words that name the value: a source index above 255, a
## file number above 16777215, or a line without a station, in SEG-D; a weight that is
## not above 0; an interval that is not a whole number of microseconds for SEG-D; an
## existing file in the folder forms. Whatever else parseSEG refuses for a shot (a
## station too wide for SEG-D, say) is translated into the same error, with parseSEG's
## words after the shot's file number. Problems with the file system, and diagnostics
## the writer reports when it closes, are `IOError`.

import std/[math, options, os, strutils]
import parseSEG
import ./[decode, types]

const
  PackageVersion = "0.1.0"
  CodeGroundForce = 20'i16 ## SEG-Y trace code of the controller's ground force
  CardWidth = 76           ## parseSEG puts "C nn " before each textual header card of 80
  MaxSegdSourceIndex = 255
  MaxSegdFileNumber = 16_777_215

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

proc fail(s: DatInfo; what: string) {.noinline, noreturn.} =
  raise newException(DatWriteError, "file number " & $s.fileNumber & ": " & what)

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
    extHeader = true) =
  ## Appends the traces of `s` to the open SEG-Y writer `w`: one record, numbered by
  ## the file number. `extHeader` says the file is Rev 2 or later, where the trigger
  ## time's nanoseconds go exactly into Trace Header Extension 1; in Rev 1 and Rev 0
  ## the time is kept to the second the format has room for (the fraction goes with it
  ## where the writer keeps one). The controller's vibrator ID goes into the trace
  ## header's device trace identifier when the file has a QC record and the ID fits
  ## 16 bits. Raises `DatWriteError` (see the module's text).
  checkOptions(s, opts, false)
  var overrides: seq[HeaderOverride] = @[]
  if opts.positions != dpNone:
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
  ## resolution of SEG-D's timestamps. Raises `DatWriteError` (see the module's text).
  checkOptions(s, opts, true)
  for t in outTraces(s, opts, true, false):
    translating(s, "SEG-D"):
      w.writeTrace(t.keys, t.samples, [], t.channelType)

func wrapped(cards: var seq[string]; text: string) =
  ## Adds `text` as cards of at most `CardWidth` characters, broken at spaces.
  var rest = text
  while rest.len > CardWidth:
    var at = rest.rfind(' ', 0, CardWidth)
    if at <= 0: at = CardWidth
    cards.add rest[0 ..< at]
    rest = "  " & rest[at .. ^1].strip(trailing = false)
  cards.add rest

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
  if opts.swapForces:
    cards.wrapped "traces 2 and 3 swapped against the file's channel order"
  case positions
  of dpNone: cards.wrapped "no coordinates written"
  of dpGga: discard
  of dpFix: cards.wrapped "coordinates of the position record; no elevation given"
  if not s.complete:
    cards.wrapped "incomplete recording: " & s.incompleteWhy
  cards.wrapped "written by parseSSDAT " & PackageVersion
  cards

proc finish(w: var SeismicWriter) =
  ## Closes the writer; its diagnostics, if any, become an `IOError`.
  var problems: seq[string] = @[]
  for d in w.close():
    problems.add d.msg
  if problems.len > 0:
    raise newException(IOError, problems.join("; "))

proc writeSegy*(s: DatShot; path: string; opts = SegyOutputOptions();
    dat = DatWriteOptions()) =
  ## Writes `s` as a SEG-Y file at `path`, replacing a file there: one record, a trace
  ## per channel and the controller's ground force (see `DatWriteOptions`). When
  ## `opts.text` is empty the textual header names the file, the shot and the
  ## channels, and says so for an incomplete recording. Raises `DatWriteError`, and
  ## `IOError` with the writer's diagnostics when it reports any.
  checkOptions(s, dat, false)
  var o = opts
  if o.text.len == 0:
    o.text = textCards(s, dat, dat.positions)
  var w: SeismicWriter
  translating(s, "SEG-Y"):
    w = openSeismicWriter(path, o)
  w.writeSegyTraces(s, dat, opts.revision.major >= 2)
  translating(s, "SEG-Y"):
    w.finish()

proc writeSegd*(s: DatShot; path: string; dat = DatWriteOptions()) =
  ## Writes `s` as a SEG-D Rev 3 file at `path`, replacing a file there: one record, a
  ## channel set per channel type, 32-bit float samples, the trigger time as the
  ## recording time. No position is written and an incomplete recording is not flagged
  ## in the file (SEG-D has no free text): see `writeSegdTraces`. Raises
  ## `DatWriteError`, and `IOError` with the writer's diagnostics when it reports any.
  checkOptions(s, dat, true)
  var w: SeismicWriter
  translating(s, "SEG-D"):
    w = openSeismicWriter(path, SegdOutputOptions(sampleIntervalUs: s.sampleIntervalUs,
      numSamples: s.len, time: posixTime(s.trigger)))
  w.writeSegdTraces(s, dat)
  translating(s, "SEG-D"):
    w.finish()

proc outputPath(s: DatInfo; folder, ext: string; overwrite: bool): string =
  result = folder / (datFileStem(s) & ext)
  if not overwrite and fileExists(result):
    fail(s, "the output file " & result & " exists and is not overwritten")

proc writeSegyTo*(s: DatShot; folder: string; opts = SegyOutputOptions();
    dat = DatWriteOptions(); overwrite = false): string =
  ## `writeSegy` into `folder` (made when missing) under the name `datFileStem(s)` and
  ## `.sgy`; returns the path. An existing file raises `DatWriteError` unless
  ## `overwrite`.
  result = outputPath(s, folder, ".sgy", overwrite)
  createDir(folder)
  s.writeSegy(result, opts, dat)

proc writeSegdTo*(s: DatShot; folder: string; dat = DatWriteOptions();
    overwrite = false): string =
  ## `writeSegd` into `folder` (made when missing) under the name `datFileStem(s)` and
  ## `.sgd`; returns the path. An existing file raises `DatWriteError` unless
  ## `overwrite`.
  result = outputPath(s, folder, ".sgd", overwrite)
  createDir(folder)
  s.writeSegd(result, dat)
