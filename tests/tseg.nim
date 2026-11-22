## A decoded shot written through parseSEG's SEG-Y and SEG-D writers and read back
## with parseSEG: samples bit for bit, trace codes, times, positions and text.
##
## Seen to fail: with `segyTraceCode` returning 20 for the baseplate, `codes` fails;
## with the mean not removed in `outTraces`, `scaleAndMean` fails; with the
## `trace.coordinateUnits` override left out, `segyHeaders` fails; with the SEG-D
## channel types swapped, `segd` fails; with the `ext1.nanoseconds` override left
## out, `exactNanoseconds` fails; with `CardWidth` at 80, `cards` fails; with SEG-D
## given the SEG-Y positions, `segd` fails; with the ground force summing the same
## channel twice, `codes` fails; with the serial in the device id, `segyHeaders` fails.

import std/[atomics, math, os, options, strutils]
import parseSEG
import parseSSDAT
import datsynth

proc tmpDir(): string =
  result = getTempDir() / ("ssdat-tseg-" & $getCurrentProcessId())
  createDir(result)

proc readBack(f: SeismicFile; n: int): seq[seq[float32]] =
  var log: DiagLog
  let x = f.readTraces(0 ..< n, log)
  doAssert log.len == 0
  for i in 0 ..< n:
    result.add newSeq[float32](x.shape[1])
    for j in 0 ..< x.shape[1]:
      result[i][j] = x[i, j]

proc headerValue(f: SeismicFile; trace: int; header, field: string): string =
  for r in f.traceHeaders(trace):
    if r.blockName == header and r.field == field:
      return $r.value
  doAssert false, "no " & header & "." & field

proc meanOf(v: seq[int32]): float64 =
  var sum = 0.0
  for x in v:
    sum += float64(x)
  sum / float64(v.len)

proc refusal(s: DatShot; words: openArray[string]; segd = false;
    dat = DatWriteOptions()) =
  ## Writing `s` raises `DatWriteError` whose message holds all `words`.
  let p = getTempDir() / ("ssdat-tseg-refused-" & $getCurrentProcessId())
  try:
    if segd: s.writeSegd(p, dat) else: s.writeSegy(p, dat = dat)
    doAssert false, "was written (wanted: " & $words & ")"
  except DatWriteError as e:
    for w in words:
      doAssert w in e.msg, "'" & w & "' not in: " & e.msg
  doAssert not fileExists(p)

proc main*() =
  let dir = tmpDir()
  defer: removeDir(dir)
  let s = parseDat(synthDat(SynthDat(samples: 300, line: 11, station: 12, index: 3,
    shotId: 5, sweepId: 6, vibrator: 12)))
  let t0 = posixTime(s.trigger)
  let lon = (45.0 + 30.25 / 60) * 3600
  let lat = (12.0 + 30.5 / 60) * 3600

  block mapping:
    doAssert segyTraceCode(dcReference) == 21 and segyTraceCode(dcMass) == 18 and
      segyTraceCode(dcBaseplate) == 19
    doAssert segdChannelType(dcReference) == sctSourceRefSweep and
      segdChannelType(dcMass) == sctSourceMass and
      segdChannelType(dcBaseplate) == sctSourceBasePlate
    doAssert segdChannelType(dcReference, sctSourceRefPilot) == sctSourceRefPilot
    doAssert $dcMass == "reaction-mass force" and $dcBaseplate == "baseplate force"
    let k = toTraceKeys(s, dcBaseplate)
    doAssert k.record == 7001 and k.channel == 3 and k.traceCode == 19 and
      k.status == tsAuxiliary and k.intervalUs == 1000 and k.t0Ms == 0 and
      k.time == t0 and k.srcLine == 11 and k.srcPoint == 12 and k.srcIndex == 3
    doAssert k.srcX.isNaN and k.srcY.isNaN and k.srcZ.isNaN and k.rcvX.isNaN
    let g = toTraceKeys(s, dcMass, dpGga)
    doAssert abs(g.srcX - lon) < 1e-6 and abs(g.srcY - lat) < 1e-6 and g.srcZ == 100 and
      g.rcvX == g.srcX and g.rcvY == g.srcY and g.rcvZ == 100 and g.channel == 2
    let x = toTraceKeys(s, dcMass, dpFix)
    doAssert abs(x.srcX - lon) < 1e-6 and x.srcZ.isNaN
    # an info gives keys too
    doAssert toTraceKeys(parseDatInfo(synthDat(SynthDat(samples: 10))),
      dcMass).traceCode == 18
    # nothing given: NaN, not 0
    let blank = parseDat(synthDat(SynthDat(samples: 10)))
    doAssert toTraceKeys(blank, dcReference).srcLine.isNaN and
      toTraceKeys(blank, dcReference).srcPoint.isNaN and
      toTraceKeys(blank, dcReference).srcIndex == 0
    let nogga = parseDat(synthDat(SynthDat(samples: 10, text: "nothing")))
    doAssert toTraceKeys(nogga, dcReference, dpGga).srcX.isNaN

  block codes:
    let p = dir / "a.sgy"
    s.writeSegy(p)
    var f = openSeismic(p, keys = true)
    doAssert f.len == 4 # the three channels and the ground force
    for i in 0 ..< 4:
      let k = f.traceKeys(i)
      doAssert k.traceCode == [21'i16, 18, 19, 20][i] and k.status == tsAuxiliary, $i
      doAssert k.record == 7001 and k.channel == float64(i + 1)
      doAssert abs(k.time - t0) < 1e-6, $(k.time, t0)
      doAssert k.intervalUs == 1000 and k.srcPoint == 12, $(k.intervalUs, k.srcPoint)
    let back = readBack(f, 4)
    for c in DatChannel:
      doAssert back[ord(c)] == s.samples(c), "samples of " & $c # bit for bit
    var gf: seq[float32] = @[]
    for v in s.groundForce:
      gf.add float32(v)
    doAssert back[3] == gf
    doAssert gf[7] == float32(s.data[dcMass][7] + s.data[dcBaseplate][7])
    let text = f.textHeader
    for w in ["vibrator controller .dat signature file", "controller serial 4321",
        "file 7001", "vibrator ID 12", "sweep id 6", "shot id 5",
        "source line 11 station 12 index 3", "reference", "reaction-mass force",
        "baseplate force", "raw counts", "controller ground force (estimated)",
        "sum of traces 2 and 3", "(assumed)", "parseSSDAT"]:
      doAssert w in text, w
    doAssert "real" notin text and "true" notin text and "measured" notin text
    f.close()
    # the ground force is switched off
    s.writeSegy(dir / "a3.sgy", dat = DatWriteOptions(groundForce: false))
    f = openSeismic(dir / "a3.sgy", keys = true)
    doAssert f.len == 3 and "ground force" notin f.textHeader
    f.close()

  block segyHeaders:
    let p = dir / "b.sgy"
    s.writeSegy(p)
    var f = openSeismic(p, keys = true)
    doAssert f.headerValue(0, "trace", "coordinateUnits") == "2"
    # the vibrator ID, not the controller serial
    doAssert f.headerValue(2, "trace", "deviceTraceId") == "12"
    let k = f.traceKeys(0)
    doAssert abs(k.srcX - lon) < 2e-3, $k.srcX
    doAssert abs(k.srcY - lat) < 2e-3
    doAssert abs(k.srcZ - 100.0) < 0.2
    f.close()
    # no positions: no coordinates, no units
    s.writeSegy(dir / "c.sgy", dat = DatWriteOptions(positions: dpNone))
    f = openSeismic(dir / "c.sgy", keys = true)
    doAssert f.traceKeys(0).srcX.isNaN and
      f.headerValue(0, "trace", "coordinateUnits") == "0"
    doAssert "no coordinates written" in f.textHeader
    f.close()
    # the binary fix instead of the GGA: no elevation, and the text says so
    s.writeSegy(dir / "d.sgy", dat = DatWriteOptions(positions: dpFix))
    f = openSeismic(dir / "d.sgy", keys = true)
    doAssert abs(f.traceKeys(0).srcY - lat) < 2e-3
    doAssert "no elevation given" in f.textHeader
    f.close()
    # a vibrator ID that does not fit 16 bits, or no QC record: no device id
    var big = s
    big.qc.vibratorId = 70000
    big.writeSegy(dir / "e.sgy")
    f = openSeismic(dir / "e.sgy", keys = true)
    doAssert f.headerValue(0, "trace", "deviceTraceId") == "0"
    f.close()
    let noqc = parseDat(synthDat(SynthDat(samples: 50, noQc: true)))
    noqc.writeSegy(dir / "e2.sgy")
    f = openSeismic(dir / "e2.sgy", keys = true)
    doAssert f.headerValue(0, "trace", "deviceTraceId") == "0"
    doAssert "vibrator ID" notin f.textHeader and "controller serial 4321" in f.textHeader
    f.close()
    # the caller's own text header wins
    s.writeSegy(dir / "f.sgy", SegyOutputOptions(text: @["my own card"]))
    f = openSeismic(dir / "f.sgy")
    doAssert "my own card" in f.textHeader and "vibrator controller" notin f.textHeader
    f.close()

  block exactNanoseconds:
    ## The trigger time's nanoseconds reach the file as they are: a float64 of
    ## seconds cannot hold them.
    for ns in [789_000_000, 123_456_789, 999_999_999, 1, 0]:
      let sh = parseDat(synthDat(SynthDat(samples: 40, trigger: DatTime(year: 2001, month: 2,
        day: 3, hour: 4, minute: 5, second: 6, nanosecond: ns))))
      let p = dir / "ns.sgy"
      sh.writeSegy(p)
      var f = openSeismic(p, keys = true)
      for i in 0 ..< 4:
        doAssert f.headerValue(i, "ext1", "nanoseconds") == $ns, $(i, ns)
        doAssert f.headerValue(i, "trace", "second") == "6", $ns
      f.close()
    # Rev 1 has no extension header: the file is written, to the second and a fraction
    s.writeSegy(dir / "r1.sgy", SegyOutputOptions(revision: SegyRevision(major: 1,
      minor: 0)))
    var f = openSeismic(dir / "r1.sgy", keys = true)
    doAssert f.len == 4 and abs(f.traceKeys(0).time - t0) < 1.0
    f.close()

  block cards:
    ## Cards are at most 76 characters (parseSEG adds "C nn "); a longer line goes on
    ## the next card, never cut.
    let long = DatWriteOptions(scale: [123456.789, 2.5, 0.25], removeMean: true)
    let made = textCards(s, long)
    for c in made:
      doAssert c.len <= 76, c
    let joined = made.join("\n")
    for w in ["scale reference 123456.789", "scale reaction-mass force 2.5",
        "scale baseplate force 0.25", "mean removed"]:
      doAssert w in joined, w
    var wide = s
    wide.incompleteWhy = "the file holds 50 of the 226 blocks its header announces: the " &
      "recording stopped or the copy was cut short"
    wide.complete = false
    let cuts = textCards(wide, DatWriteOptions())
    for c in cuts:
      doAssert c.len <= 76, c
    let all = cuts.join("\n").replace("\n  ", " ")
    doAssert "incomplete recording: the file holds 50 of the 226 blocks its header " &
      "announces: the recording stopped or the copy was cut short" in all, all
    # and on the file: every card is read back whole
    wide.writeSegy(dir / "cards.sgy", dat = long)
    var f = openSeismic(dir / "cards.sgy")
    let text = f.textHeader
    doAssert "scale reaction-mass force 2.5" in text and "mean removed" in text
    doAssert "cut short" in text
    for line in text.splitLines:
      doAssert line.len == 80
    f.close()

  block scaleAndMean:
    let p = dir / "g.sgy"
    let o = DatWriteOptions(scale: [0.5, 2.0, 0.25], removeMean: true)
    s.writeSegy(p, dat = o)
    var f = openSeismic(p)
    let back = readBack(f, 4)
    for c in DatChannel:
      let mean = meanOf(s.data[c])
      for j in 0 ..< s.len:
        doAssert back[ord(c)][j] == float32(o.scale[c] * (float64(s.data[c][j]) - mean)),
          $(c, j)
    # the ground force is the sum of the two force traces as written
    for j in 0 ..< s.len:
      let m = o.scale[dcMass] * (float64(s.data[dcMass][j]) - meanOf(s.data[dcMass]))
      let b = o.scale[dcBaseplate] * (float64(s.data[dcBaseplate][j]) -
        meanOf(s.data[dcBaseplate]))
      doAssert back[3][j] == float32(m + b), $j
    doAssert "mean removed" in f.textHeader
    f.close()
    # scale only: no mean removed
    s.writeSegy(dir / "h.sgy", dat = DatWriteOptions(scale: [3.0, 1.0, 1.0]))
    f = openSeismic(dir / "h.sgy")
    let b2 = readBack(f, 4)
    doAssert b2[0][5] == float32(3.0 * float64(s.data[dcReference][5]))
    doAssert b2[1] == s.samples(dcMass)
    f.close()

  block swapForces:
    s.writeSegy(dir / "sw.sgy", dat = DatWriteOptions(swapForces: true))
    var f = openSeismic(dir / "sw.sgy", keys = true)
    let back = readBack(f, 4)
    doAssert f.traceKeys(1).traceCode == 18 and f.traceKeys(2).traceCode == 19
    doAssert back[1] == s.samples(dcBaseplate) and back[2] == s.samples(dcMass)
    doAssert back[0] == s.samples(dcReference)
    var gf: seq[float32] = @[]
    for v in s.groundForce:
      gf.add float32(v)
    doAssert back[3] == gf # the sum does not care
    doAssert "swapped" in f.textHeader
    f.close()

  block externalConverter:
    ## The external converter's four traces from typed numbers (made up here).
    let cv = DatConverterUnit(reactionMassWeight: 1111.0, baseplateWeight: 2222.0,
      holdDownWeight: 12345.0, k: 0.375, s0: 0.0625)
    let o = DatWriteOptions(externalConverter: some(cv), groundForce: false)
    s.writeSegy(dir / "cv.sgy", dat = o)
    var f = openSeismic(dir / "cv.sgy", keys = true)
    doAssert f.len == 4
    for i in 0 ..< 4:
      doAssert f.traceKeys(i).traceCode == [21'i16, 18, 19, 20][i]
    let back = readBack(f, 4)
    let f1 = cv.s0
    let f2 = cv.k / cv.reactionMassWeight
    let f3 = cv.k / cv.baseplateWeight
    let mr = meanOf(s.data[dcReference])
    let mm = meanOf(s.data[dcMass])
    let mb = meanOf(s.data[dcBaseplate])
    for j in 0 ..< s.len:
      doAssert back[0][j] == float32(f1 * (float64(s.data[dcReference][j]) - mr))
      let t2 = f2 * (float64(s.data[dcMass][j]) - mm)
      let t3 = f3 * (float64(s.data[dcBaseplate][j]) - mb)
      doAssert back[1][j] == float32(t2) and back[2][j] == float32(t3)
      doAssert back[3][j] == float32(cv.holdDownWeight * (t2 + t3)), $j
    let text = f.textHeader
    doAssert "equal-weight sum of accelerations, not a mass-weighted sum" in
      textCards(s, o).join("\n").replace("\n  ", " ")
    doAssert "hold-down weight 12345.0 lb" in text
    f.close()
    # all five numbers are needed
    for bad in [DatConverterUnit(), DatConverterUnit(reactionMassWeight: 1, baseplateWeight: 1,
        holdDownWeight: 1, k: 1), DatConverterUnit(reactionMassWeight: 1,
        baseplateWeight: -1, holdDownWeight: 1, k: 1, s0: 1)]:
      doAssertRaises(DatWriteError):
        s.writeSegy(dir / "bad.sgy", dat = DatWriteOptions(externalConverter: some(bad)))
    refusal(s, ["file number 7001", "reaction-mass weight", "not above 0"],
      dat = DatWriteOptions(externalConverter: some(DatConverterUnit())))
    refusal(s, ["baseplate weight is -1.0"], dat = DatWriteOptions(
      externalConverter: some(DatConverterUnit(reactionMassWeight: 1, baseplateWeight: -1,
      holdDownWeight: 1, k: 1, s0: 1))))

  block segd:
    let p = dir / "j.sgd"
    s.writeSegd(p) # the default options: no positions in a SEG-D file
    var f = openSeismic(p, keys = true)
    doAssert f.len == 4
    var types: seq[int]
    for cs in f.channelSets:
      types.add cs.channelType
      doAssert cs.traceCount == 1 and cs.samplesPerTrace == 300 and
        cs.sampleIntervalUs == 1000
    doAssert types == @[0x96, 0x99, 0x95, 0x93], $types
    for i in 0 ..< 4:
      let k = f.traceKeys(i)
      doAssert k.record == 7001 and k.status == tsAuxiliary, $k.status
      doAssert abs(k.time - t0) < 1e-6, $(k.time, t0)
      doAssert k.srcLine == 11 and k.srcPoint == 12 and k.srcIndex == 3
      doAssert k.srcX.isNaN and k.srcY.isNaN, "geographic positions are not written"
    let back = readBack(f, 4)
    for c in DatChannel:
      doAssert back[ord(c)] == s.samples(c), "SEG-D samples of " & $c
    f.close()
    # positions asked for are still not written (no SEG-D place for them)
    s.writeSegd(dir / "j2.sgd", DatWriteOptions(positions: dpGga))
    f = openSeismic(dir / "j2.sgd", keys = true)
    doAssert f.traceKeys(0).srcX.isNaN
    f.close()
    # no ground force: three channel sets; the pilot as the reference type
    s.writeSegd(dir / "k.sgd", DatWriteOptions(groundForce: false,
      segdReference: sctSourceRefPilot))
    f = openSeismic(dir / "k.sgd")
    var t2: seq[int]
    for cs in f.channelSets: t2.add cs.channelType
    doAssert t2 == @[0x98, 0x99, 0x95], $t2
    f.close()
    refusal(s, ["SEG-D reference channel type is 0x70", "not 0x96 or 0x98"], true,
      DatWriteOptions(segdReference: sctOther))

  block writerRefusals:
    ## Plain words that name the value, as `DatWriteError`.
    var odd = s
    odd.sampleIntervalUs = 1000.5
    refusal(odd, ["file number 7001", "1000.5 us", "whole number of microseconds"], true)
    odd.writeSegy(dir / "odd.sgy") # SEG-Y takes a fractional interval
    var idx = s
    idx.sourceIndex = 300
    refusal(idx, ["source index 300", "above 255", "SEG-D"], true)
    idx.writeSegy(dir / "idx.sgy") # SEG-Y: left out of the keys
    var num = s
    num.fileNumber = 16_777_216
    refusal(num, ["file number 16777216", "above 16777215"], true)
    num.fileNumber = 16_777_215
    num.writeSegd(dir / "num.sgd")
    var line = s
    line.sourceLine = 0
    refusal(line, ["both a source line and a station", "a station (12)"], true)
    var wide = s
    wide.sourceLine = 4_294_967_295'i64
    wide.sourceStation = 4_294_967_295'i64
    refusal(wide, ["file number 7001", "SEG-D", "4294967295"], true)
    # a shot with no samples (not from the decoder)
    refusal(DatShot(), ["holds no samples"])
    refusal(DatShot(), ["holds no samples"], true)
    # the translated parseSEG refusals are also DatWriteError, not ValueError
    var rec = s
    rec.fileNumber = 2_147_483_647
    rec.writeSegy(dir / "rec.sgy")
    doAssertRaises(DatWriteError):
      rec.writeSegd(dir / "rec.sgd")
    doAssert not fileExists(dir / "rec.sgd")

  block severalShots:
    ## Several shots into one writer: one record each, SEG-Y and SEG-D.
    var shots: seq[DatShot] = @[]
    for i in 0 ..< 3:
      shots.add parseDat(synthDat(SynthDat(samples: 100, fileNumber: 7001 + i,
        sweepId: int64(i))))
    var w = openSeismicWriter(dir / "m.sgy", SegyOutputOptions())
    for sh in shots:
      w.writeSegyTraces(sh)
    doAssert w.close().len == 0
    var f = openSeismic(dir / "m.sgy", keys = true)
    doAssert f.len == 12
    for i in 0 ..< 12:
      doAssert f.traceKeys(i).record == float64(7001 + i div 4)
    f.close()
    var d = openSeismicWriter(dir / "m.sgd", SegdOutputOptions(sampleIntervalUs: 1000,
      numSamples: 100))
    for sh in shots:
      d.writeSegdTraces(sh)
    doAssert d.close().len == 0
    f = openSeismic(dir / "m.sgd", keys = true)
    doAssert f.len == 12
    for i in 0 ..< 12:
      doAssert f.traceKeys(i).record == float64(7001 + i div 4)
    f.close()

  block folderForms:
    let folder = dir / "out"
    let stem = datFileStem(s)
    let p = s.writeSegyTo(folder)
    doAssert p == folder / (stem & ".sgy") and fileExists(p)
    doAssert openSeismic(p).len == 4
    # never overwritten silently
    doAssertRaises(DatWriteError):
      discard s.writeSegyTo(folder)
    try:
      discard s.writeSegyTo(folder)
    except DatWriteError as e:
      doAssert "exists" in e.msg and stem in e.msg and "file number 7001" in e.msg
    var other = s
    other.data[dcReference][0] += 1
    let before = readFile(p)
    doAssertRaises(DatWriteError):
      discard other.writeSegyTo(folder)
    doAssert readFile(p) == before
    doAssert other.writeSegyTo(folder, overwrite = true) == p and readFile(p) != before
    let q = s.writeSegdTo(folder)
    doAssert q == folder / (stem & ".sgd") and fileExists(q)
    doAssertRaises(DatWriteError):
      discard s.writeSegdTo(folder)
    doAssert s.writeSegdTo(folder, overwrite = true) == q

  block incompleteShot:
    ## An incomplete shot is written with the samples it has, and says so.
    let d = synthDat(SynthDat(samples: 200, truncateAfter: 4))
    let part = parseDat(d, allowIncomplete = true)
    doAssert part.len == 108 and not part.complete
    part.writeSegy(dir / "n.sgy")
    var f = openSeismic(dir / "n.sgy")
    doAssert f.len == 4 and f.readBack(4)[0] == part.samples(dcReference)
    doAssert "incomplete recording" in f.textHeader and "cut short" in f.textHeader
    f.close()
    part.writeSegd(dir / "n.sgd")
    f = openSeismic(dir / "n.sgd")
    doAssert f.len == 4
    f.close()

  block polarityAsRecorded:
    ## The samples and the ground force go in as recorded: no sign is changed, and
    ## the text header says how the file's ground force sits against its reference.
    var neg = s
    for i in 0 ..< neg.len:
      neg.data[dcMass][i] = -abs(neg.data[dcMass][i]) - 1
      neg.data[dcBaseplate][i] = -abs(neg.data[dcBaseplate][i]) - 2
      neg.data[dcReference][i] = abs(neg.data[dcReference][i]) + 3
    neg.writeSegy(dir / "pol.sgy")
    var f = openSeismic(dir / "pol.sgy")
    let back = readBack(f, 4)
    for i in 0 ..< neg.len:
      doAssert back[0][i] == float32(neg.data[dcReference][i]) and back[0][i] > 0
      doAssert back[1][i] == float32(neg.data[dcMass][i]) and back[1][i] < 0
      doAssert back[3][i] == float32(neg.data[dcMass][i] + neg.data[dcBaseplate][i])
    doAssert "opposite in sign to the reference" in f.textHeader.replace("\n", " ")
    f.close()

  block exclusiveClaim:
    ## A name is claimed in one step: a file already there, or another writer ahead,
    ## means `DatWriteError`; the empty claim of a failed write is removed.
    let folder = dir / "claim"
    createDir(folder)
    let stem = datFileStem(s)
    writeFile(folder / (stem & ".sgy"), "")
    doAssertRaises(DatWriteError):
      discard s.writeSegyTo(folder)
    doAssert readFile(folder / (stem & ".sgy")) == "" # not touched
    removeFile(folder / (stem & ".sgy"))
    # a write that fails after the claim leaves nothing
    var wide = s
    wide.sourceLine = 4_294_967_295'i64
    wide.sourceStation = 4_294_967_295'i64
    doAssertRaises(DatWriteError):
      discard wide.writeSegdTo(folder)
    doAssert not fileExists(folder / (stem & ".sgd"))
    # a folder that cannot be made is an IOError (its parent is a file)
    writeFile(dir / "plain", "x")
    doAssertRaises(IOError):
      discard s.writeSegyTo(dir / "plain" / "sub")
    doAssertRaises(IOError):
      discard s.writeSegdTo(dir / "plain" / "sub")

  when defined(posix):
    block folderNotWritable:
      ## The file system's refusal (permission denied: an `OSError` from `createDir` or
      ## the claim) comes out as `IOError`, as the module promises. Not when run as root.
      let ro = dir / "readonly"
      createDir(ro)
      setFilePermissions(ro, {fpUserRead, fpUserExec})
      try:
        if not (try: (writeFile(ro / "probe", "x"); false) except IOError: true):
          removeFile(ro / "probe") # the permission does not bind this user
        else:
          doAssertRaises(IOError):
            discard s.writeSegyTo(ro / "sub")
          doAssertRaises(IOError):
            discard s.writeSegdTo(ro)
          doAssertRaises(IOError):
            discard s.writeSegyTo(ro)
      finally:
        setFilePermissions(ro, {fpUserRead, fpUserWrite, fpUserExec})

  block racingWriters:
    ## Writers after one name at the same time: exactly one gets it.
    type Race = object
      shot: ptr DatShot
      folder: cstring
      won, lost, other: Atomic[int]
    let raceDir = dir / "race"
    var race = Race(folder: cstring(raceDir))
    var shot = s
    race.shot = addr shot
    proc worker(r: ptr Race) {.thread.} =
      {.cast(gcsafe).}:
        try:
          discard r.shot[].writeSegyTo($r.folder)
          discard r.won.fetchAdd(1)
        except DatWriteError:
          discard r.lost.fetchAdd(1)
        except CatchableError:
          discard r.other.fetchAdd(1)
    for round in 0 ..< 5:
      removeDir(dir / "race")
      race.won.store(0)
      race.lost.store(0)
      race.other.store(0)
      var threads: array[8, Thread[ptr Race]]
      for i in 0 ..< threads.len:
        createThread(threads[i], worker, addr race)
      joinThreads(threads)
      doAssert race.won.load == 1 and race.lost.load == 7 and race.other.load == 0,
        $(race.won.load, race.lost.load, race.other.load)
      doAssert openSeismic(dir / "race" / (datFileStem(s) & ".sgy")).len == 4

  block writerRevisions:
    ## `writeSegyTraces` with its default suits a Rev 1 writer; the exact nanoseconds
    ## are for a Rev 2 writer, which `extHeader = true` asks for.
    var w = openSeismicWriter(dir / "rev1.sgy", SegyOutputOptions(revision: SegyRevision(
      major: 1, minor: 0)))
    w.writeSegyTraces(s)
    doAssert w.close().len == 0
    var f = openSeismic(dir / "rev1.sgy")
    doAssert f.len == 4
    f.close()
    var w2 = openSeismicWriter(dir / "rev2.sgy", SegyOutputOptions())
    w2.writeSegyTraces(s, extHeader = true)
    doAssert w2.close().len == 0
    f = openSeismic(dir / "rev2.sgy", keys = true)
    doAssert f.headerValue(0, "ext1", "nanoseconds") == "789000000"
    f.close()
    var w3 = openSeismicWriter(dir / "rev1b.sgy", SegyOutputOptions(revision: SegyRevision(
      major: 1, minor: 0)))
    doAssertRaises(DatWriteError): # asking for the extension a Rev 1 file has not got
      w3.writeSegyTraces(s, extHeader = true)

  block longWords:
    ## A word longer than a card is cut, not looped over; the cards stay within 80
    ## characters in the file whatever the shot holds.
    var odd = s
    odd.complete = false
    odd.incompleteWhy = "x".repeat(300)
    odd.trigger = DatTime(year: 1_000_000_000, month: 1_000_000_000, day: 1_000_000_000,
      hour: 1_000_000_000, minute: 1_000_000_000, second: 1_000_000_000,
      nanosecond: 999_999_999)
    for c in textCards(odd, DatWriteOptions()):
      doAssert c.len <= 76, c
    doAssert textCards(odd, DatWriteOptions()).len <= 38
    let big = textCards(odd, DatWriteOptions(vendorLayout: false))
    var xs = 0
    for c in big:
      if c.strip.len > 0 and c.strip.allCharsInSet({'x'}): xs += c.strip.len
    doAssert big.len > 4 and xs == 300, $xs
    # in the file (the layout off: the trigger would not fit the block)
    odd.writeSegy(dir / "long.sgy", dat = DatWriteOptions(vendorLayout: false))
    var f = openSeismic(dir / "long.sgy")
    for line in f.textHeader.splitLines:
      doAssert line.len == 80
    f.close()
    # a long reason only: with the layout on
    var long = s
    long.complete = false
    long.incompleteWhy = "y".repeat(500)
    long.writeSegy(dir / "long2.sgy")
    doAssert textCards(long, DatWriteOptions()).len <= 37
    doAssert "y".repeat(50) in openSeismic(dir / "long2.sgy").textHeader

  block unwritable:
    doAssertRaises(CatchableError):
      s.writeSegy(dir / "no" / "such" / "folder" / "x.sgy")

when isMainModule:
  main()
