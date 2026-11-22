# Vendor maps of parseSSDAT

parseSEG's vendor maps that describe the shot block parseSSDAT writes into a SEG-Y or
SEG-D file (`DatWriteOptions.vendorLayout`, on by default). Put this folder on the search
path of a parseSEG program (`PARSESEG_VENDOR_PATH`, or load it with `loadVendorMaps`) and
the block decodes by field name.

| File | For |
|---|---|
| `parseSSDAT-segy-1.nif` | SEG-Y files: the block is the binary stanza `parseSSDAT:Shot v1` of the extended textual header; recognised by card 37, `PARSESSDAT SHOT STANZAS VERSION 1 (MAP PARSESSDAT-SEGY-1)` |
| `parseSSDAT-segd-1.nif` | SEG-D Rev 3 files: the block is the record's external header (64 blocks of 32 bytes); recognised by `SSDATSHT` at its first byte |

Both hold the same fields: SEG-Y and SEG-D files written by parseSSDAT from a vibrator
controller's `.dat` signature file: the shot block (decoded fields, QC record, raw
records). The layout belongs to parseSSDAT, not to the controller's maker; the maps
carry no company name and the files hold no value that is not in the `.dat` file.

The block is 2048 bytes, big-endian: 8 bytes `SSDATSHT`, the layout version and the
block length, the decoded header, position and trailer values, the 240-byte QC record
verbatim from byte 257 (its fields and the 128-value correlation series decoded by name,
`qc...` and `corr[i]`), and the three raw 512-byte records of the file. Unused bytes are
0, and a latitude or longitude that is NaN means none. The samples are not in it, and
neither is a flipped sign: the ground force is written as recorded.
