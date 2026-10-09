## The streaming parser against the typed decoder it replaced (tests/oracle):
## same verdict, error details, metadata and rows, permissive and strict.
import std/[os, random, strutils, unittest]
import ../../tokenlists/core/[types, errors, store]
import ../../tokenlists/core/parsers/stream
import ../oracle/legacy

const Root = currentSourcePath.parentDir / ".." / ".."

type Outcome = object
  failure: TklError
  list: TokenList
  tokens: seq[Token]
  flags: seq[set[RecordFlag]]
  rowNumbers: seq[uint32]

proc outcome(parsed: Result[ParsedSource, TklError], store: TokenStore): Outcome =
  if parsed.isErr:
    return Outcome(failure: parsed.error)
  result.list = parsed.get.list
  result.rowNumbers = parsed.get.rowNumbers
  for row in parsed.get.rows:
    result.tokens.add store.token(row)
    result.flags.add store.record(row).flags

proc differs(body: string, format: ListFormat, limits: ParseLimits): string =
  ## Empty when both parsers agree in every mode; else what differs.
  for validate in [false, true]:
    var fresh, old = initTokenStore()
    let actual = parseList(fresh, body, format, "src", limits, validate).outcome(fresh)
    let expected = (if validate: legacyRefreshParse(old, body, format, "src", limits)
      else: legacyParse(old, body, format, "src", limits)).outcome(old)
    # parseListBody rejects an empty body before either parser runs.
    if body.len > 0 and actual != expected:
      return "validate=" & $validate & " " & $format & "\nnew: " &
        $actual.failure & "\nold: " & $expected.failure
  let actual = validateList(body, format, "src", limits)
  let expected = legacyValidate(body, format, "src", limits)
  if actual != expected:
    return "validateList " & $format & "\nnew: " & $actual & "\nold: " & $expected
  ""

template agree(body: string, limits = DefaultParseLimits) =
  for format in [StandardFormat, StatusFormat]:
    let difference = differs(body, format, limits)
    if difference.len > 0:
      checkpoint body[0 ..< min(body.len, 400)]
      checkpoint difference
      fail()

const
  a = "0x000000000000000000000000000000000000000a"
  meta = """"name":"L","timestamp":"2025-01-01T00:00:00Z","version":{"major":1,"minor":2,"patch":3}"""
  standardRow = """{"chainId":1,"address":"""" & a &
    """","name":"N","symbol":"S","decimals":18,"logoURI":"https://x.org/a/b/c/d/e.png"}"""
  statusRow = """{"name":"N","symbol":"S","decimals":6,"crossChainId":"g","logoURI":"ipfs://l","contracts":{"10":"""" &
    a & """","1":"""" & a & """"}}"""

func list(rows: string, extra = ""): string =
  "{" & meta & extra & ""","tokens":[""" & rows & "]}"

const Cases = [
  "", " ", "null", "[]", "\"x\"", "1", "true", "{", "}", "{}", "{} ", "{}{}", "{} x",
  "{/*c*/}", "{\"a\":1/}", "{,}", "{\"a\":1,}", "{\"a\":1,,\"b\":2}", "{\"a\" 1}",
  "{\"a\":1 \"b\":2}", "{\"a\":}", "{\"a\":1", "{\"a\"", "{\"a", "{1:2}",
  "{\"a\":[1,]}", "{\"a\":[,1]}", "{\"a\":[1 2]}", "{\"a\":[1,,2]}", "{\"a\":[",
  "{\"a\":tru}", "{\"a\":trUe}", "{\"a\":nul}", "{\"a\":fals}", "{\"a\":falsey}",
  "{\"a\":+1}", "{\"a\":.5}", "{\"a\":-}", "{\"a\":-x}", "{\"a\":01}", "{\"a\":1.}",
  "{\"a\":1.x}", "{\"a\":1e}", "{\"a\":1e+}", "{\"a\":1ex}", "{\"a\":1E-5}",
  "{\"a\":123456789012345678901}", "{\"a\":12345678901234567890}",
  "{\"a\":1." & '1'.repeat(129) & "}", "{\"a\":1e" & '1'.repeat(33) & "}",
  "{\"a\":\"\\x41\"}", "{\"a\":\"\\q\"}", "{\"a\":\"\\v\\0\\'\\/\"}",
  "{\"a\":\"\\u12\"}", "{\"a\":\"\\u12G4\"}", "{\"a\":\"\\uD800\"}",
  "{\"a\":\"\\uD800x\"}", "{\"a\":\"\\uD800\\x\"}", "{\"a\":\"\\uD800\\u0041\"}",
  "{\"a\":\"\\uD83D\\uDE00\"}", "{\"a\":\"\\uDC00\"}", "{\"a\":\"a\tb\"}",
  "{\"a\":\"a\nb\"}", "{\"a\":\"\x01\"}", "{\"a\":\"\xff\"}", "{\"a\":\"\xc3\xa9\"}",
  "{\"a\":\"\xc0\x80\"}", "{\"a\":\"\xe2\x82\"}", "{\"a\":1}\xff", "{\"a\":\x01}",
  "\xef\xbb\xbf{}", "{\"a\":1,\"a\":2}", "{\"a\":1,\"\\u0061\":2}",
  "{\"a\":{\"b\":1,\"b\":2}}", "{\"a\":1,\"a\"x}",
  "{\"name\":5}", "{\"name\":null}", "{\"timestamp\":[]}", "{\"version\":null}",
  "{\"version\":{\"major\":\"1\"}}", "{\"version\":{\"major\":1.5}}",
  "{\"version\":{\"major\":-9223372036854775808}}",
  "{\"version\":{\"major\":-9223372036854775809}}",
  "{\"version\":{\"major\":18446744073709551616}}", "{\"version\":{}}",
  "{\"tags\":null}", "{\"tags\":[]}", "{\"tags\":1}", "{\"tags\":\"t\"}",
  "{\"tags\":{ \"a\" : [ 1 , \"\\u000b\\t\\/é\" ] }}", "{\"logoURI\":null}",
  "{\"logoURI\":1}", "{\"keywords\":null}", "{\"keywords\":[1]}",
  "{\"keywords\":[\"a\",null]}", "{\"tokens\":null}", "{\"tokens\":{}}",
  "{\"tokens\":[null]}", "{\"tokens\":[1,2]}", "{\"tokens\":[{\"chainId\":\"1\"}]}",
  "{\"tokens\":[{\"chainId\":-1}]}", "{\"tokens\":[{\"chainId\":1e1}]}",
  "{\"tokens\":[{\"chainId\":18446744073709551616}]}",
  "{\"tokens\":[{\"chainId\":18446744073709551615,\"decimals\":256}]}",
  "{\"tokens\":[{\"address\":null}]}", "{\"tokens\":[{\"logoURI\":null}]}",
  "{\"tokens\":[{\"crossChainId\":null}]}", "{\"tokens\":[{\"contracts\":null}]}",
  "{\"tokens\":[{\"contracts\":[]}]}", "{\"tokens\":[{\"contracts\":{\"x\":\"a\"}}]}",
  "{\"tokens\":[{\"contracts\":{\"\":\"a\"}}]}",
  "{\"tokens\":[{\"contracts\":{\"1\":\"a\",\"01\":\"b\"}}]}",
  "{\"tokens\":[{\"contracts\":{\"1\":5}}]}",
  "{\"tokens\":[{\"contracts\":{\"18446744073709551616\":\"a\"}}]}",
  "{\"tokens\":[{\"contracts\":{\"2\":\"b\",\"1\":\"a\",\"3\":\"c\"}}]}",
  "{\"tokens\":[{\"\\u0063hainId\":5,\"addr\\u0065ss\":\"0x\\u0030" & '0'.repeat(39) & "\"}]}",
  "{\"tokens\":[{\"name\":\"\\u00e9\\n\\\"\",\"symbol\":\"\\ud83d\\ude00\"}]}",
  "{\"tokens\":[{\"extensions\":{\"a\":[{},[],null,true,1.5e3]}}]}",
  list(standardRow), list(statusRow), list(standardRow & "," & standardRow),
  list(standardRow.replace("\"name\":\"N\",", "")),
  list(statusRow.replace("\"name\":\"N\",", "")),
  list(standardRow.replace("\"logoURI\":\"https://x.org/a/b/c/d/e.png\"", "\"logoURI\":null")),
  list(statusRow.replace("\"crossChainId\":\"g\"", "\"crossChainId\":null")),
  list(standardRow, ",\"logoURI\":\"bad uri\""), list(standardRow, ",\"logoURI\":\"\""),
  list(standardRow, ",\"logoURI\":null"), list(standardRow, ",\"keywords\":null"),
  list(standardRow, ",\"tags\":[]"), list(standardRow, ",\"tags\":null"),
  list(standardRow, ",\"tags\":{\"x\":{\"name\":\"X\"}}"),
  list("null"), list("1"), list("{}"),
  list(standardRow).replace("2025-01-01T00:00:00Z", "2025-02-30T00:00:00Z"),
  list(standardRow).replace("\"major\":1,", ""),
  list(standardRow).replace("\"timestamp\"", "\"Timestamp\""),
  list(standardRow).replace("\"tokens\"", "\"tokens\":[],\"t\""),
]

suite "streaming parser matches the typed decoder":
  test "edge cases":
    for body in Cases:
      agree(body)

  test "tight limits":
    for limits in [
        ParseLimits(maxBytes: 64, maxDepth: 2, maxArrayItems: 1,
          maxObjectMembers: 3, maxStringBytes: 4, maxRows: 1 shl 30),
        ParseLimits(maxBytes: 40, maxDepth: 3, maxArrayItems: 2,
          maxObjectMembers: 8, maxStringBytes: 64, maxRows: 1 shl 30),
        ParseLimits(maxBytes: 0, maxDepth: 1, maxArrayItems: 1,
          maxObjectMembers: 1, maxStringBytes: 1, maxRows: 1 shl 30)]:
      for body in Cases:
        agree(body, limits)
    # Escapes that re-encode longer than the document: a row and tags.
    let limits = ParseLimits(maxBytes: 48, maxDepth: 8, maxArrayItems: 8,
      maxObjectMembers: 8, maxStringBytes: 64, maxRows: 1 shl 30)
    agree("{\"tokens\":[{\"name\":\"\\v\\v\\v\\v\\v\\v\\v\\v\"}]}", limits)
    agree("{\"tags\":{\"a\":\"\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\"},\"name\":\"\"}", limits)
    agree("{\"tags\":{\"a\":\"\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\"},\"timestamp\":5}", limits)

  test "many keys in one object":
    var members: seq[string]
    for index in 0 ..< 200:
      members.add "\"k" & $index & "\":" & $index
    agree("{\"x\":{" & members.join(",") & "}}")
    agree("{\"x\":{" & members.join(",") & ",\"k77\":1}}")
    agree("{\"x\":{" & members.join(",") & ",\"k\\u0037\\u0037\":1}}")

  test "fixtures":
    for dir in ["fixtures/embedded", "fixtures/sdk/parsers", "fixtures/sdk/fetcher",
        "tests/fuzz/corpus"]:
      for path in walkFiles(Root / dir / "*.json"):
        checkpoint path
        agree(readFile(path))

  test "mutations":
    var rng = initRand(0x7EA)
    var seeds: seq[string] = @[list(standardRow & "," & standardRow),
      list(statusRow & "," & statusRow, ",\"tags\":{\"a\":[1,\"\\u0041\"]},\"keywords\":[\"k\"]")]
    for path in walkFiles(Root / "tests/fuzz/corpus" / "*.json"):
      seeds.add readFile(path)
    const Alphabet = "{}[],:\"\\ -+.0123456789eEtrufalsnxu/\t\n\x01\xff\xc3\xa9"
    let limits = ParseLimits(maxBytes: 4096, maxDepth: 6, maxArrayItems: 16,
      maxObjectMembers: 12, maxStringBytes: 48, maxRows: 1 shl 30)
    for round in 0 ..< 30_000:
      var body = seeds[rng.rand(seeds.high)]
      for _ in 0 .. rng.rand(3):
        let at = rng.rand(body.len)
        case rng.rand(2)
        of 0: body.insert($Alphabet[rng.rand(Alphabet.high)], at)
        of 1:
          if at < body.len: body.delete(at .. at)
        else:
          if at < body.len: body[at] = Alphabet[rng.rand(Alphabet.high)]
      agree(body, if round mod 2 == 0: DefaultParseLimits else: limits)
