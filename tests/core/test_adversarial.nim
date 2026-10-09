## Hostile list shapes cost work linear in their size. Work is counted as
## table probes and sort comparisons (-d:tklCountProbes), not timed.
import std/[strutils, unittest]
import tokenlists/api
import ../../tokenlists/core/[types, store, hashing]
import ../../tokenlists/core/parsers/stream
import ../oracle/legacy

func inverse(odd: uint64): uint64 =
  result = odd
  for _ in 0 ..< 6:
    result *= 2'u64 - odd * result

func unshift(value: uint64, shift: int): uint64 =
  result = value
  var bits = shift
  while bits < 64:
    result = value xor (result shr shift)
    bits += shift

func unmix64(hash: uint64): uint64 =
  result = unshift(hash, 31) * inverse(0x94D049BB133111EB'u64)
  result = unshift(result, 27) * inverse(0xBF58476D1CE4E5B9'u64)
  result = unshift(result, 30)

proc colliding(count: int, mask: uint64, hash: proc(text: string): uint64): seq[string] =
  ## Texts whose hash under a known seed lands in slot 0 of every table up to
  ## `mask`, as a list author who knew the seed could write them.
  var index = 0
  while result.len < count:
    let text = "k" & $index
    if (hash(text) and mask) == 0:
      result.add text
    inc index

const Known = 0'u64
  ## The seed an attacker assumes; the process seed differs.

proc statusList(rows, contracts: int, descending: bool): string =
  result = """{"name":"L","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":["""
  for row in 0 ..< rows:
    if row > 0: result.add ','
    result.add """{"crossChainId":"c","name":"N","symbol":"S","decimals":6,"contracts":{"""
    for index in 0 ..< contracts:
      if index > 0: result.add ','
      let chain = if descending: contracts - index else: index + 1
      result.add "\"" & $chain & "\":\"0x" & toHex(row * contracts + index, 40) & "\""
    result.add "}}"
  result.add "]}"

const limits = ParseLimits(maxBytes: 64 shl 20, maxDepth: 32,
  maxArrayItems: 1 shl 20, maxObjectMembers: 1 shl 20, maxStringBytes: 1 shl 20,
  maxRows: 1 shl 20)

proc work(body: string, rows: var int): int =
  var store = initTokenStore()
  probes = 0
  let parsed = parseList(store, body, StatusFormat, "src", limits, false)
  doAssert parsed.isOk, $parsed.error
  rows = parsed.get.rows.len
  probes

suite "adversarial list shapes":
  test "contracts per row cost linear work in their count":
    const Contracts = 4096
    for descending in [false, true]:
      var rows: int
      let ops = work(statusList(2, Contracts, descending), rows)
      check rows == 2 * Contracts
      checkpoint "descending " & $descending & ": " & $ops & " ops"
      # Sorting is n log n comparisons; duplicate checks a few probes each.
      check ops < 2 * Contracts * 24

  test "a duplicate among many contracts faults like the decoder":
    for at in [3, 40, 99]:
      let body = statusList(1, 100, false).replace("\"" & $(at + 1) & "\":", "\"007\":")
      for validate in [false, true]:
        var fresh, old = initTokenStore()
        let actual = parseList(fresh, body, StatusFormat, "src", limits, validate)
        let expected = if validate: legacyRefreshParse(old, body, StatusFormat, "src", limits)
          else: legacyParse(old, body, StatusFormat, "src", limits)
        check actual.isErr == expected.isErr
        if actual.isErr and expected.isErr:
          check actual.error == expected.error
          check "DuplicateContractChainId" in $actual.error
        elif actual.isOk and expected.isOk:
          check actual.get.rows.len == expected.get.rows.len

  test "distinct chain ids cost no more per row than one chain":
    const Rows = 40_000
    proc work(spread: bool, shift = 0): int =
      var store = initTokenStore()
      probes = 0
      for index in 0 ..< Rows:
        let chain = if spread: uint64(index) shl shift else: 1'u64
        discard store.addToken(chain, "0x" & toHex(index, 40), 6, "N", "S", "", "")
      check store.chainIds.len == (if spread: Rows else: 1)
      probes
    let single = work(false)
    # Low and high id bits: neither may cluster the chain table.
    for shift in [0, 32]:
      let many = work(true, shift)
      checkpoint "one chain " & $single & ", distinct << " & $shift & " " & $many
      check many < single + 4 * Rows

  test "chain ids crafted for a known seed spread over the chain table":
    const Count = 20_000
    var store = initTokenStore()
    probes = 0
    for index in 0 ..< Count:
      let chainId = unmix64(uint64(index) shl 20) xor Known
      doAssert (hashChain(chainId, Known) and 0xFFFFF) == 0
      discard store.addToken(chainId, "0x" & toHex(index, 40), 6, "N", "S", "", "")
    check store.chainIds.len == Count
    check probes < 8 * Count

  test "texts crafted for a known seed spread over the text table":
    const Count = 1000
    let names = colliding(Count, 4095, proc(text: string): uint64 = hashText(text, Known))
    var store = initTokenStore()
    probes = 0
    for index, name in names:
      discard store.addToken(1, "0x" & toHex(index, 40), 6, name, "S", "", "")
    check store.len == Count
    check probes < 8 * Count

  test "records crafted for a known seed spread over the record table":
    const Count = 600
    var store = initTokenStore()
    discard store.addToken(1, "0x" & toHex(0, 40), 6, "N", "S", "", "")
    var record = store.record(0)
    var addresses: seq[string]
    var candidate = 1
    while addresses.len < Count:
      let text = "0x" & toHex(candidate, 40)
      doAssert parseAddress(text, record.address)
      if (hashRecord(record, Known) and 2047) == 0:
        addresses.add text
      inc candidate
    probes = 0
    for address in addresses:
      discard store.addToken(1, address, 6, "N", "S", "", "")
    check store.len == Count + 1
    check probes < 8 * Count

  test "object keys crafted for a known seed spread over the key table":
    const Count = 1000
    let keys = colliding(Count, 4095, proc(text: string): uint64 = keyHash(text, Known))
    var body = """{"name":"L","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":[{"chainId":1,"address":"0x0000000000000000000000000000000000000001","name":"N","symbol":"S","decimals":6"""
    for key in keys:
      body.add ",\"" & key & "\":0"
    body.add "}]}"
    var store = initTokenStore()
    probes = 0
    let parsed = parseList(store, body, StandardFormat, "src", limits, false)
    check parsed.isOk
    check probes < 8 * Count

  test "rows a list expands to are capped":
    # The largest bundled list has 4765 rows.
    check DefaultParseLimits.maxRows >= 20 * 4765
    let body = statusList(2, 100, false)
    var capped = limits
    for (maxRows, expected) in [(199, false), (200, true)]:
      capped.maxRows = maxRows
      for validate in [false, true]:
        var store = initTokenStore()
        let parsed = parseList(store, body, StatusFormat, "src", capped, validate)
        check parsed.isOk == expected
        if not expected:
          check parsed.error.detail == "TooLarge"
      check validateList(body, StatusFormat, "src", capped).isOk == expected

  test "skipped keys and aliases cost a search per token":
    const Count = 10_000
    var body = """{"name":"L","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":["""
    var policy = CataloguePolicy()
    for index in 0 ..< Count:
      let address = "0x" & toHex(index + 1, 40)
      if index > 0: body.add ','
      body.add """{"chainId":1,"address":"""" & address & """","name":"N","symbol":"S","decimals":6}"""
      if index mod 2 == 0:
        policy.skippedKeys.add "1-" & address.toLowerAscii
        policy.skippedKeys.add "2-" & address.toLowerAscii
      elif index mod 3 == 0:
        policy.nativeAliases.add TokenIdentity(chainId: 1, address: address)
    body.add "]}"
    let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
      initialLists: @[ListContent(id: "main")])
    var catalogue = initCatalogue(config,
      [SourceBody(id: "main", origin: BundledBody, body: body)]).get
    probes = 0
    discard catalogue.setPolicy(policy).get
    check probes < 40 * Count
    check catalogue.getAll().get.total == Count div 2 + 1
    check catalogue.getByKey("1-0x" & toHex(1, 40).toLowerAscii).isErr
    check catalogue.getByKey("1-0x" & toHex(4, 40).toLowerAscii).get.address ==
      NativeAddress
