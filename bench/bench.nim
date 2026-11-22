## Benchmark of the decoder: files per second and MB per second for reading the
## info of a file (`readDatInfo`: three blocks) and for decoding all of it
## (`readDatInto` with one shot and one buffer kept between files).
##
##   nim c -d:release -r bench/bench.nim                 # synthetic files, 400 of them
##   nim c -d:release -r bench/bench.nim 2000            # this many synthetic files
##   nim c -d:release -r bench/bench.nim <folder>...     # every .dat below the folders
##
## Each pass runs twice and the second is reported, so the files are in the system's
## cache and the numbers are the decoder's, not the disk's. MB/s counts the size of
## the files, whether or not the pass reads all of it. Prints counts and rates only.

import std/[algorithm, monotimes, os, strutils, times]
import parseSSDAT/[decode, types]
import ../tests/datsynth

proc megabytes(bytes: int64): float64 =
  float64(bytes) / 1e6

proc rate(what: string; files, refused: int; bytes: int64; took: Duration) =
  let s = max(float64(took.inNanoseconds) / 1e9, 1e-9)
  echo what.alignLeft(14), files, " files in ", formatFloat(s, ffDecimal, 3), " s: ",
    formatFloat(float64(files) / s, ffDecimal, 0), " files/s, ",
    formatFloat(megabytes(bytes) / s, ffDecimal, 0), " MB/s", (if refused > 0:
    ", " & $refused & " refused" else: "")

proc run(paths: seq[string]) =
  var bytes = 0'i64
  for p in paths:
    bytes += getFileSize(p)
  var shot: DatShot
  var buffer: seq[byte] = @[]
  for pass in 1 .. 2:
    var refused = 0
    var t = getMonoTime()
    for p in paths:
      try:
        discard readDatInfo(p)
      except DatFormatError:
        inc refused
    if pass == 2: rate("info only", paths.len, refused, bytes, getMonoTime() - t)
    refused = 0
    var samples = 0
    t = getMonoTime()
    for p in paths:
      try:
        readDatInto(p, shot, buffer, allowIncomplete = true)
        samples += shot.len
      except DatFormatError:
        inc refused
    if pass == 2:
      rate("full decode", paths.len, refused, bytes, getMonoTime() - t)
      echo "              ", samples, " samples per channel"

proc main() =
  let args = commandLineParams()
  var paths: seq[string] = @[]
  var made = ""
  if args.len == 0 or args[0].allCharsInSet(Digits):
    let count = if args.len > 0: parseInt(args[0]) else: 400
    made = getTempDir() / ("ssdat-bench-" & $getCurrentProcessId())
    createDir(made)
    for i in 0 ..< count:
      let samples = if i mod 8 == 7: 4000 else: 12000 # one 4 s file in eight
      writeFile(made / ("f" & $i & ".dat"), cast[string](synthDat(SynthDat(
        samples: samples, fileNumber: 1000 + i, line: i, station: i * 2,
        sweepId: i))))
      paths.add made / ("f" & $i & ".dat")
  else:
    for dir in args:
      for f in walkDirRec(dir):
        if f.toLowerAscii.endsWith(".dat"):
          paths.add f
    paths.sort()
  try:
    echo "files: ", paths.len
    run(paths)
  finally:
    if made.len > 0:
      removeDir(made)

main()
