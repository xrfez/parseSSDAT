## Hostile input: a file cut at every length, bytes flipped, blocks spliced from
## different files and blocks filled with random bytes never raise anything but
## `DatFormatError` (no Defect, no hang), with and without `allowIncomplete`.
## Fixed seeds: the same inputs every run. Run in a debug build (range, index and
## overflow checks on) and in `-d:danger` by `nim testRelease`.
##
## Seen to fail: with the check `got + frames > wanted` taken out of `parseDat`,
## `byteFlips` dies with an IndexDefect; with the `got == 0` refusal taken out of
## `decodeInto`, `everyPrefix` accepts a file with no sample.

import std/random
import parseSSDAT/[decode, types]
import datsynth

var reused: DatShot ## one shot decodes every input, as a caller that keeps one does

proc tryParse(d: openArray[byte]; allow: bool): bool =
  ## True when `d` decoded; false when `DatFormatError` refused it. Anything else
  ## escapes and fails the test. The reused shot and the info agree with a new decode.
  try:
    let s = parseDat(d, allow)
    for c in DatChannel:
      doAssert s.data[c].len == s.len
    doAssert s.len <= s.declaredSamples and s.len > 0 and s.samples == s.len
    decodeInto(reused, d, allow)
    doAssert reused.data == s.data and reused.qc == s.qc and reused.fix == s.fix and
      reused.headerText == s.headerText and reused.records.len == s.records.len and
      reused.complete == s.complete and reused.sweepId == s.sweepId
    if s.complete:
      let i = parseDatInfo(d)
      doAssert i.complete and i.qc == s.qc and i.sweepId == s.sweepId and
        i.samples == s.len and i.trigger == s.trigger and i.gga == s.gga
    result = true
  except DatFormatError as e:
    doAssert e.msg.len > 0
    result = false
  try:
    let i = parseDatInfo(d)
    doAssert i.samples <= i.declaredSamples and i.blocks >= 3
    doAssert i.complete == (i.incompleteWhy.len == 0)
  except DatFormatError as e:
    doAssert e.msg.len > 0

proc corrupted(d: seq[byte]; r: var Rand): seq[byte] =
  ## One random byte of `d` changed; half the time its block is summed again, so
  ## the checks behind the checksum are reached.
  result = d
  let at = r.rand(d.len - 1)
  result[at] = result[at] xor byte(1 + r.rand(254))
  if r.rand(1) == 0:
    fixChecksum(result, at div 512)

proc main*() =
  let base = synthDat(SynthDat(samples: 4 * 54 + 10, line: 1, sweepId: 2))
  doAssert base.len == 8 * 512

  block everyPrefix:
    for allow in [false, true]:
      for n in 0 .. base.len:
        let ok = tryParse(base.toOpenArray(0, n - 1), allow)
        if n == base.len:
          doAssert ok
        elif not allow:
          doAssert not ok, $n
        elif n >= 3 * 512:
          doAssert ok, "prefix " & $n & " with allowIncomplete"
        else:
          doAssert not ok, "prefix " & $n & " has no samples"

  block byteFlips:
    var r = initRand(20240607)
    for i in 0 ..< 2000:
      let d = corrupted(base, r)
      discard tryParse(d, false)
      discard tryParse(d, true)

  block splices:
    var r = initRand(918273)
    let other = synthDat(SynthDat(samples: 3 * 54, fileNumber: 99, serial: 7,
      qcOffset: 100, truncateAfter: -1))
    let sources = [base, other]
    for i in 0 ..< 500:
      var d: seq[byte] = @[]
      for k in 0 ..< 1 + r.rand(11):
        let src = sources[r.rand(1)]
        let b = r.rand(src.len div 512 - 1)
        d.add src.toOpenArray(b * 512, b * 512 + 511)
      if r.rand(3) == 0: # a first block that is a real header
        for j in 0 ..< 512:
          if d.len >= 512: d[j] = base[j]
      discard tryParse(d, false)
      discard tryParse(d, true)

  block randomBlocks:
    ## A block of random bytes under a valid length and sum.
    var r = initRand(5551212)
    for i in 0 ..< 1000:
      var d = base
      let k = r.rand(7)
      for j in 4 ..< 512:
        d[k * 512 + j] = byte(r.rand(255))
      d[k * 512] = byte(r.rand(255))
      d[k * 512 + 1] = byte(r.rand(1))
      fixChecksum(d, k)
      discard tryParse(d, false)
      discard tryParse(d, true)

  block headerNumbers:
    ## Large and small numbers in the header fields of every block.
    var r = initRand(31337)
    const extremes = [0'u32, 1, 2, 3, 53, 54, 55, 0x7FFFFFFF'u32, 0x80000000'u32, 0xFFFFFFFF'u32]
    for k in 0 .. 7:
      for field in [4, 8, 12, 16, 46, 492]:
        for v in extremes:
          if k == 0 or field < 46:
            var d = base
            for j in 0 .. 3:
              d[k * 512 + field + j] = byte((v shr (8 * j)) and 0xFF)
            if field == 46: # big-endian there
              for j in 0 .. 3:
                d[k * 512 + field + j] = byte((v shr (8 * (3 - j))) and 0xFF)
            fixChecksum(d, k)
            discard tryParse(d, false)
            discard tryParse(d, true)

when isMainModule:
  main()
