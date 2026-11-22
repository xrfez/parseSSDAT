## parseSSDAT reads a vibrator controller's `.dat` signature files and writes them
## as SEG-Y or SEG-D through parseSEG.
##
## `readDat` and `parseDat` decode a file into a `DatShot`: the three channels of raw
## counts, the trigger time, the positions and the shot numbers of the trailer.
## `looksLikeDat` tells such a file from another by its first block.
## `writeSegy`, `writeSegd` and `writeTraces` hand the shot to parseSEG's writers.
##
## The decoder (`parseSSDAT/decode`, `parseSSDAT/types`) needs only the standard
## library; only `parseSSDAT/toseg` imports parseSEG.

import parseSSDAT/[types, decode, toseg]
export types, decode, toseg
