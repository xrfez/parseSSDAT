# Changelog

## 0.1.0 - Unreleased

- Decoder for a vibrator controller's `.dat` signature files: `parseDat`, `readDat`,
  `decodeInto` and `readDatInto` (a shot and a buffer kept between files),
  `parseDatInfo` and `readDatInfo` (a file's header, position, trailer and QC record
  from three blocks, for file lists), `looksLikeDat`, `datFileStem`.
- Channels: reference, reaction-mass force, baseplate force (raw counts); the
  controller's ground force as their sum (`groundForce`); the QC record as `DatQc`.
- Refuses every damaged file with `DatFormatError` or `DatIncompleteError`; a stopped
  recording can be read with `allowIncomplete`.
- Writers for SEG-Y and SEG-D through parseSEG: `writeSegy`, `writeSegd`,
  `writeSegyTo`, `writeSegdTo`, `writeSegyTraces`, `writeSegdTraces`, with options
  for positions, scaling, mean removal, the ground force trace, swapped force
  channels, the SEG-D reference type and the external converter's four traces.
- The shot block (`vendorLayout`, on by default): every decoded value, the QC record
  and the three raw records in 2048 bytes, written as one stanza `parseSSDAT:Shot v1`
  of a SEG-Y file's extended textual header (found by card 37) or as a SEG-D record's
  external header; vendor maps `parseSSDAT-segy-1` and `parseSSDAT-segd-1` in
  `vendormaps/`; `shotBlock`, `addShotBlock`, `withShotCard`. Needs parseSEG 0.19.0.
  `vendorLayout = false` writes exactly the files of before.
- Benchmark in `bench/`, a libFuzzer target in `tests/fuzz/`.
- `DatQc` decodes the QC record's fields (crew, vibrator ID, sweep, checksums, force
  and distortion summaries, limit letters, status bytes, the correlation series,
  position quality, stiffness, viscosity, target force); fields matched only in part
  are marked probable in their docs.
- The samples and the ground force are written as recorded: the file's ground force is
  opposite in sign to its reference, and no option changes a sign.
- `writeSegyTo` and `writeSegdTo` claim their file name exclusively.
