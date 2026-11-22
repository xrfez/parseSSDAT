## The decoder against synthetic files: every field round-trips, the refusals say
## what is wrong, and incomplete files are told from corrupt ones.
##
## Seen to fail: with the sign extension of `sample24` left out, the `signs` block
## fails; with the trailer's `u32be` reads shifted by one byte, `roundTrip` fails;
## with the checksum test of `checkBlock` removed, `checksums` fails; with the
## `declared > (n - 3) * 54` test removed, `headerSamples` fails; with the room of
## the sample arrays taken from the header (`room = wanted`), `blockCounts` fails;
## with the seconds limit at 61, `bigNumbers` fails; with the scan for data after a zero
## block left out, `corruptIsNotIncomplete` fails; with the `got == 0` refusal left
## out, `noSamples` fails; with the interval check left out, `interval` fails; with
## the buffer grown before the size check in `readDatInto`, `readFiles` fails.

import std/[os, strutils]
import parseSSDAT/[decode, types]
import datsynth

proc refused(data: openArray[byte]; words: openArray[string]; allow = false): string =
  ## The message of the `DatFormatError` `parseDat` raises for `data`; each of
  ## `words` is in it.
  try:
    discard parseDat(data, allow)
    doAssert false, "was not refused (wanted: " & $words & ")"
  except DatFormatError as e:
    result = e.msg
    for w in words:
      doAssert w in e.msg, "'" & w & "' not in: " & e.msg

proc sameShot(a: DatShot; s: SynthDat; ns: int) =
  doAssert a.controllerSerial == s.serial and a.fileNumber == s.fileNumber
  doAssert a.firmware == s.firmware
  doAssert a.trigger == s.trigger, $a.trigger
  doAssert a.len == ns and a.declaredSamples == ns and a.complete
  doAssert a.sampleIntervalUs == 1000
  for c in DatChannel:
    doAssert a.data[c].len == ns
    if s.data[c].len > 0:
      doAssert a.data[c] == s.data[c], $c
  doAssert a.sourceLine == s.line and a.sourceStation == s.station
  doAssert a.shotId == s.shotId and a.sourceIndex == s.index
  doAssert a.trailerCounter == s.counter and a.sweepId == s.sweepId
  doAssert a.records.len == 3 and a.records[0].kind == 0x80 and
    a.records[1].kind == 0x87 and a.records[2].kind == 0x84
  doAssert a.records[0].bytes.len == 512 and a.records[2].offset > 512

proc main*() =

  block roundTrip:
    for ns in [1, 53, 54, 55, 108, 120, 4000, 12000]:
      for last in [-1, 0]:
        for qc in [97, 99, 100]:
          var s = SynthDat(samples: ns, qcOffset: qc, lastFrames: last, line: 101,
            station: 202, shotId: 303, index: 4, counter: 55, sweepId: 66,
            firmware: (if qc == 99: (3, 9) else: (1, 2)))
          let d = synthDat(s)
          doAssert looksLikeDat(d)
          let blocks = d.len div 512
          let multiple = ns mod 54 == 0
          doAssert blocks == (if multiple and last == 0: ns div 54 + 4 elif multiple:
            ns div 54 + 3 else: ns div 54 + 4), $(ns, last, blocks)
          let a = parseDat(d)
          sameShot(a, s, ns)
          doAssert a.qc.raw.len == 240, $(ns, last, qc, blocks)
          doAssert a.qc.raw[0] == 0x46 and
            a.qc.raw[3] == 0xE7 and a.qc.raw == d[blockOffset(blocks - 1) + qc ..<
            blockOffset(blocks - 1) + qc + 240]
          doAssert a.records[0].bytes == d[0 ..< 512]
    # the generated samples are the chirp, the same on both sides
    let s = SynthDat(samples: 500)
    doAssert parseDat(synthDat(s)).data == parseDat(synthDat(s)).data
    doAssert $parseDat(synthDat(s)).trigger == "2001-02-03T04:05:06.789000Z"

  block signs:
    var s = SynthDat()
    for c in DatChannel:
      s.data[c] = @[-8_388_608'i32, -1, 0, 1, 8_388_607, -256, 255]
    let a = parseDat(synthDat(s))
    for c in DatChannel:
      doAssert a.data[c] == s.data[c]
    doAssert a.samples(dcMass)[0] == -8_388_608.0'f32 and a.samples(dcBaseplate)[4] ==
      8_388_607.0'f32

  block channelsAreSeparate:
    var s = SynthDat()
    s.data[dcReference] = @[1'i32, 2, 3]
    s.data[dcBaseplate] = @[10'i32, 20, 30]
    s.data[dcMass] = @[-100'i32, -200, -300]
    let a = parseDat(synthDat(s))
    doAssert a.data == s.data

  block unknownBytesDoNotMatter:
    ## Every byte the format leaves unexplained is changed: the shot is the same.
    for qc in [97, 100]:
      let s = SynthDat(samples: 200, qcOffset: qc, line: 9, sweepId: 8)
      var d = synthDat(s)
      let want = parseDat(d)
      let n = d.len div 512
      proc scramble(d: var seq[byte]; k: int; ranges: openArray[Slice[int]]) =
        for r in ranges:
          for i in r:
            d[blockOffset(k) + i] = byte(0xFF - int(d[blockOffset(k) + i]) + 1) xor 0x5C
        fixChecksum(d, k)
      scramble(d, 0, [3 .. 3, 22 .. 31, 34 .. 45, 50 .. 183, 184 .. 279, 503 .. 505])
      scramble(d, 1, [20 .. 20, 21 .. 134, 152 .. 165])
      scramble(d, n - 1, [20 .. 29, 54 .. qc - 1])
      for k in 2 ..< n - 1: # the data records' fourth byte
        scramble(d, k, [3 .. 3])
      var a = parseDat(d)
      doAssert a.data == want.data and a.sweepId == 8 and a.sourceLine == 9
      doAssert a.qc.raw.len == 240

  block timeAndHeader:
    doAssert posixTime(DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5,
      second: 6, nanosecond: 789_000_000)) == 981173106.789
    doAssert posixTime(DatTime(year: 1970, month: 1, day: 1)) == 0.0
    doAssert posixTime(DatTime(year: 2000, month: 3, day: 1)) == 951868800.0
    doAssert posixTime(DatTime(year: 2024, month: 12, day: 31, hour: 23, minute: 59,
      second: 59)) == 1735689599.0
    let a = parseDat(synthDat(SynthDat(trigger: DatTime(year: 2024, month: 2, day: 29,
      hour: 23, minute: 59, second: 60, nanosecond: 999_999_999))))
    doAssert a.trigger.second == 60 and a.trigger.nanosecond == 999_999_999
    # the length of the shot
    doAssert parseDat(synthDat(SynthDat(samples: 77))).len == 77

  block positions:
    let a = parseDat(synthDat(SynthDat()))
    doAssert a.gga.valid and a.gga.latitudeDeg == 12.0 + 30.5 / 60 and
      a.gga.longitudeDeg == (45.0 + 30.25 / 60) and a.gga.altitudeM == 100.0 and
      a.gga.geoidSeparationM == 10.0 and a.gga.fixQuality == 1 and
      a.gga.satellites == 8 and a.gga.hdop == 0.9
    doAssert a.fix.latitudeDeg == 12.0 + 30.5 / 60 and
      a.fix.longitudeDeg == 45.0 + 30.25 / 60 and a.fix.heightDm == 1234 and
      a.fix.fixQuality == 2 and a.fix.satellites == 9 and a.fix.hdop == 1.1
    let b = parseDat(synthDat(SynthDat(fixLat: (33, 15_000_000, 'S'),
      fixLon: (120, 0, 'W'),
      text: "9600 bps;$GNGGA,010203.00,3315.000000,S,12000.500000,W,2,10,1.5,-5.5,M,2.0,M,,*hh\r\n")))
    doAssert b.fix.latitudeDeg == -33.25 and b.fix.longitudeDeg == -120.0
    doAssert b.gga.valid and b.gga.latitudeDeg == -33.25 and
      b.gga.longitudeDeg < -120.008 and b.gga.altitudeM == -5.5
    # another hemisphere letter: NaN, not an error
    let c = parseDat(synthDat(SynthDat(fixLat: (33, 15_000_000, 'X'))))
    doAssert c.fix.latitudeDeg != c.fix.latitudeDeg and c.fix.longitudeDeg == (45.0 + 30.25 / 60)
    # out of range
    let e = parseDat(synthDat(SynthDat(fixLat: (91, 0, 'N'), fixLon: (10, 70_000_000, 'E'))))
    doAssert e.fix.latitudeDeg != e.fix.latitudeDeg and e.fix.longitudeDeg != e.fix.longitudeDeg

  block ggaParser:
    doAssert not parseGga("").valid and not parseGga("no sentence here").valid
    doAssert not parseGga("$GPGGA,").valid and not parseGga("$GPGGA,010203,12").valid
    doAssert not parseGga("$GPGGA,010203.00,1230.5,N,04530.25,E").valid # cut: no quality
    doAssert not parseGga("$GPGGA,010203.00,,,,,0,00,,,M,,M,,*66").valid # no fix
    doAssert not parseGga("$GPGGA,010203.00,1260.0,N,04530.25,E,1,8,0.9,1.0,M,1.0,M").valid
    doAssert not parseGga("$GPGGA,010203.00,1230.5,Q,04530.25,E,1,8,0.9,1.0,M,1.0,M").valid
    doAssert not parseGga("$GPGGA,010203.00,nan.5,N,04530.25,E,1,8,0.9,1.0,M,1.0,M").valid
    doAssert not parseGga("GPGGA,010203.00,1230.5,N,04530.25,E,1,8").valid # no `$`
    # a bad sentence first, a good one after it
    let g = parseGga("$GPGGA,x,1230.5,N,04530.25,E,1,8\r\n$GPGGA,0,1230.5,N,04530.25,E,1,8\r\n")
    doAssert g.valid and g.satellites == 8 and g.altitudeM == 0 and g.hdop == 0
    let h = parseGga("$GPGGA,010203.00,0000.0,N,00000.0,E,1,,,,M,,M,,*00")
    doAssert h.valid and h.latitudeDeg == 0 and h.satellites == 0
    doAssert not parseGga("$GPGGA,010203.00,1230.5,N,04530.25,E,1,8,0.9,1e999,M").valid

  block textIsCleaned:
    var s = SynthDat(text: "abc\x01\x7F\xC3\xA9\r\nxyz")
    let a = parseDat(synthDat(s))
    doAssert a.headerText == "abc????\r\nxyz", a.headerText.escape
    doAssert not a.gga.valid

  block refusedHeads:
    let word = "not a .dat"
    discard refused(newSeq[byte](0), [word, "0 bytes"])
    discard refused(newSeq[byte](511), [word, "511 bytes"])
    discard refused(newSeq[byte](512), [word, "first block"])
    discard refused(newSeq[byte](4096), [word, "first block"])
    var segy = newSeq[byte](3600)
    for i in 0 ..< 3200:
      segy[i] = 0x40 # EBCDIC blanks
    discard refused(segy, [word, "first block"])
    var segd = newSeq[byte](1024)
    segd[0] = 0x00
    segd[1] = 0x01
    segd[10] = 0x0F
    discard refused(segd, [word])
    var text = newSeq[byte](2000)
    for i in 0 ..< text.len:
      text[i] = byte(ord("hello world\n"[i mod 12]))
    discard refused(text, [word])
    doAssert not looksLikeDat(newSeq[byte](0)) and not looksLikeDat(segy) and
      not looksLikeDat(segd) and not looksLikeDat(text) and
      not looksLikeDat(newSeq[byte](512)) and not looksLikeDat(synthDat(SynthDat())[0 ..< 511])
    var d = synthDat(SynthDat())
    doAssert looksLikeDat(d[0 ..< 512]) and looksLikeDat(d)
    # the first block of another kind, or a damaged header
    var e = d
    e[2] = 0x81
    fixChecksum(e, 0)
    discard refused(e, [word, "0x81"])
    doAssert not looksLikeDat(e)
    e = d
    e[blockOffset(0) + 100] = e[blockOffset(0) + 100] xor 1
    discard refused(e, [word, "checksum"])
    e = d
    e[12] = 2
    fixChecksum(e, 0)
    discard refused(e, [word, "block number"])
    e = d
    e[16] = 2 # block count 2
    e[17] = 0
    e[18] = 0
    e[19] = 0
    fixChecksum(e, 0)
    discard refused(e, [word, "2 blocks"])
    doAssert not looksLikeDat(e)

  block checksums:
    let d = synthDat(SynthDat(samples: 200))
    let n = d.len div 512
    for k in 0 ..< n:
      var e = d
      e[blockOffset(k) + 40] = e[blockOffset(k) + 40] xor 0x10
      if k == 0:
        discard refused(e, ["not a .dat", "checksum"])
      else:
        discard refused(e, ["block " & $(k + 1) & " of " & $n, "fails its checksum"])
    # a change in the padding after the record does not matter
    var e = d
    e[blockOffset(2) + 511] = 0x99
    discard parseDat(e)

  block wrongKinds:
    let d = synthDat(SynthDat(samples: 200)) # 0x80 0x87 0x81 0x81 0x81 0x82 0x84
    let n = d.len div 512
    doAssert n == 7
    for k in 1 ..< n:
      for kind in [0x80'u8, 0x81, 0x82, 0x84, 0x87, 0x00, 0xFF]:
        if kind != d[blockOffset(k) + 2]:
          var e = d
          e[blockOffset(k) + 2] = kind
          fixChecksum(e, k)
          let msg = refused(e, ["block " & $(k + 1) & " of 7", "belongs there"])
          doAssert "0x" & toHex(int(kind), 2) in msg

  block otherFileOrUnit:
    let d = synthDat(SynthDat(samples: 200))
    for k in 1 ..< d.len div 512:
      var e = d
      e[blockOffset(k) + 8] = e[blockOffset(k) + 8] + 1
      fixChecksum(e, k)
      discard refused(e, ["block " & $(k + 1), "is from file 7002, not 7001"])
      e = d
      e[blockOffset(k) + 4] = e[blockOffset(k) + 4] + 1
      fixChecksum(e, k)
      discard refused(e, ["block " & $(k + 1), "from controller 4322, not 4321"])

  block blockNumbers:
    var d = synthDat(SynthDat(samples: 200))
    # blocks 3 and 4 swapped
    for i in 0 ..< 512:
      swap(d[blockOffset(2) + i], d[blockOffset(3) + i])
    discard refused(d, ["block 3 of 7", "numbered 4"])
    d = synthDat(SynthDat(samples: 200))
    d[blockOffset(3) + 12] = 3
    fixChecksum(d, 3)
    discard refused(d, ["block 4 of 7", "numbered 3"])
    d = synthDat(SynthDat(samples: 200))
    d[blockOffset(3) + 16] = 8 # a different block count
    fixChecksum(d, 3)
    discard refused(d, ["block 4 of 7", "announces 8 blocks"])

  block recordLengths:
    let d = synthDat(SynthDat(samples: 200))
    proc withLength(k, length: int): seq[byte] =
      result = d
      result[blockOffset(k)] = byte(length and 0xFF)
      result[blockOffset(k) + 1] = byte(length shr 8)
    for length in [511, 18, 0, 65535, 4096]:
      discard refused(withLength(3, length), ["block 4 of 7", "record length " & $length])
      discard refused(withLength(0, length), ["not a .dat"])
    # lengths that pass the checksum (the sum is fixed) but are wrong for the kind
    for length in [504, 495, 20, 19]:
      var e = withLength(3, length)
      fixChecksum(e, 3)
      discard refused(e, ["block 4 of 7", "full data record"])
    var e = withLength(5, 130) # a last record: (130 - 19) mod 9 != 0
    fixChecksum(e, 5)
    discard refused(e, ["block 6 of 7", "whole number"])
    e = withLength(1, 100)
    fixChecksum(e, 1)
    discard refused(e, ["block 2 of 7", "position record"])
    e = withLength(6, 30)
    fixChecksum(e, 6)
    discard refused(e, ["block 7 of 7", "trailer"])
    e = withLength(0, 400)
    fixChecksum(e, 0)
    discard refused(e, ["header record"])

  block headerSamples:
    let d = synthDat(SynthDat(samples: 200)) # 7 blocks hold at most 4 * 54 = 216
    proc withSamples(v: int64): seq[byte] =
      result = d
      for i in 0 .. 3:
        result[46 + i] = byte((v shr (8 * (3 - i))) and 0xFF)
      fixChecksum(result, 0)
    discard refused(withSamples(0), ["announces 0 samples"])
    discard refused(withSamples(217), ["announces 217 samples", "more than its 7 blocks"])
    discard refused(withSamples(0xFFFFFFFF'i64), ["more than its 7 blocks"])
    discard refused(withSamples(199), ["hold more than the 199 samples"])
    discard refused(withSamples(216), ["hold 200 samples", "announces 216"])
    discard parseDat(withSamples(200))

  block blockCounts:
    ## An absurd block count is refused at once, and nothing large is allocated.
    let d = synthDat(SynthDat(samples: 200))
    for count in [0'i64, 1, 2, 0xFFFFFFFF'i64, 0x7FFFFFFF, 1 shl 20, (64 shl 20) div 512,
        (64 shl 20) div 512 - 1]:
      var e = d
      for i in 0 .. 3:
        e[16 + i] = byte((count shr (8 * i)) and 0xFF)
      fixChecksum(e, 0)
      let before = getOccupiedMem()
      try:
        discard parseDat(e)
        doAssert false, "accepted block count " & $count
      except DatFormatError:
        discard
      doAssert getOccupiedMem() - before < 4 * e.len, $count
      doAssert not (looksLikeDat(e) and count >= (64 shl 20) div 512)
    # a large but possible count and sample count in a short file: the shot holds
    # the samples that are there, and nothing near the size the header states
    var e = synthDat(SynthDat(samples: 4 * 54, truncateAfter: 5))
    let count = (64 shl 20) div 512 - 1
    for k in 0 ..< 5:
      for i in 0 .. 3:
        e[blockOffset(k) + 16 + i] = byte((count shr (8 * i)) and 0xFF)
    for i in 0 .. 3:
      e[46 + i] = byte(((count - 3) * 54 shr (8 * (3 - i))) and 0xFF)
    for k in 0 ..< 5:
      fixChecksum(e, k)
    let before = getOccupiedMem()
    let a = parseDat(e, allowIncomplete = true)
    doAssert a.len == 3 * 54 and not a.complete
    doAssert getOccupiedMem() - before < 16 * e.len, $(getOccupiedMem() - before)
    doAssertRaises(DatIncompleteError):
      discard parseDat(e)

  block afterTrailer:
    let d = synthDat(SynthDat(samples: 200))
    for extra in [1, 100, 512, 1000]:
      let e = d & newSeq[byte](extra)
      discard refused(e, ["after the trailer", $extra & " bytes"])
      discard refused(e, ["after the trailer"], allow = true)

  block incomplete:
    for zero in [false, true]:
      for cut in [3, 5, 6]:
        let s = SynthDat(samples: 200, truncateAfter: cut, zeroBlockAtCut: zero,
          sweepId: 5, shotId: 6)
        let d = synthDat(s)
        let words = "the file holds " & $cut & " of the 7 blocks its header announces"
        try:
          discard parseDat(d)
          doAssert false
        except DatIncompleteError as e:
          doAssert words in e.msg and "stopped" in e.msg and "cut short" in e.msg, e.msg
          doAssert e.offset == cut * 512
        let a = parseDat(d, allowIncomplete = true)
        doAssert not a.complete and words in a.incompleteWhy
        doAssert a.len == (if cut == 6: 200 else: (cut - 2) * 54), $(cut, a.len)
        doAssert a.declaredSamples == 200 and a.sweepId == 0 and a.shotId == 0 and
          not a.qc.valid and a.qc.raw.len == 0 and a.records.len == 2
        doAssert a.controllerSerial == 4321 and a.trigger.year == 2001 and a.gga.valid
        let full = parseDat(synthDat(SynthDat(samples: 200)))
        for c in DatChannel:
          doAssert a.data[c] == full.data[c][0 ..< a.len]
    # the one before the trailer: the last data record is there too
    let s = SynthDat(samples: 200, truncateAfter: 6)
    doAssert parseDat(synthDat(s), true).len == 200
    # a header and position record only: no samples, so nothing to return
    doAssertRaises(DatIncompleteError):
      discard parseDat(synthDat(SynthDat(samples: 200, truncateAfter: 2)), true)

  block noSamples:
    ## A file cut right after its position record: no sample was recorded.
    for zero in [false, true]:
      let d = synthDat(SynthDat(samples: 200, truncateAfter: 2, zeroBlockAtCut: zero))
      doAssertRaises(DatIncompleteError):
        discard parseDat(d)
      try:
        discard parseDat(d, allowIncomplete = true)
        doAssert false
      except DatIncompleteError as e:
        doAssert "no samples were recorded" in e.msg and "2 of the 7 blocks" in e.msg, e.msg

  block cutPartBlock:
    var d = synthDat(SynthDat(samples: 200))
    d.setLen(4 * 512 + 300)
    doAssert parseDat(d, true).len == 2 * 54
    try:
      discard parseDat(d)
      doAssert false
    except DatIncompleteError as e:
      doAssert "4 of the 7 blocks" in e.msg

  block corruptIsNotIncomplete:
    # a block that is not zero and fails its checksum is corruption, flag or not
    var d = synthDat(SynthDat(samples: 200, truncateAfter: 5))
    d[blockOffset(3) + 77] = d[blockOffset(3) + 77] xor 1
    discard refused(d, ["block 4 of 7", "checksum"], allow = true)
    # a zero block in the header or position place is corruption too
    var e = synthDat(SynthDat(samples: 200))
    for i in 0 ..< 512:
      e[blockOffset(1) + i] = 0
    discard refused(e, ["block 2 of 7"], allow = true)
    # a zero block with data after it is corruption (S7), flag or not; the zero
    # block is named, not "the file holds 3 of its 7 blocks"
    var f = synthDat(SynthDat(samples: 200))
    for i in 0 ..< 512:
      f[blockOffset(4) + i] = 0
    discard refused(f, ["block 5 of 7", "all zeros", "block 6 of 7"], allow = true)
    discard refused(f, ["block 5 of 7", "all zeros"])
    # zero blocks to the end (or the end of the file) are an ending
    var g = synthDat(SynthDat(samples: 200))
    for k in 4 ..< 7:
      for i in 0 ..< 512:
        g[blockOffset(k) + i] = 0
    let a = parseDat(g, true)
    doAssert not a.complete and a.len == 108 and "4 of the 7 blocks" in a.incompleteWhy
    doAssertRaises(DatIncompleteError):
      discard parseDat(g)
    # one block is missing a header: refused with the flag
    discard refused(newSeq[byte](512), ["first block"], allow = true)
    let one = synthDat(SynthDat(samples: 200))[0 ..< 512]
    try:
      discard parseDat(one, true)
      doAssert false
    except DatIncompleteError as e:
      doAssert "position record is missing" in e.msg

  block samplesMustMatch:
    # all data records present, but one has lost frames in the middle: counts differ
    var d = synthDat(SynthDat(samples: 200))
    let n = d.len div 512
    # last data record shortened by a frame
    let o = blockOffset(n - 2)
    let l = int(d[o]) or (int(d[o + 1]) shl 8)
    d[o] = byte((l - 9) and 0xFF)
    d[o + 1] = byte((l - 9) shr 8)
    fixChecksum(d, n - 2)
    discard refused(d, ["hold 199 samples", "announces 200"])

  block exactMultiples:
    # 54 and 108 samples: a last record of 54 frames or of none, both read
    for ns in [54, 108]:
      for last in [-1, 0]:
        let a = parseDat(synthDat(SynthDat(samples: ns, lastFrames: last)))
        doAssert a.len == ns and a.complete

  block qcRecord:
    let s = SynthDat(samples: 100, crew: 9, vibrator: 77, sweepNumber: 16, sweepId: 123456,
      sweepChecksum: 0xBEEF, paramChecksum: 0xCAFE, shotId: 31, line: 41, station: 51)
    for qc in [97, 99, 100]:
      var s2 = s
      s2.qcOffset = qc
      let a = parseDat(synthDat(s2))
      doAssert a.qc.valid and a.qc.crew == 9 and a.qc.vibratorId == 77
      doAssert a.qc.sweepNumber == 16 and a.qc.sweepId == 123456
      doAssert a.qc.sweepChecksum == 0xBEEF and a.qc.paramChecksum == 0xCAFE
      doAssert a.qc.trigger == DatTime(year: 2001, month: 2, day: 3, hour: 4, minute: 5,
        second: 7, nanosecond: 790_000_000), $a.qc.trigger
      doAssert a.qc.shotId == 31 and a.qc.sourceLine == 41 and a.qc.sourceStation == 51
      doAssert a.qc.raw.len == 240 and a.qc.raw[2] == 0 and a.qc.raw[3] == 0xE7
      # the serial and the vibrator ID are different numbers
      doAssert a.controllerSerial == 4321 and a.qc.vibratorId != a.controllerSerial
    # no QC record: not valid, no raw bytes, the rest decodes
    let n = parseDat(synthDat(SynthDat(samples: 100, noQc: true, sweepId: 5)))
    doAssert not n.qc.valid and n.qc.raw.len == 0 and n.qc.vibratorId == 0
    doAssert n.sweepId == 5 and n.controllerSerial == 4321
    # a QC trigger that is not a time is kept as stored (nanoseconds -1)
    var odd = SynthDat(samples: 100)
    odd.qcTrigger = DatTime(year: 2030, month: 13, day: 40, hour: 25, minute: 61,
      second: 62, nanosecond: 5)
    let o = parseDat(synthDat(odd))
    doAssert o.qc.valid and o.qc.trigger.month == 13 and o.qc.trigger.year == 2030

  block bigNumbers:
    ## Numbers of 2^31 and above are numbers, not a RangeDefect on a 32-bit build.
    let s = SynthDat(samples: 60, serial: 0xFFFF_FFFF, fileNumber: 0xFFFF_FFFF)
    let a = parseDat(synthDat(s))
    doAssert a.controllerSerial == 0xFFFF_FFFF and a.fileNumber == 0xFFFF_FFFF
    doAssert datFileStem(a).startsWith("5_".repeat(0) & $(0xFFFF_FFFF'i64 mod 10_000_000_000'i64))
    var d = synthDat(SynthDat(samples: 60))
    for ns in [0x7FFF_FFFF'i64, 0x8000_0000'i64, 0xFFFF_FFFF'i64, 1_000_000_000]:
      var e = d
      for i in 0 .. 3:
        e[492 + i] = byte((ns shr (8 * i)) and 0xFF)
      fixChecksum(e, 0)
      discard refused(e, ["trigger time is not a valid date"])
    # the second is 0 to 60; 61 is not a time of day
    for (sec, ok) in [(59, true), (60, true), (61, false), (62, false), (255, false)]:
      var e = d
      e[496] = byte(sec)
      fixChecksum(e, 0)
      if ok: discard parseDat(e)
      else: discard refused(e, ["trigger time is not a valid date"])

  block interval:
    let d = synthDat(SynthDat(samples: 60))
    doAssert parseDat(d).sampleIntervalUs == 1000
    doAssert parseDat(d, sampleIntervalUs = 500.0).sampleIntervalUs == 500
    doAssert parseDat(d, allowIncomplete = true, sampleIntervalUs = 2000).sampleIntervalUs ==
      2000
    for bad in [0.0, -1.0, NaN, Inf, -Inf]:
      doAssertRaises(ValueError):
        discard parseDat(d, sampleIntervalUs = bad)
      doAssertRaises(ValueError):
        discard parseDatInfo(d, sampleIntervalUs = bad)

  block fileStem:
    let a = parseDat(synthDat(SynthDat(samples: 60)))
    doAssert datFileStem(a) == "4321_20010203T040506.789000000Z", datFileStem(a)
    let b = parseDat(synthDat(SynthDat(samples: 60, serial: 7, noQc: true,
      trigger: DatTime(year: 2024, month: 12, day: 31, hour: 23, minute: 59, second: 59,
      nanosecond: 5))))
    doAssert datFileStem(b) == "0007_20241231T235959.000000005Z"
    doAssert datFileStem(parseDatInfo(synthDat(SynthDat(samples: 60)))) == datFileStem(a)
    for c in datFileStem(a):
      doAssert c notin {':', '\\', '/', '*', '?', '"', '<', '>', '|', ' '}
    # sorts by controller, then time
    doAssert datFileStem(b) < datFileStem(a)

  block groundForce:
    var s = SynthDat()
    s.data[dcReference] = @[1'i32, 2, 3]
    s.data[dcMass] = @[-8_388_608'i32, 5, 8_388_607]
    s.data[dcBaseplate] = @[-1'i32, 6, 8_388_607]
    let a = parseDat(synthDat(s))
    doAssert a.groundForce == @[-8_388_609'i32, 11, 16_777_214]

  block info:
    ## `parseDatInfo` gives what a file list needs from three blocks.
    let s = SynthDat(samples: 300, line: 11, station: 12, shotId: 13, index: 4,
      sweepId: 15, counter: 16, vibrator: 21, crew: 2)
    let d = synthDat(s)
    let full = parseDat(d)
    let i = parseDatInfo(d)
    doAssert i.complete and i.incompleteWhy == "" and i.samples == 300 and
      i.declaredSamples == 300 and i.blocks == d.len div 512
    doAssert i.controllerSerial == 4321 and i.fileNumber == 7001 and
      i.firmware == (1, 2) and i.trigger == full.trigger
    doAssert i.sampleIntervalUs == 1000 and i.gga == full.gga and i.fix == full.fix
    doAssert i.sourceLine == 11 and i.sourceStation == 12 and i.shotId == 13 and
      i.sourceIndex == 4 and i.sweepId == 15 and i.trailerCounter == 16
    doAssert i.qc == full.qc and i.qc.vibratorId == 21 and i.qc.crew == 2
    doAssert i.headerText == full.headerText
    # a shot is an info: the same fields
    doAssert full.samples == 300 and full.blocks == i.blocks
    # the three-part form is given three blocks and the size only
    var first = d[0 ..< 1024]
    var last = d[d.len - 512 ..< d.len]
    let j = parseDatInfo(first, last, d.len)
    doAssert j.qc == i.qc and j.complete
    let k = parseDatInfo(first, last, d.len, sampleIntervalUs = 250)
    doAssert k.sampleIntervalUs == 250
    # an incomplete file is flagged, with the reason; the zero block is not counted
    for zero in [false, true]:
      let c = synthDat(SynthDat(samples: 200, truncateAfter: 4, zeroBlockAtCut: zero))
      let ci = parseDatInfo(c)
      doAssert not ci.complete and "4 of the 7 blocks" in ci.incompleteWhy, ci.incompleteWhy
      doAssert ci.samples == 108 and ci.declaredSamples == 200 and not ci.qc.valid
      doAssert ci.controllerSerial == 4321 and ci.trigger == full.trigger
    # cut right after the position record: flagged, no samples, not an error
    let two = parseDatInfo(synthDat(SynthDat(samples: 200, truncateAfter: 2)))
    doAssert not two.complete and two.samples == 0
    # shorter than that: an error
    doAssertRaises(DatIncompleteError):
      discard parseDatInfo(synthDat(SynthDat(samples: 200))[0 ..< 700])
    doAssertRaises(DatFormatError):
      discard parseDatInfo(synthDat(SynthDat(samples: 200))[0 ..< 300])
    # damage in the blocks it reads is found; in the others it is not (parseDat finds it)
    var e = d
    e[blockOffset(d.len div 512 - 1) + 40] = e[blockOffset(d.len div 512 - 1) + 40] xor 1
    doAssertRaises(DatFormatError):
      discard parseDatInfo(e)
    e = d
    e[blockOffset(3) + 40] = e[blockOffset(3) + 40] xor 1
    doAssert parseDatInfo(e).complete
    doAssertRaises(DatFormatError):
      discard parseDat(e)
    doAssertRaises(DatFormatError):
      discard parseDatInfo(d & @[byte 1])
    doAssertRaises(ValueError):
      discard parseDatInfo(first[0 ..< 600], last, d.len)

  block reuse:
    ## One shot and one buffer decode many files: the same as a new shot each time,
    ## and after the first, nothing is allocated.
    var s: DatShot
    var files: seq[seq[byte]] = @[]
    for i in 0 ..< 6:
      files.add synthDat(SynthDat(samples: 400 + i * 7 mod 50, fileNumber: 100 + i,
        sweepId: i, line: i, noQc: i == 3, qcOffset: [97, 99, 100][i mod 3]))
    files.add synthDat(SynthDat(samples: 200, truncateAfter: 4))
    files.add synthDat(SynthDat(samples: 10))
    for round in 0 ..< 2:
      for f in files:
        let want = parseDat(f, allowIncomplete = true)
        decodeInto(s, f, allowIncomplete = true)
        doAssert s.data == want.data and s.qc == want.qc and s.fix == want.fix
        doAssert s.fileNumber == want.fileNumber and s.complete == want.complete and
          s.incompleteWhy == want.incompleteWhy and s.headerText == want.headerText
        doAssert s.records.len == want.records.len and s.sweepId == want.sweepId
        for r in 0 ..< s.records.len:
          doAssert s.records[r].bytes == want.records[r].bytes and
            s.records[r].offset == want.records[r].offset
    # steady state: no growth of the heap
    let big = synthDat(SynthDat(samples: 12000))
    decodeInto(s, big)
    let before = getOccupiedMem()
    for i in 0 ..< 50:
      decodeInto(s, big)
    doAssert getOccupiedMem() - before <= 0, $(getOccupiedMem() - before)
    # a failed decode leaves the shot usable for the next file
    doAssertRaises(DatFormatError):
      decodeInto(s, big[0 ..< 3000])
    decodeInto(s, big)
    doAssert s.len == 12000 and s.complete

  block readFiles:
    let dir = getTempDir() / ("ssdat-tdecode-" & $getCurrentProcessId())
    createDir(dir)
    try:
      let p = dir / "a.dat"
      writeFile(p, cast[string](synthDat(SynthDat(samples: 300))))
      let a = readDat(p)
      doAssert a.len == 300 and a.complete
      doAssert readDat(p, allowIncomplete = true).fileNumber == 7001
      # an unreadable file names the path
      try:
        discard readDat(dir / "missing.dat")
        doAssert false
      except IOError as e:
        doAssert "missing.dat" in e.msg
      try:
        discard readDat(dir)
        doAssert false
      except IOError as e:
        doAssert dir in e.msg
      # larger than any .dat: refused before it is read
      let big = dir / "big.dat"
      let f = open(big, fmWrite)
      f.setFilePos(MaxDatBytes)
      f.write("x")
      f.close()
      try:
        discard readDat(big)
        doAssert false
      except DatFormatError as e:
        doAssert "larger than any .dat" in e.msg and "big.dat" in e.msg
      # ... and nothing was allocated for it
      var buffer: seq[byte] = @[]
      var shot: DatShot
      doAssertRaises(DatFormatError):
        readDatInto(big, shot, buffer)
      doAssert buffer.len == 0
      doAssertRaises(DatFormatError):
        discard readDatInfo(big)
      # info from the file: the same as from its bytes, and only three blocks read
      let bytes = synthDat(SynthDat(samples: 3000, line: 4, station: 5))
      writeFile(dir / "b.dat", cast[string](bytes))
      let info = readDatInfo(dir / "b.dat")
      doAssert info.qc == parseDatInfo(bytes).qc and info.complete and info.samples == 3000
      doAssert info.sourceLine == 4 and info.controllerSerial == 4321
      doAssert readDatInfo(dir / "b.dat", sampleIntervalUs = 500).sampleIntervalUs == 500
      writeFile(dir / "c.dat", cast[string](synthDat(SynthDat(samples: 200,
        truncateAfter: 4))))
      doAssert not readDatInfo(dir / "c.dat").complete
      writeFile(dir / "e.dat", "tiny")
      doAssertRaises(DatFormatError):
        discard readDatInfo(dir / "e.dat")
      doAssertRaises(IOError):
        discard readDatInfo(dir / "missing.dat")
      try:
        discard readDatInfo(dir)
        doAssert false
      except IOError as e:
        doAssert dir in e.msg
      # reading into a buffer kept between files
      readDatInto(dir / "b.dat", shot, buffer)
      doAssert shot.len == 3000 and buffer.len == bytes.len
      readDatInto(dir / "a.dat", shot, buffer)
      doAssert shot.len == 300
      # a file that is not a .dat
      writeFile(dir / "t.txt", "just text")
      try:
        discard readDat(dir / "t.txt")
        doAssert false
      except DatFormatError as e:
        doAssert "not a .dat" in e.msg
    finally:
      removeDir(dir)

when isMainModule:
  main()
