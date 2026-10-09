## Hostile list shapes cost work linear in their size. Work is counted as
## table probes and sort comparisons (-d:tklCountProbes), not timed.
import std/[strutils, unittest]
import ../../tokenlists/core/[types, store, hashing]
import ../../tokenlists/core/parsers/stream
import ../oracle/legacy

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
  maxArrayItems: 1 shl 20, maxObjectMembers: 1 shl 20, maxStringBytes: 1 shl 20)

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
