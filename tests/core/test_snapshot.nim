import std/[unittest, options]
import ../../tokenlists/core/snapshot

suite "snapshot":
  test "key is chainId-lowercase address":
    check tokenKey(1'u64, "0xAbCdEf0000000000000000000000000000000001") ==
      "1-0xabcdef0000000000000000000000000000000001"

  test "first occurrence wins and lookup is case-insensitive":
    let parsed = parseTokens("""[
      {"chainId":1,"address":"0xAbCdEf0000000000000000000000000000000001","symbol":"AAA","decimals":18},
      {"chainId":1,"address":"0xabcdef0000000000000000000000000000000001","symbol":"DUP","decimals":6},
      {"chainId":10,"address":"0x0000000000000000000000000000000000000000","symbol":"ETH","decimals":18}
    ]""")
    check parsed.isSome
    let snap = buildSnapshot(parsed.get)
    check snap.tokens.len == 2
    let hit = snap.lookup("1-0xABCDEF0000000000000000000000000000000001")
    check hit.isSome
    check hit.get.symbol == "AAA"
    check snap.lookup("1-0x00000000000000000000000000000000000000ff").isNone

  test "malformed input is rejected, never raises":
    check parseTokens("not json").isNone
    check parseTokens("""{"a":1}""").isNone
    check parseTokens("""[{"chainId":-1,"address":"0x00","symbol":"X","decimals":1}]""").isNone
    check parseTokens("""[{"chainId":1,"address":"0x0000000000000000000000000000000000000000","symbol":"X","decimals":300}]""").isNone

  test "json round trip":
    let snap = buildSnapshot(parseTokens(
      """[{"chainId":1,"address":"0x0000000000000000000000000000000000000000","symbol":"E\"TH","decimals":18}]""").get)
    let again = parseTokens(allToJson(snap))
    check again.isSome
    check again.get[0].symbol == "E\"TH"
