import std/[unittest, strutils]
import ../../tokenlists/core/[types, errors, validators]
import ../../tokenlists/core/parsers/registry

const
  address = "0x0000000000000000000000000000000000000001"
  metadata = """"name":"Tokens","timestamp":"2025-01-01T00:00:00.123Z",
    "version":{"major":1,"minor":0,"patch":0}"""
  validRow = """{"chainId":1,"address":"""" & address &
    """","name":"Token","symbol":"","decimals":255}"""
  validList = "{" & metadata & ""","tokens":[""" & validRow & "]}"
  validRegistry = """{"timestamp":"2025-01-01T00:00:00Z",
    "version":{"major":1,"minor":0,"patch":0},
    "tokenLists":[{"id":"a","sourceUrl":"https://example.com/a","schema":null},
                  {"id":"b","sourceUrl":"https://example.com/b",
                   "schema":"https://unknown.example/schema"}]}"""

suite "registry and native validators":
  test "registry preserves metadata, order and opaque schema IDs":
    let registry = parseRegistry(validRegistry, "registry").get
    check registry.version.major == 1
    check registry.tokenLists.len == 2
    check registry.tokenLists[0].id == "a"
    check registry.tokenLists[0].schema == ""
    check registry.tokenLists[1].schema == "https://unknown.example/schema"
    check parseRegistry("{}").get.tokenLists.len == 0
    check parseRegistry("""{"tokenLists":[]}""").isOk
    for bad in ["null", "[]", "{", """{"tokenLists":null}""",
                """{"version":{"major":"x"}}"""]:
      check parseRegistry(bad).isErr

  test "format IDs never imply remote schema fetch":
    check resolveFormat("", StatusFormat).get == StatusFormat
    check resolveFormat("standard", StatusFormat).get == StandardFormat
    check resolveFormat("status", StandardFormat).get == StatusFormat
    check resolveFormat("registry", StandardFormat).get == RegistryFormat
    check resolveFormat("https://uniswap.org/tokenlist.schema.json",
      StatusFormat).get == StandardFormat
    check resolveFormat("https://example.com/schema",
      StandardFormat).error.code == UnsupportedSchema
    check resolveFormat("{}", StandardFormat).isErr

  test "native standard validation is distinct from permissive parsing":
    check validateDocument(validList, StandardFormat).isOk
    check validateDocument("{}", StandardFormat).error.code == InvalidContent
    check validateDocument("null", StandardFormat).isErr
    check validateDocument(validList.replace("\"decimals\":255", "\"decimals\":256"),
      StandardFormat).isErr
    check validateDocument(validList.replace("\"chainId\":1", "\"chainId\":0"),
      StandardFormat).isErr
    check validateDocument(validList.replace(address, "bad"), StandardFormat).isErr
    check validateDocument(validList.replace("\"name\":\"Token\",", ""),
      StandardFormat).isErr
    check validateDocument(validList.replace("2025-01-01", "2025-02-30"),
      StandardFormat).isErr
    check validateDocument(validList.replace("\"minor\":0", "\"minor\":-1"),
      StandardFormat).isErr
    check validateDocument(validList.replace("\"major\":1", "\"major\":1e1"),
      StandardFormat).isErr
    check validateDocument("{" & metadata & ""","tokens":[]}""",
      StandardFormat).isErr

  test "Status shape uses contracts and admits cross-chain grouping":
    let body = "{" & metadata & ""","tokens":[{"name":"X","symbol":"X",
      "decimals":18,"crossChainId":"group","contracts":{"1":"""" & address & """"}}]}"""
    check validateDocument(body, StatusFormat).isOk
    check validateDocument(body, StandardFormat).isErr
    check validateDocument(body.replace(address, "bad"), StatusFormat).isErr

  test "registry validates URLs, required metadata and duplicate IDs":
    check validateDocument(validRegistry, RegistryFormat).isOk
    for changed in [
      validRegistry.replace("https://example.com/a", "file:///tmp/token-list"),
      validRegistry.replace("https://example.com/a", "https://"),
      validRegistry.replace("https://example.com/a", "https://bad host/a"),
      validRegistry.replace("\"id\":\"b\"", "\"id\":\"a\""),
      validRegistry.replace("\"id\":\"a\"", "\"id\":\"\""),
      validRegistry.replace("2025-01-01T00:00:00Z", "not-a-date")
    ]:
      check validateDocument(changed, RegistryFormat).isErr
    check validateDocument("""{"tokenLists":[]}""", RegistryFormat).isErr
    check validateDocument("{", RegistryFormat).error.code == InvalidArgument

  test "typed errors carry the requested source":
    let failed = validateDocument("{}", StandardFormat, "uniswap")
    check failed.error.sourceId == "uniswap"
