import std/[unittest, strutils]
import ../../tokenlists/core/[types, errors]
import ../../tokenlists/core/parsers/[standard, status]
import ../../tokenlists/core/parsers/registry

const a = "0x000000000000000000000000000000000000000a"
func row(chain = "1", decimals = "18", address = a, symbol = ""): string =
  """{"chainId":""" & chain & ""","address":"""" & address &
    """","symbol":"""" & symbol & """","decimals":""" & decimals & "}"
func wrap(rows: string): string = """{"tokens":[""" & rows & "]}"

suite "bounded token parsers":
  test "version metadata preserves signed SDK integers":
    for value in ["-9223372036854775808", "-1", "0", "9223372036854775807"]:
      let body = "{\"version\":{\"major\":" & value &
        ",\"minor\":" & value & ",\"patch\":" & value & "}}"
      let parsed = parseStandard(body, [])
      check parsed.isOk
      if parsed.isErr:
        continue
      let standard = parsed.get.list.version
      check $standard.major == value
      check $standard.minor == value
      check $standard.patch == value
      check parseStatus(body, []).get.list.version == standard
      check parseRegistry(body).get.version == standard
    for value in ["-9223372036854775809", "9223372036854775808", "1e1", "-1e1", "1.0"]:
      let body = "{\"version\":{\"major\":" & value & "}}"
      check parseStandard(body, []).isErr
      check parseStatus(body, []).isErr
      check parseRegistry(body).isErr

  test "standard metadata and document order survive":
    let parsed = parseStandard("""{"name":"Example","timestamp":"2025-01-01T00:00:00Z",
      "version":{"major":1,"minor":2,"patch":3},"tags":{"stable":{"name":"Stable"}},
      "keywords":["x"],"logoURI":"https://example.com/logo.png","tokens":[""" &
      row(symbol = "A") & "," & row(symbol = "B") & "]}", [1'u64], "source").get
    check parsed.list.id == "source"
    check parsed.list.name == "Example"
    check parsed.list.version.minor == 2
    check parsed.list.keywords == @["x"]
    check parsed.list.logoUri == "https://example.com/logo.png"
    check string(parsed.list.tags).contains("Stable")
    check parsed.list.tokens.len == 2
    check parsed.list.tokens[0].symbol == "A"
    check parsed.list.tokens[1].symbol == "B"
    check parsed.list.tokens[0].crossChainId == ""
    check not parsed.list.tokens[0].custom
    check parsed.diagnostics.len == 0
    check parseStandard("{}", [1'u64]).get.list.tokens.len == 0

  test "full uint64 and decimal bounds do not narrow unsafely":
    let parsed = parseStandard(wrap(row(chain = $high(uint64), decimals = "255")),
      [high(uint64)]).get
    check parsed.list.tokens[0].chainId == high(uint64)
    check parsed.list.tokens[0].decimals == 255
    check parsed.list.tokens[0].symbol == ""
    for value in ["18446744073709551616", "-1", "1.5", "1e1", "+1"]:
      checkpoint value
      check parseStandard(wrap(row(chain = value)), [1'u64]).isErr
    let dropped = parseStandard(wrap(row(decimals = "256")), [1'u64], "src").get
    check dropped.list.tokens.len == 0
    check dropped.diagnostics[0].error.detail == "DecimalsTooLarge"
    check dropped.diagnostics[0].error.sourceId == "src"
    check dropped.diagnostics[0].row == 0

  test "bad address and unsupported chain are row diagnostics":
    let parsed = parseStandard(wrap(row(address = "no") & "," & row(chain = "10") &
      "," & row()), [1'u64]).get
    check parsed.list.tokens.len == 1
    check parsed.diagnostics.len == 2
    check parsed.diagnostics[0].error.detail == "BadAddress"
    check parsed.diagnostics[1].error.code == UnsupportedChain
    check parseStandard(wrap(row()), []).get.list.tokens.len == 0

  test "Status contracts sort numerically within document order":
    let body = """{"tokens":[{"crossChainId":"group","name":"Name","symbol":"X",
      "logoURI":"ipfs://logo","decimals":6,"contracts":{"10":"""" & a &
      """","2":"""" & a & """","1":"""" & a & """"}},
      {"crossChainId":"next","contracts":{"1":"""" & a & """"}}]}"""
    let parsed = parseStatus(body, [1'u64, 2, 10]).get
    check parsed.list.tokens.len == 4
    check parsed.list.tokens[0].chainId == 1
    check parsed.list.tokens[1].chainId == 2
    check parsed.list.tokens[2].chainId == 10
    check parsed.list.tokens[0].crossChainId == "group"
    check parsed.list.tokens[0].logoUri == "ipfs://logo"
    check parsed.list.tokens[3].crossChainId == "next"
    check parseStatus(body, [1'u64, 2, 10]).get == parsed
    for key in ["bad", "-1", "18446744073709551616"]:
      check parseStatus("""{"tokens":[{"contracts":{"""" & key & """":"""" &
        a & """"}}]}""", [1'u64]).isErr
    check parseStatus("""{"tokens":[{"contracts":{"1":"""" & a &
      """","01":"""" & a & """"}}]}""", [1'u64]).isErr

  test "malformed, null and nonstandard JSON return InvalidArgument":
    for bad in ["", "null", "[]", "{", "{}{}", "{} trailing", "{/*x*/}",
                """{"tokens":[],}""", """{"tokens":null}""",
                """{"tokens":[null]}""", """{"tokens":[{"chainId":"1"}]}""",
                "{\"name\":\"\xff\"}", """{"name":"\uD800"}"""]:
      let parsed = parseStandard(bad, [1'u64], "bad-source")
      check parsed.isErr
      if parsed.isErr:
        check parsed.error.code == InvalidArgument
        check parsed.error.sourceId == "bad-source"

  test "finite byte depth collection and string limits":
    var limits = DefaultParseLimits
    limits.maxBytes = 2
    check parseStandard("{} ", [], limits = limits).isErr
    check parseStandard("{}", [], limits = limits).isOk
    limits = DefaultParseLimits
    limits.maxDepth = 2
    check parseStandard("""{"extension":{"a":{"b":1}}}""", [], limits = limits).isErr
    limits = DefaultParseLimits
    limits.maxArrayItems = 1
    check parseStandard(wrap(row() & "," & row()), [1'u64], limits = limits).isErr
    limits = DefaultParseLimits
    limits.maxObjectMembers = 1
    check parseStandard("""{"name":"x","timestamp":"y"}""", [], limits = limits).isErr
    limits = DefaultParseLimits
    limits.maxStringBytes = 3
    check parseStandard("""{"name":"long"}""", [], limits = limits).isErr
    limits.maxStringBytes = 0
    check parseStandard("{}", [], limits = limits).isErr

  test "tags retain the SDK object or null shape":
    for bad in ["1", "[]", "\"text\""]:
      let data = "{\"tags\":" & bad & "}"
      check parseStandard(data, []).isErr
      check parseStatus(data, []).isErr
    for valid in ["null", "{}", "{\"tag\":{\"name\":\"X\"}}"]:
      let data = "{\"tags\":" & valid & "}"
      check parseStandard(data, []).isOk
      check parseStatus(data, []).isOk

  test "duplicate object fields reject instead of concatenating arrays":
    for data in [
      "{\"tokens\":[" & row() & "],\"tokens\":[]}",
      "{\"keywords\":[\"a\"],\"keywords\":[]}",
      "{\"version\":{\"major\":1},\"version\":{\"minor\":2}}",
      "{\"extension\":{\"a\":1,\"a\":2}}",
      "{\"name\":\"a\",\"\\u006eame\":\"b\"}"
    ]:
      check parseStandard(data, [1'u64]).isErr
      check parseStatus(data, [1'u64]).isErr
