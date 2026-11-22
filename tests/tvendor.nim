## The shot block (`vendorLayout`): written into SEG-Y and SEG-D files, read back through
## parseSEG with the maps of `vendormaps/` applied. Every field of the block equals the
## value of the shot, the QC record and the three raw records are in it byte for byte,
## and a file written without the layout has none of it.
##
## Seen to fail: with the block's QC record put at byte 255 instead of 257, `fields`
## fails; with card 37 left out of the text header, `segy` finds no block; with the
## external header passed to no trace, `segd` finds no block; with the two maps
## differing in one field line, `mapsAgree` fails; with `(byteOrder big)` taken off the
## maps' multi-byte fields, `littleEndianSegy` (and `mapsAgree`) fail: a little-endian
## SEG-Y decoded layoutVersion 256.

import std/[math, os, strutils, tables]
import parseSEG
import parseSSDAT
import datsynth

const MapDir = currentSourcePath().parentDir.parentDir / "vendormaps"

proc registry(): VendorRegistry =
  var log: DiagLog
  result.loadVendorMaps([MapDir / "parseSSDAT-segy-1.nif", MapDir / "parseSSDAT-segd-1.nif"],
    log)
  doAssert log.len == 0, $log

proc byName(b: VendorBlock): Table[string, VendorValue] =
  for f in b.fields:
    result[f.name] = f.value

proc stanzaBlocks(f: SeismicFile): seq[seq[byte]] =
  ## The bytes of every binary stanza of the extended textual header.
  let ext = f.index.segy.extended
  for st in ext.stanzas:
    if st.isBinary and not st.isUserData:
      result.add ext.data[st.dataStart ..< st.dataStart + st.byteCount]

proc blocksOf(f: SeismicFile; reg: VendorRegistry): seq[VendorBlock] =
  var log: DiagLog
  if f.kind == skSegy:
    result = reg.decodeVendorAreas(f.index.segy, log)
  else:
    for rec in f.index.segdRecords:
      result.add reg.decodeVendorAreas(rec, log)
  doAssert log.count(sevWarning) == 0 and log.count(sevError) == 0, $log

proc rawBlocks(f: SeismicFile): seq[seq[byte]] =
  if f.kind == skSegy:
    result = stanzaBlocks(f)
  else:
    for rec in f.index.segdRecords:
      result.add rec.external

proc near(a, b: float64): bool =
  abs(a - b) <= 1e-9 * max(1.0, abs(b))

proc checkFields(v: Table[string, VendorValue]; s: DatShot; opts: DatWriteOptions;
    positions: DatPositions) =
  ## Every field of the shot block against the shot, by name.
  proc int0(name: string; want: SomeInteger) =
    ## A field with a sentinel 0: absent when the value is 0.
    if want == 0: doAssert name notin v, name
    else: doAssert name in v and v[name].intVal == int64(want), name & " " & $want
  proc intF(name: string; want: SomeInteger) =
    doAssert name in v and v[name].intVal == int64(want), name & " " & $want & " " &
      (if name in v: $v[name].intVal else: "missing")
  proc floatF(name: string; want: float64) =
    doAssert name in v and near(v[name].floatVal, want), name & " " & $want & " " &
      (if name in v: $v[name].floatVal else: "missing")
  doAssert v["magic"].text == "SSDATSHT"
  # the header record's GNSS text, up to the NUL that ends it
  doAssert v["gnssText"].text.split('\0')[0] == s.headerText
  intF "layoutVersion", 1
  intF "blockBytes", 2048
  intF "unitSerial", s.controllerSerial
  intF "fileNumber", s.fileNumber
  intF "firmwareMajor", s.firmware.major
  intF "firmwareMinor", s.firmware.minor
  intF "complete", ord(s.complete)
  doAssert v["complete"].label == (if s.complete: "complete" else: "incomplete")
  intF "channels", 3
  intF "samples", s.len
  intF "declaredSamples", s.declaredSamples
  floatF "sampleIntervalUs", s.sampleIntervalUs
  intF "triggerYear", s.trigger.year
  intF "triggerMonth", s.trigger.month
  intF "triggerDay", s.trigger.day
  intF "triggerHour", s.trigger.hour
  intF "triggerMinute", s.trigger.minute
  intF "triggerSecond", s.trigger.second
  intF "triggerNanosecond", s.trigger.nanosecond
  int0 "sourceLine", s.sourceLine
  int0 "sourceStation", s.sourceStation
  int0 "shotId", s.shotId
  int0 "sourceIndex", s.sourceIndex
  intF "trailerCounter", s.trailerCounter
  intF "sweepId", s.sweepId
  if s.gga.valid:
    floatF "ggaLatitude", s.gga.latitudeDeg
    floatF "ggaLongitude", s.gga.longitudeDeg
    floatF "ggaAltitude", s.gga.altitudeM
    floatF "ggaGeoidSeparation", s.gga.geoidSeparationM
    doAssert abs(v["ggaHdop"].floatVal - s.gga.hdop) < 1e-6
    intF "ggaFixQuality", s.gga.fixQuality
    intF "ggaSatellites", s.gga.satellites
  else:
    doAssert v["ggaLatitude"].floatVal.isNaN and v["ggaLongitude"].floatVal.isNaN
  intF "ggaValid", ord(s.gga.valid)
  floatF "fixLatitude", s.fix.latitudeDeg
  floatF "fixLongitude", s.fix.longitudeDeg
  floatF "fixHeight", float64(s.fix.heightDm) * 0.1
  intF "fixQuality", s.fix.fixQuality
  intF "fixSatellites", s.fix.satellites
  floatF "fixHdop", float64(int(round(s.fix.hdop * 10))) * 0.1
  # a float field is not dropped by a sentinel: 0 when none was given
  floatF "lbfPerCount", opts.lbfPerCount
  floatF "scaleReference", opts.scale[dcReference]
  floatF "scaleMass", opts.scale[dcMass]
  floatF "scaleBaseplate", opts.scale[dcBaseplate]
  intF "meanRemoved", ord(opts.removeMean)
  intF "groundForceTrace", ord(opts.groundForce)
  intF "groundForcePolarity", 0
  doAssert v["groundForcePolarity"].label.startsWith("as recorded")
  intF "positions", ord(positions)
  # the words fit 76 bytes or are cut there
  doAssert v["incompleteWhy"].text == s.incompleteWhy[0 ..< min(76, s.incompleteWhy.len)]
  # the QC record
  let q = s.qc
  if q.valid:
    intF "qcCrew", q.crew
    intF "qcVibratorId", q.vibratorId
    intF "qcMessageType", q.raw[8]
    intF "qcSweepId", q.sweepId
    intF "qcSweepNumber", q.sweepNumber
    floatF "qcPhaseMax", q.phaseMaxDeg
    intF "qcForceMax", q.forceMaxPct
    intF "qcForceMin", q.forceMinPct
    intF "qcForceAvg", q.forceAvgPct
    intF "qcThdMax", q.thdMaxPct
    intF "qcThdAvg", q.thdAvgPct
    intF "qcSweepChecksum", q.sweepChecksum
    intF "qcParamChecksum", q.paramChecksum
    for i in 0 .. 2:
      intF "qcStatus" & $(i + 1), q.statusFlags[i]
    var flags: seq[string] = @[]
    for l in DatLimit:
      if l in q.limits: flags.add $l
    doAssert v["qcLimits"].intVal == q.statusFlags[3].int and v["qcLimits"].flags == flags,
      $v["qcLimits"].flags & " " & $flags
    intF "qcCorrelationMagnitude", q.correlationMagnitude
    for i in 0 ..< 128:
      let want = if q.correlation.len == 128: int64(q.correlation[i]) else: int64(
        cast[int8](q.raw[38 + i]))
      intF "corr[" & $i & "]", want
    intF "qcYear2", q.trigger.year - 2000
    intF "qcMonth", q.trigger.month
    intF "qcDay", q.trigger.day
    intF "qcHour", q.trigger.hour
    intF "qcMinute", q.trigger.minute
    intF "qcSecond", q.trigger.second
    intF "qcNanosecond", q.trigger.nanosecond
    floatF "qcHeightAboveEllipsoid", float64(q.heightCm) * 0.01
    intF "qcSatellites", q.satellites
    floatF "qcPdop", q.pdop
    floatF "qcHdop", q.hdop
    floatF "qcVdop", q.vdop
    intF "qcCorrectionAge", q.correctionAgeS
    intF "qcSignatureFileCounter", int64(q.raw[197]) shl 24 or int64(q.raw[198]) shl 16 or
      int64(q.raw[199]) shl 8 or int64(q.raw[200])
    intF "qcFlashFree", q.raw[201]
    intF "qcStiffnessMax", q.stiffness.max
    intF "qcStiffnessMin", q.stiffness.min
    intF "qcStiffnessAvg", q.stiffness.avg
    intF "qcViscosityMax", q.viscosity.max
    intF "qcViscosityMin", q.viscosity.min
    intF "qcViscosityAvg", q.viscosity.avg
    intF "qcTargetForce", q.targetForceLbf
    intF "qcShotId", q.shotId
    intF "qcSourceLine", q.sourceLine
    intF "qcSourceStation", q.sourceStation

proc checkRaw(b: seq[byte]; s: DatShot) =
  ## The raw parts of the block: the QC record and the three records, byte for byte.
  doAssert b.len == 2048 and b[0 ..< 8] == @[byte 0x53, 0x53, 0x44, 0x41, 0x54, 0x53,
    0x48, 0x54]
  if s.qc.valid: doAssert b[256 ..< 496] == s.qc.raw
  else: doAssert b[256 ..< 496] == newSeq[byte](240)
  doAssert b[512 ..< 1024] == s.records[0].bytes # header: start, GNSS text, end
  doAssert b[1024 ..< 1536] == s.records[1].bytes
  if s.records.len > 2: doAssert b[1536 ..< 2048] == s.records[2].bytes
  else: doAssert b[1536 ..< 2048] == newSeq[byte](512)
  var unused = @[47, 115]
  for i in 137 .. 143:
    unused.add i
  for i in 496 .. 511:
    unused.add i
  for i in unused:
    doAssert b[i] == 0, "unused byte " & $i

proc readBack(f: SeismicFile; n: int): seq[seq[float32]] =
  var log: DiagLog
  let x = f.readTraces(0 ..< n, log)
  for i in 0 ..< n:
    result.add newSeq[float32](x.shape[1])
    for j in 0 ..< x.shape[1]:
      result[i][j] = x[i, j]

proc main*() =
  let dir = getTempDir() / ("ssdat-tvendor-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let reg = registry()
  let synth = SynthDat(samples: 300, line: 11, station: 12, index: 3, shotId: 5, sweepId: 6,
    counter: 77, vibrator: 21, crew: 4, sweepNumber: 2,
    corr: (var c = newSeq[int8](128); (for i in 0 ..< 128: c[i] = int8(i - 64)); c))
  let s = parseDat(synthDat(synth))

  block mapsAgree:
    ## The two maps hold the same field lines, and both load and check clean.
    var lines: array[2, seq[string]]
    for i, name in ["parseSSDAT-segy-1.nif", "parseSSDAT-segd-1.nif"]:
      let text = readFile(MapDir / name)
      var inTarget = false
      for line in text.splitLines:
        if line.strip.startsWith("(target"): inTarget = true
        elif inTarget: lines[i].add line
      let m = loadVendorMap(text, name)
      doAssert checkVendorMap(m).len == 0, $checkVendorMap(m)
      doAssert m.name == name.changeFileExt("")
      doAssert "(version 2)" in text
      # the block is big-endian whatever the file's order: every multi-byte field says so
      for line in text.splitLines:
        for enc in ["u16", "i16", "u32", "f32", "f64"]:
          if ("(enc " & enc & ")") in line:
            doAssert "(byteOrder big)" in line, line
      # every field lies inside the 2048-byte block
      var widest = 0
      for line in lines[i]:
        let at = line.find("(at ")
        if "(field" in line and at >= 0:
          let start = parseInt(line[at + 4 ..< line.find(')', at)])
          var width = 0
          for (enc, w) in [("u8", 1), ("i8", 1), ("u16", 2), ("i16", 2), ("u32", 4),
              ("f32", 4), ("f64", 8)]:
            if ("(enc " & enc & ")") in line: width = w
          let lenAt = line.find("(len ")
          if lenAt >= 0: width = parseInt(line[lenAt + 5 ..< line.find(')', lenAt)])
          if "(repeat" notin line: widest = max(widest, start - 1 + width)
      doAssert widest <= 2048 and widest > 1500, $widest
    doAssert lines[0] == lines[1] and lines[0].len > 90
    doAssert "(kind stanza)" in readFile(MapDir / "parseSSDAT-segy-1.nif")
    doAssert "(kind externalHeader)" in readFile(MapDir / "parseSSDAT-segd-1.nif")

  block shotBlockBytes:
    let opts = DatWriteOptions(lbfPerCount: 0.125)
    let b = shotBlock(s, opts)
    doAssert b.len == ShotBlockBytes and ShotBlockBytes == 2048
    checkRaw(b, s)
    doAssert shotBlock(s, opts) == b # deterministic
    doAssert shotBlock(s, DatWriteOptions(removeMean: true)) != b

  block segy:
    for (major, minor) in [(2, 1), (2, 0), (1, 0)]:
      let p = dir / "a.sgy"
      let opts = DatWriteOptions(lbfPerCount: 0.125, scale: [1.0, 0.5, 2.0], removeMean: true,
        positions: dpFix)
      s.writeSegy(p, SegyOutputOptions(revision: SegyRevision(major: uint8(major),
        minor: uint8(minor))), opts)
      var f = openSeismic(p, keys = true)
      doAssert not f.log.isFatal, $f.log
      doAssert ShotCardText in f.textHeader and "C37 PARSESSDAT SHOT STANZAS" in
        f.textHeader.replace("C 37", "C37").replace("C37 ", "C37 "), f.textHeader
      let blocks = f.blocksOf(reg)
      doAssert blocks.len == 1 and blocks[0].name == "parseSSDATShot" and
        blocks[0].mapName == "parseSSDAT-segy-1", $blocks.len
      checkFields(byName(blocks[0]), s, opts, dpFix)
      let raw = f.rawBlocks
      doAssert raw.len == 1
      checkRaw(raw[0], s)
      doAssert raw[0] == shotBlock(s, opts)
      # the traces: as recorded, and the block's file number is their record number
      doAssert f.len == 4 and f.traceKeys(0).record == float64(s.fileNumber)
      f.close()
    # the first stanza is found whichever way the file is opened (bytes in memory too)
    var w = openSeismicWriterBytes(SegyOutputOptions(text: textCards(s, DatWriteOptions())))
    w.addShotBlock(s)
    w.writeSegyTraces(s)
    let bytes = w.finishBytes()
    let m = openSeismicBytes(bytes, "m.sgy", keys = true)
    doAssert m.blocksOf(reg).len == 1 and m.rawBlocks[0] == shotBlock(s, DatWriteOptions())

  block littleEndianSegy:
    ## The block is big-endian whatever the file's byte order: a little-endian SEG-Y
    ## decodes through the map exactly as the big-endian one.
    let opts = DatWriteOptions(lbfPerCount: 0.125, scale: [1.0, 0.5, 2.0], positions: dpFix)
    var decoded: array[2, Table[string, VendorValue]]
    for i, order in [boBig, boLittle]:
      let p = dir / "o.sgy"
      s.writeSegy(p, SegyOutputOptions(byteOrder: order), opts)
      var f = openSeismic(p, keys = true)
      doAssert not f.log.isFatal, $f.log
      let blocks = f.blocksOf(reg)
      doAssert blocks.len == 1, $blocks.len
      decoded[i] = byName(blocks[0])
      checkFields(decoded[i], s, opts, dpFix)
      checkRaw(f.rawBlocks[0], s)
      doAssert f.rawBlocks[0] == shotBlock(s, opts)
      f.close()
    doAssert decoded[0].len == decoded[1].len and decoded[0].len > 90
    for name, v in decoded[0]:
      doAssert name in decoded[1] and $decoded[1][name] == $v, name

  block fields:
    ## Every field, with the default options and with positions of the GGA sentence.
    for (positions, mean) in [(dpGga, false), (dpNone, true), (dpFix, false)]:
      let opts = DatWriteOptions(positions: positions, removeMean: mean)
      let b = shotBlock(s, opts)
      doAssert b[179] == byte(ord(positions))
    let noQc = parseDat(synthDat(SynthDat(samples: 100, noQc: true, text: "no gga here")))
    s.writeSegy(dir / "q.sgy")
    noQc.writeSegy(dir / "n.sgy")
    var f = openSeismic(dir / "n.sgy", keys = true)
    let bl = f.blocksOf(reg)
    doAssert bl.len == 1
    let v = byName(bl[0])
    checkFields(v, noQc, DatWriteOptions(), dpNone) # no GGA: none written
    doAssert v["ggaLatitude"].floatVal.isNaN and v["ggaValid"].intVal == 0
    checkRaw(f.rawBlocks[0], noQc)
    f.close()

  block segd:
    let p = dir / "a.sgd"
    let opts = DatWriteOptions(lbfPerCount: 0.125, scale: [1.0, 0.5, 2.0], positions: dpGga)
    s.writeSegd(p, opts)
    var f = openSeismic(p, keys = true)
    doAssert f.kind == skSegd and f.len == 4 and not f.log.isFatal, $f.log
    let blocks = f.blocksOf(reg)
    doAssert blocks.len == 1 and blocks[0].name == "parseSSDATShot" and
      blocks[0].mapName == "parseSSDAT-segd-1", $blocks.len
    var o2 = opts
    o2.positions = dpNone # SEG-D writes none, and the block says so
    checkFields(byName(blocks[0]), s, o2, dpNone)
    checkRaw(f.rawBlocks[0], s)
    doAssert f.rawBlocks[0] == shotBlock(s, o2)
    doAssert f.index.segdRecords[0].externalHeaderBlocks == 64
    f.close()

  block incomplete:
    let part = parseDat(synthDat(SynthDat(samples: 200, truncateAfter: 4)),
      allowIncomplete = true)
    for segd in [false, true]:
      let p = dir / (if segd: "i.sgd" else: "i.sgy")
      if segd: part.writeSegd(p) else: part.writeSegy(p)
      var f = openSeismic(p, keys = true)
      let bl = f.blocksOf(reg)
      doAssert bl.len == 1
      let v = byName(bl[0])
      doAssert v["complete"].label == "incomplete" and v["complete"].intVal == 0
      doAssert part.incompleteWhy.len > 76 and v["incompleteWhy"].text.len == 76 and
        part.incompleteWhy.startsWith(v["incompleteWhy"].text) and
        "4 of the 7 blocks" in v["incompleteWhy"].text
      doAssert "sourceLine" notin v and "shotId" notin v and v["trailerCounter"].intVal == 0
      checkFields(v, part, DatWriteOptions(), if segd: dpNone else: dpGga)
      checkRaw(f.rawBlocks[0], part)
      doAssert f.rawBlocks[0][1536 ..< 2048] == newSeq[byte](512) # no trailer
      f.close()

  block severalShots:
    ## One block per shot, each with the record number of its traces.
    var shots: seq[DatShot] = @[]
    for i in 0 ..< 3:
      shots.add parseDat(synthDat(SynthDat(samples: 100, fileNumber: 7001 + i,
        sweepId: int64(i + 1), vibrator: 10 + i, shotId: int64(100 + i))))
    let opts = DatWriteOptions()
    var w = openSeismicWriter(dir / "m.sgy", SegyOutputOptions(
      text: withShotCard(textCards(shots[0], opts))))
    for sh in shots:
      w.addShotBlock(sh, opts)
    for sh in shots:
      w.writeSegyTraces(sh, opts)
    doAssert w.close().len == 0
    var f = openSeismic(dir / "m.sgy", keys = true)
    var bl = f.blocksOf(reg)
    doAssert bl.len == 3 and f.len == 12
    for i in 0 ..< 3:
      doAssert byName(bl[i])["fileNumber"].intVal == 7001 + i
      doAssert byName(bl[i])["qcVibratorId"].intVal == 10 + i
      for c in 0 ..< 4:
        doAssert f.traceKeys(4 * i + c).record == float64(7001 + i)
      checkRaw(f.rawBlocks[i], shots[i])
    f.close()
    var d = openSeismicWriter(dir / "m.sgd", SegdOutputOptions(sampleIntervalUs: 1000,
      numSamples: 100))
    for sh in shots:
      d.writeSegdTraces(sh, opts)
    doAssert d.close().len == 0
    f = openSeismic(dir / "m.sgd", keys = true)
    bl = f.blocksOf(reg)
    doAssert bl.len == 3 and f.len == 12
    for i in 0 ..< 3:
      doAssert byName(bl[i])["fileNumber"].intVal == 7001 + i
      for c in 0 ..< 4:
        doAssert f.traceKeys(4 * i + c).record == float64(7001 + i)
    f.close()

  block plainFiles:
    ## `vendorLayout = false`: no block, no card, no diagnostic from the maps, and the
    ## same traces and standard headers as the file with the layout.
    let plain = DatWriteOptions(vendorLayout: false)
    s.writeSegy(dir / "p.sgy", dat = plain)
    s.writeSegy(dir / "v.sgy")
    var p = openSeismic(dir / "p.sgy", keys = true)
    var v = openSeismic(dir / "v.sgy", keys = true)
    doAssert p.blocksOf(reg).len == 0 and p.rawBlocks.len == 0
    doAssert ShotCardText notin p.textHeader and "parseSSDAT" in p.textHeader
    doAssert v.len == p.len
    doAssert p.readBack(4) == v.readBack(4)
    for i in 0 ..< p.len:
      doAssert $p.traceKeys(i) == $v.traceKeys(i) # NaN fields: compare as text
      doAssert p.traceHeaders(i).len == v.traceHeaders(i).len
    # the trace records are byte for byte the same: the tails of the two files
    let a = readFile(dir / "p.sgy")
    let b = readFile(dir / "v.sgy")
    let tail = 4 * (240 + 300 * 4) + 3200 * 0
    doAssert a[a.len - tail ..< a.len] == b[b.len - tail ..< b.len]
    doAssert b.len > a.len # the stanza
    p.close()
    v.close()
    s.writeSegd(dir / "p.sgd", plain)
    s.writeSegd(dir / "v.sgd")
    p = openSeismic(dir / "p.sgd", keys = true)
    v = openSeismic(dir / "v.sgd", keys = true)
    doAssert p.blocksOf(reg).len == 0 and p.index.segdRecords[0].externalHeaderBlocks == 0
    doAssert p.readBack(4) == v.readBack(4)
    for i in 0 ..< p.len:
      doAssert $p.traceKeys(i) == $v.traceKeys(i) # NaN fields: compare as text
    p.close()
    v.close()
    # a file with the layout is not claimed by the maps once the card is gone
    var cards = textCards(s, DatWriteOptions(vendorLayout: false))
    s.writeSegy(dir / "t.sgy", SegyOutputOptions(text: cards), DatWriteOptions(vendorLayout: false))
    # (no card 37 in a user's text header without the layout: no block is decoded)
    var plainFile = openSeismic(dir / "t.sgy")
    doAssert plainFile.blocksOf(reg).len == 0
    plainFile.close()

  block blockLimits:
    ## A shot that does not fit the block is refused in words, never wrapped or
    ## overwritten; with the layout off it is written.
    proc refused(sh: DatShot; words: openArray[string]; dat = DatWriteOptions()) =
      for segd in [false, true]:
        let p = dir / "limit.out"
        try:
          if segd: sh.writeSegd(p, dat) else: sh.writeSegy(p, dat = dat)
          doAssert false, "was written: " & $words
        except DatWriteError as e:
          for w in words:
            doAssert w in e.msg, w & " not in " & e.msg
        doAssert not fileExists(p)
    for (name, tweak) in [("controller serial", proc (x: var DatShot) = x.controllerSerial = -1),
        ("file number", proc (x: var DatShot) = x.fileNumber = 1'i64 shl 40),
        ("source line", proc (x: var DatShot) = x.sourceLine = 4_294_967_296'i64),
        ("source station", proc (x: var DatShot) = x.sourceStation = -5),
        ("shot id", proc (x: var DatShot) = x.shotId = 1'i64 shl 33),
        ("sweep id", proc (x: var DatShot) = x.sweepId = -1),
        ("source index", proc (x: var DatShot) = x.sourceIndex = 1'i64 shl 32),
        ("trailer counter", proc (x: var DatShot) = x.trailerCounter = -2)]:
      var sh = s
      tweak(sh)
      refused(sh, [name, "32 bits", "vendorLayout"])
      var plain = sh # the same shot without the layout: only SEG-Y can hold some values
      plain.sourceIndex = min(plain.sourceIndex, 3)
      if name in ["trailer counter", "sweep id", "shot id"]:
        plain.writeSegy(dir / "plain.sgy", dat = DatWriteOptions(vendorLayout: false))
    var odd = s
    odd.trigger = DatTime(year: 70000, month: 300, day: 1, hour: 99999, minute: 0, second: 0,
      nanosecond: 1_000_000_000)
    refused(odd, ["trigger time", "shot block"])
    # the QC record and the raw records have their sizes
    for n in [1, 239, 241, 300, 1792, 1793, 100000]:
      var sh = s
      sh.qc.raw = newSeq[byte](n)
      refused(sh, ["QC record", $n & " bytes", "not 240"])
    var short = s
    short.records[0].bytes.setLen(511)
    refused(short, ["raw record", "511 bytes", "not 512"])
    var long = s
    long.records[2].bytes.setLen(513)
    refused(long, ["raw record", "513 bytes"])
    var empty = s
    empty.qc.raw.setLen(0) # no QC record is fine
    empty.qc.valid = false
    empty.writeSegy(dir / "e.sgy")
    refused(s, ["pound-force per count", "-1.0"], DatWriteOptions(lbfPerCount: -1.0))
    refused(s, ["pound-force per count", "nan"], DatWriteOptions(lbfPerCount: NaN))
    refused(s, ["pound-force per count", "inf"], DatWriteOptions(lbfPerCount: Inf))
    doAssertRaises(DatWriteError):
      s.writeSegy(dir / "neg.sgy", dat = DatWriteOptions(lbfPerCount: -0.5, vendorLayout: false))
    # a record that is the wrong size is not looked at when the layout is off
    short.writeSegy(dir / "s.sgy", dat = DatWriteOptions(vendorLayout: false))

  block positionsWritten:
    ## The positions byte and the text say what was written: none, for a GGA position
    ## asked of a shot without a valid sentence or a fix asked of one without a fix.
    let noGga = parseDat(synthDat(SynthDat(samples: 60, text: "no gga here")))
    var noFix = parseDat(synthDat(SynthDat(samples: 60)))
    noFix.fix.latitudeDeg = NaN
    doAssert writtenPositions(noGga, dpGga) == dpNone and writtenPositions(s, dpGga) == dpGga
    doAssert writtenPositions(noFix, dpFix) == dpNone and writtenPositions(noFix, dpGga) == dpGga
    doAssert writtenPositions(noGga, dpFix) == dpFix and writtenPositions(s, dpNone) == dpNone
    doAssert shotBlock(noGga, DatWriteOptions(positions: dpGga))[179] == 0
    doAssert shotBlock(noFix, DatWriteOptions(positions: dpFix))[179] == 0
    doAssert shotBlock(s, DatWriteOptions(positions: dpGga))[179] == 1
    doAssert shotBlock(s, DatWriteOptions(positions: dpFix))[179] == 2
    noGga.writeSegy(dir / "ng.sgy")
    var f = openSeismic(dir / "ng.sgy", keys = true)
    doAssert "no coordinates written" in f.textHeader and f.traceKeys(0).srcX.isNaN
    doAssert f.blocksOf(reg)[0].byName["positions"].intVal == 0
    f.close()
    noFix.writeSegy(dir / "nf.sgy", dat = DatWriteOptions(positions: dpFix))
    f = openSeismic(dir / "nf.sgy", keys = true)
    doAssert "no coordinates written" in f.textHeader
    doAssert f.blocksOf(reg)[0].byName["positions"].intVal == 0
    f.close()

  block incompleteWordsCut:
    ## The reason is cut at the last space within 76 characters, not in a word.
    var sh = s
    sh.complete = false
    sh.incompleteWhy = "the file holds 50 of the 226 blocks its header announces: the " &
      "recording stopped or the copy was cut short"
    let b = shotBlock(sh, DatWriteOptions())
    let text = cast[string](b[180 ..< 256]).strip(leading = false)
    doAssert text == "the file holds 50 of the 226 blocks its header announces: the recording",
      text
    doAssert text.len <= 76 and sh.incompleteWhy.startsWith(text)
    sh.incompleteWhy = "x".repeat(200) # no space: cut at 76
    doAssert cast[string](shotBlock(sh, DatWriteOptions())[180 ..< 256]) == "x".repeat(76)
    sh.incompleteWhy = "short words"
    doAssert cast[string](shotBlock(sh, DatWriteOptions())[180 ..< 256]).strip(
      leading = false) == "short words"

  block shotBlockLimits:
    ## `shotBlock` called on its own refuses what does not fit, in words, instead of
    ## writing a wrapped or cut number.
    proc refusedBlock(name: string; tweak: proc (x: var DatShot)) =
      var sh = s
      tweak(sh)
      try:
        discard shotBlock(sh, DatWriteOptions())
        doAssert false, name & ": a block was written"
      except DatWriteError as e:
        doAssert "does not fit" in e.msg or "bytes" in e.msg, e.msg
    refusedBlock("negative", proc (x: var DatShot) = x.fileNumber = -1)
    refusedBlock("40 bits", proc (x: var DatShot) = x.fileNumber = 1'i64 shl 40)
    refusedBlock("serial", proc (x: var DatShot) = x.controllerSerial = -3)
    refusedBlock("year", proc (x: var DatShot) = x.trigger.year = 70000)
    refusedBlock("month", proc (x: var DatShot) = x.trigger.month = -1)
    refusedBlock("height", proc (x: var DatShot) = x.fix.heightDm = 40000)
    refusedBlock("fix satellites", proc (x: var DatShot) = x.fix.satellites = 300)
    refusedBlock("fix hdop", proc (x: var DatShot) = x.fix.hdop = 30.0)
    refusedBlock("qc length", proc (x: var DatShot) = x.qc.raw.add 0'u8)
    refusedBlock("record length", proc (x: var DatShot) = x.records[0].bytes.add 0'u8)
    # the words name the value
    var sh = s
    sh.fileNumber = 1'i64 shl 40
    try:
      discard shotBlock(sh, DatWriteOptions())
    except DatWriteError as e:
      doAssert "file number" in e.msg and "32 bits" in e.msg, e.msg
    # a shot that fits is written as before
    doAssert shotBlock(s, DatWriteOptions()).len == ShotBlockBytes

  block refusals:
    ## Rev 0 has no stanzas: refused in words, or written plain.
    doAssertRaises(DatWriteError):
      s.writeSegy(dir / "r0.sgy", SegyOutputOptions(revision: SegyRevision(major: 0,
        minor: 0)))
    try:
      s.writeSegy(dir / "r0.sgy", SegyOutputOptions(revision: SegyRevision(major: 0,
        minor: 0)))
    except DatWriteError as e:
      doAssert "Rev 1 or later" in e.msg and "vendorLayout" in e.msg and "file number" in e.msg
    doAssert not fileExists(dir / "r0.sgy")
    s.writeSegy(dir / "r0.sgy", SegyOutputOptions(revision: SegyRevision(major: 0, minor: 0)),
      DatWriteOptions(vendorLayout: false))
    var r0 = openSeismic(dir / "r0.sgy")
    doAssert r0.len == 4
    r0.close()
    # a stanza after the first trace: parseSEG's refusal comes out as DatWriteError
    var w = openSeismicWriter(dir / "late.sgy", SegyOutputOptions())
    w.writeSegyTraces(s)
    doAssertRaises(DatWriteError):
      w.addShotBlock(s)

when isMainModule:
  main()
