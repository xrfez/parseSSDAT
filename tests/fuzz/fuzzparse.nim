## libFuzzer target for `parseDat` (not part of the test run).
##
## Build (clang with libFuzzer), from the package folder:
##   nim c --cc:clang --panics:on -d:release -d:useMalloc -g --noMain:on \
##     --passC:"-fsanitize=fuzzer,address" --passL:"-fsanitize=fuzzer,address" \
##     -o:fuzzparse tests/fuzz/fuzzparse.nim
##   mkdir corpus   # and put in it files that `synthDat` (tests/datsynth.nim) writes
##   ./fuzzparse -max_len=131072 corpus
## Without libFuzzer, replay files: `nim c -d:fuzzStandalone tests/fuzz/fuzzparse.nim`
## then `./fuzzparse input...` (with none, it replays a few synthetic files). The test
## runner builds and runs it that way, so it cannot stop compiling unnoticed. Seed the corpus with files `synthDat` writes.

import parseSSDAT/[decode, types]

var reused: DatShot ## one shot decodes every input, as a caller that keeps one does

proc initialize(): cint {.cdecl, exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    cdecl, exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  if len > 0:
    for allow in [false, true]:
      try:
        discard parseDat(data.toOpenArray(0, len - 1), allow)
        decodeInto(reused, data.toOpenArray(0, len - 1), allow)
      except DatFormatError:
        discard # the expected refusal; any other failure is a finding
      except ValueError:
        discard # the interval check: never raised for the default interval
    try:
      discard parseDatInfo(data.toOpenArray(0, len - 1))
    except DatFormatError:
      discard
    except ValueError:
      discard

when defined(fuzzStandalone):
  import std/[cmdline, syncio]
  import ../datsynth

  proc replay(buf: string) =
    if buf.len > 0:
      discard testOneInput(cast[ptr UncheckedArray[byte]](cstring(buf)), buf.len)

  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  if paramCount() == 0: # no files: a few synthetic ones, so the target is exercised
    for samples in [1, 54, 200]:
      replay cast[string](synthDat(SynthDat(samples: samples)))
    replay cast[string](synthDat(SynthDat(samples: 200, truncateAfter: 4)))
  for i in 1 .. paramCount():
    replay readFile(paramStr(i))
