# SDK fixtures in fixtures/sdk originate from status-im/go-wallet-sdk commit
# 0d553d87d783: https://github.com/status-im/go-wallet-sdk/tree/0d553d87d783
# Their JSON content is preserved apart from trailing-whitespace normalization;
# tests substitute template values.
# This Source Code Form is subject to the terms of the Mozilla Public License,
# v. 2.0. A copy is available at https://mozilla.org/MPL/2.0/.

import std/[unittest, strutils, sequtils]
import ../../tokenlists/core/[types, keys, validators]
import ../../tokenlists/core/parsers/[standard, status, registry]

template fixture(path: static[string]): string =
  const content = staticRead(path)
  content

const chains = [1'u64, 10, 8453, 42161]

func listBody(rows: string): string =
  const body = fixture("../../fixtures/sdk/parsers/status_token_list_response_template.json")
  body
    .replace("NAME", "Fixture List")
    .replace("TIMESTAMP", "2025-09-01T00:00:00.000Z")
    .replace("MAJOR", "1").replace("MINOR", "2").replace("TOKENS", rows)

func registryBody(rows: string): string =
  const body = fixture("../../fixtures/sdk/fetcher/list_of_token_lists_response_template.json")
  body
    .replace("TIMESTAMP", "2025-09-01T00:00:00.000Z")
    .replace("MINOR", "2").replace("TOKEN_LISTS", rows)
    .replace("SERVER-URL", "https://example.com")

suite "ported SDK fixtures":
  test "standard fixture metadata and all token fields":
    let body = listBody(fixture("../../fixtures/sdk/parsers/uniswap_tokens_response.json"))
    let parsed = parseStandard(body, chains).get
    check parsed.list.name == "Fixture List"
    check parsed.list.timestamp == "2025-09-01T00:00:00.000Z"
    check parsed.list.version == Version(major: 1, minor: 2, patch: 0)
    check parsed.list.keywords == @["uniswap", "default"]
    check parsed.list.tokens.len == 5
    check parsed.list.tokens.mapIt(it.symbol) == @["1INCH", "SNT", "SNT", "SNT", "AAVE"]
    let token = parsed.list.tokens[1]
    check token.address == "0x744d70fdbe2ba4cf95131626614a1763df805b9e"
    check token.name == "Status"
    check token.chainId == 1
    check token.decimals == 18
    check token.logoUri.len > 0
    check token.crossChainId == ""
    check validateDocument(body, StandardFormat).isOk
    check parseStandard(body, chains).get == parsed

  test "Status golden identities have deterministic document then chain order":
    let body = listBody(fixture("../../fixtures/sdk/parsers/status_tokens_response.json"))
    let parsed = parseStatus(body, chains).get
    check parsed.list.tokens.len == 30
    let expected = fixture("../../fixtures/status-keys.txt").strip.splitLines
    check parsed.list.tokens.mapIt(tokenKey(it.chainId, it.address).get) == expected
    check parsed.list.tokens[0].crossChainId == "status"
    check parsed.list.tokens[0].name == "Status"
    check parsed.list.tokens[0].decimals == 18
    check parsed.list.tokens[4].crossChainId == "usd-coin"
    check parseStatus(body, chains).get == parsed
    check validateDocument(body, StatusFormat).isOk

  test "SDK invalid address fixtures drop rows rather than whole list":
    let standard = parseStandard(listBody(
      fixture("../../fixtures/sdk/parsers/uniswap_invalid_tokens_response.json")), chains).get
    let status = parseStatus(listBody(
      fixture("../../fixtures/sdk/parsers/status_invalid_tokens_response.json")), chains).get
    check standard.list.tokens.len == 1
    check standard.diagnostics.len == 1
    check standard.list.tokens[0].symbol == "SNT"
    check status.list.tokens.len == 1
    check status.diagnostics.len == 1
    check status.list.tokens[0].symbol == "SNT"

  test "fetcher content revisions preserve filtering and validation":
    const sources = [
      fixture("../../fixtures/sdk/fetcher/uniswap_tokens_response.json"),
      fixture("../../fixtures/sdk/fetcher/uniswap_tokens_response_1.json"),
      fixture("../../fixtures/sdk/fetcher/uniswap_tokens_response_2.json")
    ]
    for index, rows in sources:
      let body = listBody(rows)
      let parsed = parseStandard(body, chains).get
      check parsed.list.tokens.len == [1, 2, 8][index]
      check validateDocument(body, StandardFormat).isOk

  test "registry source additions retain order and IDs":
    const sources = [
      fixture("../../fixtures/sdk/fetcher/token_lists_response.json"),
      fixture("../../fixtures/sdk/fetcher/token_lists_response_1.json"),
      fixture("../../fixtures/sdk/fetcher/token_lists_response_2.json")
    ]
    for index, rows in sources:
      let body = registryBody(rows)
      let registry = parseRegistry(body).get
      check registry.tokenLists.len == index + 2
      check registry.tokenLists[0].id == "status"
      check registry.tokenLists[1].id == "uniswap"
      check registry.version.minor == 2
      check validateDocument(body, RegistryFormat).isOk
    let rows = fixture("../../fixtures/sdk/fetcher/list_of_token_lists_some_wrong_urls_response.json")
    # Both URLs are syntactically valid after substitution. Their server-side
    # 404 outcome belongs to the later refresh planner, not this pure validator.
    check validateDocument(registryBody(rows), RegistryFormat).isOk

  test "external schema document is never executable policy":
    let schema = fixture("../../fixtures/sdk/fetcher/list_of_token_lists_wrong_schema.json")
    check resolveFormat(schema, StandardFormat).error.code == UnsupportedSchema

  test "empty lists are usable documents":
    check parseStandard(listBody("[]"), chains).get.list.tokens.len == 0
    check parseStatus(listBody("[]"), chains).get.list.tokens.len == 0
    check validateDocument(listBody("[]"), StandardFormat).isOk

# Embedded fixtures are decoded from status-go ec8aed16562acc50ffda89165e508cc501064fb9,
# pkg/services/wallet/token/local-token-lists/default-lists/*.go (MPL-2.0).
# Only the final newline is normalized; see https://mozilla.org/MPL/2.0/.
suite "Status embedded lists":
  test "all shipped lists validate and preserve usable rows":
    const inputs = [
      ("status", StatusFormat, fixture("../../fixtures/embedded/status.json")),
      ("uniswap", StandardFormat, fixture("../../fixtures/embedded/uniswap.json")),
      ("coingecko_ethereum", StandardFormat,
        fixture("../../fixtures/embedded/coingecko_ethereum.json")),
      ("coingecko_arbitrum", StandardFormat,
        fixture("../../fixtures/embedded/coingecko_arbitrum.json")),
      ("coingecko_base", StandardFormat,
        fixture("../../fixtures/embedded/coingecko_base.json")),
      ("coingecko_bsc", StandardFormat,
        fixture("../../fixtures/embedded/coingecko_bsc.json")),
      ("coingecko_linea", StandardFormat,
        fixture("../../fixtures/embedded/coingecko_linea.json")),
      ("coingecko_optimism", StandardFormat,
        fixture("../../fixtures/embedded/coingecko_optimism.json"))
    ]
    const supported = [1'u64, 10, 56, 137, 324, 8453, 42161, 43114, 59144]
    for (id, format, body) in inputs:
      checkpoint id
      let validated = validateDocument(body, format, id)
      if validated.isErr:
        checkpoint validated.error.detail
      check validated.isOk
      let parsed = if format == StatusFormat:
        parseStatus(body, supported, id).get
      else:
        parseStandard(body, supported, id).get
      check parsed.list.tokens.len > 0
      if id == "coingecko_ethereum":
        check parsed.list.tokens.len == 4765
        check parsed.list.tokens.anyIt(it.symbol == "YEE\u00a0")
      if id == "status":
        check parsed.list.tokens.anyIt(it.logoUri == "")
      if id == "uniswap":
        check parsed.diagnostics.anyIt(it.error.detail == "BadAddress")
