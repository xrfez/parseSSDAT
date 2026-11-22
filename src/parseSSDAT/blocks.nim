## Block framing of a `.dat` file: the length and checksum of a record, the record
## header, and the record kinds. Private to the package (parseSSDAT does not
## re-export it).
##
## A block is 512 bytes. Bytes 0-1 are the little-endian length `L` of the record,
## which is bytes `2 .. L+1`; its byte sum is 0 modulo 256. The first 18 bytes of
## every record are its header: kind, one byte, unit, file number, block number and
## block count (each a little-endian 32-bit number).

import ./types

const
  KindHeader* = 0x80'u8
  KindData* = 0x81'u8
  KindLast* = 0x82'u8
  KindTrailer* = 0x84'u8
  KindPosition* = 0x87'u8
  MaxLength* = DatBlockBytes - 2 ## the largest `L`
  MinLength* = 19                ## the record header and its checksum byte
  FrameBytes* = 9                ## one sample of each of the three channels
  FullFrames* = 54               ## frames of a full data record
  PayloadStart* = 20             ## block offset of the payload

type RecordHead* = object
  ## The common header of a record, read from a block.
  length*: int
  kind*: uint8
  unit*, fileNumber*, blockNumber*, blockCount*: int64

func raiseFormat*(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises a `DatFormatError` with the file offset of the problem.
  var e = newException(DatFormatError, msg)
  e.offset = offset
  raise e

func raiseIncomplete*(msg: string; offset: int64 = -1) {.noinline, noreturn.} =
  ## Raises a `DatIncompleteError` with the file offset of the problem.
  var e = newException(DatIncompleteError, msg)
  e.offset = offset
  raise e

func u16le*(b: openArray[byte]; at: int): int {.inline.} =
  int(b[at]) or (int(b[at + 1]) shl 8)

func u16be*(b: openArray[byte]; at: int): int {.inline.} =
  (int(b[at]) shl 8) or int(b[at + 1])

func u32le*(b: openArray[byte]; at: int): int64 {.inline.} =
  int64(b[at]) or (int64(b[at + 1]) shl 8) or (int64(b[at + 2]) shl 16) or
    (int64(b[at + 3]) shl 24)

func u32be*(b: openArray[byte]; at: int): int64 {.inline.} =
  (int64(b[at]) shl 24) or (int64(b[at + 1]) shl 16) or (int64(b[at + 2]) shl 8) or
    int64(b[at + 3])

func i16le*(b: openArray[byte]; at: int): int {.inline.} =
  let v = u16le(b, at)
  if v >= 0x8000: v - 0x10000 else: v

func isZeroBlock*(b: openArray[byte]): bool =
  ## True when every byte of the block is 0.
  result = true
  for x in b:
    if x != 0:
      return false

func sumIsZero*(b: openArray[byte]; length: int): bool =
  ## True when the record (bytes `2 .. length+1` of the 512-byte block `b`) sums to
  ## 0 modulo 256. `length` must be at most `MaxLength`.
  var sum = 0'u8
  for i in 2 .. length + 1:
    sum += b[i]
  sum == 0

func readHead*(b: openArray[byte]): RecordHead =
  ## The record header of the 512-byte block `b`; `length` is not checked.
  RecordHead(length: u16le(b, 0), kind: b[2], unit: u32le(b, 4),
    fileNumber: u32le(b, 8), blockNumber: u32le(b, 12), blockCount: u32le(b, 16))

func kindName*(kind: uint8): string =
  ## Plain words for a record kind.
  case kind
  of KindHeader: "header record"
  of KindPosition: "position record"
  of KindData: "data record"
  of KindLast: "last data record"
  of KindTrailer: "trailer"
  else: "record of unknown kind"

func framesIn*(length: int): int =
  ## Whole sample frames of a data record of record length `length` (-1 when the
  ## payload is not a whole number of frames).
  let payload = length - MinLength
  if payload >= 0 and payload mod FrameBytes == 0: payload div FrameBytes else: -1
