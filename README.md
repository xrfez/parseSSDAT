# parseSSDAT

Reads a vibrator controller's `.dat` signature files and writes them as SEG-Y or SEG-D
through [parseSEG](https://github.com/xrfez/parseSEG). MIT licence.

A file is a sequence of 512-byte blocks: a header record (trigger time, GNSS text), a
position record, data records and a trailer (source line, station, shot and sweep
numbers, and the controller's 240-byte QC record). The samples are three interleaved
channels of signed 24-bit counts, one sample per millisecond:

| channel | what it is | SEG-Y code | SEG-D type |
|---|---|---|---|
| 1 `dcReference` | the reference (pilot) | 21 | 0x96 |
| 2 `dcMass` | the reaction-mass force | 18 | 0x99 |
| 3 `dcBaseplate` | the baseplate force | 19 | 0x95 |
| 4 (written) | the controller's ground force, estimated: the sum of 2 and 3 | 20 | 0x93 |

**Polarity.** The ground force as the controller records it sits 180 degrees from its
reference (opposite in sign) in every sweep where that can be told; the controller
itself reads that as 0 degrees of phase. This library writes the samples and the ground
force exactly as recorded and never changes a sign. There is no option that flips or
aligns polarity.

Channels 2 and 3 are the controller's mass-weighted accelerations, in raw counts. The
external converter that some sites use labels them the other way round (its SEG-Y
calls channel 2 the baseplate); `DatWriteOptions.swapForces` is there for a unit that
is wired differently from the rest.

- `parseSSDAT/decode` and `parseSSDAT/types` need only the standard library.
  `parseSSDAT/toseg` is the only module that imports parseSEG.
- The decoder refuses any byte string that is not a `.dat` file with a
  `DatFormatError` that says which block is wrong. It never raises a `Defect`, never
  reads outside its input and never sizes an allocation from a number in the file.

## Example

```nim
import parseSSDAT

let shot = readDat("00001234.DAT")        # DatFormatError, DatIncompleteError, IOError
echo shot.controllerSerial, " file ", shot.fileNumber
echo shot.qc.valid, " vibrator ID ", shot.qc.vibratorId   # from the QC record
echo shot.trigger, ", ", shot.len, " samples at ", shot.sampleIntervalUs, " us"
echo shot.gga.valid, " ", shot.gga.latitudeDeg, " ", shot.gga.longitudeDeg
echo shot.sourceLine, " ", shot.sourceStation, " ", shot.sweepId  # 0: not given
let reference = shot.samples(dcReference)  # seq[float32], exact for 24-bit counts
let groundForce = shot.groundForce         # seq[int32]: channel 2 + channel 3

shot.writeSegy("shot.sgy")                 # 4 traces: codes 21, 18, 19, 20
shot.writeSegd("shot.sgd")                 # SEG-D Rev 3: 0x96, 0x99, 0x95, 0x93
let path = shot.writeSegyTo("out")         # out/<datFileStem>.sgy, never overwritten
```

The controller's **serial number** (`controllerSerial`, the 32-bit number in every
record header, the number the controller's folders are named after; header bytes 32
and 33 repeat it as remainder and quotient by 100, which agreed in every file seen) and the operator's **vibrator ID**
(`qc.vibratorId`, from the QC record, absent from a stopped recording) are different
numbers. File names use the serial; the SEG-Y device trace identifier holds the
vibrator ID.

`shot.qc` holds the QC record's decoded fields (`crew`, `vibratorId`, `sweepId`,
`forceMaxPct`, `limits`, `correlation`, `targetForceLbf`, ...) and its raw 240 bytes;
the doc comment of each says how sure its meaning is.

## Many files

- `readDatInfo(path)` reads the first two blocks and the last and nothing else, and
  gives a `DatInfo`: everything a file list needs (trigger time, serial, vibrator ID,
  sample count, interval, line, station, shot and sweep ids, both positions, complete
  or not and why). `parseDatInfo(first, last, fileSize)` does the same for bytes
  you hold. A `DatShot` is a `DatInfo` with its samples.
- `readDatInto(path, shot, buffer)` and `decodeInto(shot, bytes)` decode into a
  `DatShot` and a byte buffer that you keep between files: after the first files they
  allocate nothing. There is no global state: call them from several threads, each
  with its own shot and buffer.
- `looksLikeDat(first512Bytes)` tells a `.dat` file from another by its first block.
- `datFileStem(shot)` is the name every default output uses: the serial in four digits
  and the exact trigger time, UTC, to the nanosecond, `0042_20010203T040506.789000000Z`
  (a serial above 9999 gives a wider stem). It sorts for serials of one width, and holds
  nothing Windows forbids.
- `writeSegyTo` and `writeSegdTo` claim the file name exclusively: of several writers
  after the same name exactly one succeeds (an empty file stands there while it
  writes), the others get `DatWriteError`.

`nim bench` (or `nim c -d:release -r bench/bench.nim <folder>`) prints files per second
and MB/s for both.

## Stopped recordings

A recording that was stopped (the file ends, or turns to zeros, before the blocks its
header announces) raises `DatIncompleteError`. `allowIncomplete = true` returns the
samples recorded so far with `complete = false` and the reason in `incompleteWhy`; the
SEG-Y text header of such a shot says so (SEG-D has no free text). A file with no
sample at all, or a zero block with data after it, is refused either way.

## What the file does not say

| Choice | Default | Where to change it |
|---|---|---|
| Sample interval | 1000 us: the file does not state it | `sampleIntervalUs` of `readDat`, `parseDat`, `decodeInto`, `readDatInfo` |
| Units | raw counts, mean kept | `DatWriteOptions.scale`, `removeMean` |
| Ground force trace | written (code 20 / 0x93) | `DatWriteOptions.groundForce` |
| External converter's four traces | off | `DatWriteOptions.externalConverter` (three typed weights in pounds and the converter's two constants; no built-in values; its fourth trace is an equal-weight sum of accelerations times the hold-down weight, not a mass-weighted sum) |
| Source position | the GGA sentence of the header text | `DatWriteOptions.positions` (`dpGga`, `dpFix` for the binary fix, `dpNone`); the shot holds both |
| SEG-D reference type | 0x96, source reference sweep | `DatWriteOptions.segdReference` (0x98 allowed) |
| Force channels | file order | `DatWriteOptions.swapForces` |

SEG-Y positions go in as arc seconds (coordinate units 2). SEG-D has no field for
geographic coordinates, so SEG-D files get none. SEG-Y has no source line: the line and
station are in the text header, and the station is also the source point. A SEG-Y
file from the binary fix has no elevation (the format has no "unknown" but 0), and its
text header says so. The trigger time reaches Rev 2 SEG-Y to the nanosecond and SEG-D to
the microsecond, the resolution of its timestamps.

Several shots can go into one file, a record each:

```nim
var w = openSeismicWriter("all.sgy", SegyOutputOptions())
for shot in shots:
  w.writeSegyTraces(shot)                  # record = file number
discard w.close()
```

## Errors

`DatFormatError` (and its child `DatIncompleteError`) for bad input, `IOError` for the
file system, `ValueError` for an interval that is not positive and finite, and
`DatWriteError` for a shot or an option a writer cannot take, with plain words that
name the value: a source index above 255 or a file number above 16777215 in SEG-D, a
weight that is not above 0, an existing output file in the folder forms.

## Developing

Dependencies are pinned in `atlas.lock`. Fill `deps/` with `atlas rep atlas.lock`, or
without Atlas (it checks out nothing it should not touch) with
`nim depsSync`; `nim depsStatus` and `nim depsCheck` compare `deps/`, `nim.cfg` and
the lock. An existing working copy of parseSEG can be linked as `deps/parseSEG`.

```sh
nim test            # every tests/t*.nim, one process each (debug)
nim testRelease     # the same in -d:release and -d:danger
nim bench           # decoder speed on synthetic files
nim docs            # API docs into htmldocs/
```

The tests use synthetic files written by `tests/datsynth.nim`: the library reads this
format and does not write it. `tests/fuzz/fuzzparse.nim` is a libFuzzer target for
`parseDat`.
