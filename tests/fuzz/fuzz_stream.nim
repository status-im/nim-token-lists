{.push raises: [], gcsafe.}

## Differential target: the streaming parser against the typed decoder it
## replaced (tests/oracle), in every mode, under default and tight limits.
import tokenlists/core/[types, errors, store]
import tokenlists/core/parsers/stream
import tests/oracle/legacy

proc nimMain() {.importc: "NimMain", cdecl.}

proc initialize(argc: ptr cint, argv: ptr ptr cstring): cint
    {.exportc: "LLVMFuzzerInitialize", cdecl.} =
  nimMain()
  0

proc same(
    actual: Result[ParsedSource, TklError], fresh: TokenStore,
    expected: Result[ParsedSource, TklError], old: TokenStore
): bool =
  if actual.isErr or expected.isErr:
    return actual.isErr and expected.isErr and actual.error == expected.error
  if actual.get.list != expected.get.list or
      actual.get.rowNumbers != expected.get.rowNumbers or
      actual.get.rows.len != expected.get.rows.len:
    return false
  for index, row in actual.get.rows:
    let other = expected.get.rows[index]
    if fresh.token(row) != old.token(other) or
        fresh.record(row).flags != old.record(other).flags:
      return false
  true

proc fuzz(data: ptr UncheckedArray[byte], size: csize_t): cint
    {.exportc: "LLVMFuzzerTestOneInput", cdecl.} =
  if size == 0 or size > 65536:
    return 0
  var input = newString(int(size))
  copyMem(addr input[0], data, int(size))
  let tight = ParseLimits(maxBytes: 4096, maxDepth: 6, maxArrayItems: 16,
    maxObjectMembers: 12, maxStringBytes: 48, maxRows: 1 shl 30)
  for limits in [DefaultParseLimits, tight]:
    for format in [StandardFormat, StatusFormat]:
      for validate in [false, true]:
        var fresh, old = initTokenStore()
        let actual = parseList(fresh, input, format, "src", limits, validate)
        let expected =
          if validate: legacyRefreshParse(old, input, format, "src", limits)
          else: legacyParse(old, input, format, "src", limits)
        doAssert same(actual, fresh, expected, old)
      doAssert validateList(input, format, "src", limits) ==
        legacyValidate(input, format, "src", limits)
  0
