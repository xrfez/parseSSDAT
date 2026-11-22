## libFuzzer target for `parseDat` (not part of the test run).
##
## Build (clang with libFuzzer), from the package folder:
##   nim c --cc:clang --panics:on -d:release -d:useMalloc -g --noMain:on \
##     --passC:"-fsanitize=fuzzer,address" --passL:"-fsanitize=fuzzer,address" \
##     -o:fuzzparse tests/fuzz/fuzzparse.nim
##   mkdir corpus   # and put in it files that `synthDat` (tests/datsynth.nim) writes
##   ./fuzzparse -max_len=131072 corpus
## Without libFuzzer, replay files: `nim c -d:fuzzStandalone tests/fuzz/fuzzparse.nim`
## then `./fuzzparse input...`. Seed the corpus with files `synthDat` writes.

import parseSSDAT/[decode, types]

proc initialize(): cint {.cdecl, exportc: "LLVMFuzzerInitialize".} =
  {.emit: "N_CDECL(void, NimMain)(void); NimMain();".}

proc testOneInput(data: ptr UncheckedArray[byte], len: int): cint {.
    cdecl, exportc: "LLVMFuzzerTestOneInput", raises: [].} =
  result = 0
  if len > 0:
    for allow in [false, true]:
      try:
        discard parseDat(data.toOpenArray(0, len - 1), allow)
      except DatFormatError:
        discard # the expected refusal; any other failure is a finding

when defined(fuzzStandalone):
  import std/[cmdline, syncio]
  stderr.write "StandaloneFuzzTarget: running " & $paramCount() & " inputs\n"
  for i in 1 .. paramCount():
    var buf = readFile(paramStr(i))
    if buf.len > 0:
      discard testOneInput(cast[ptr UncheckedArray[byte]](cstring(buf)), buf.len)
