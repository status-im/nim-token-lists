import std/unittest
import ../../tokenlists/core/[types, errors, keys]

suite "production keys":
  test "uint64 decimal boundaries":
    check parseChainId("0").get == 0'u64
    check parseChainId("18446744073709551615").get == high(uint64)
    for invalid in ["", "-1", "+1", " 1", "1 ", "1x", "18446744073709551616"]:
      check parseChainId(invalid).isErr

  test "canonical address and identity":
    let address = "0XAbCdEf0000000000000000000000000000000001"
    check normalizeAddress(address).get == "0xabcdef0000000000000000000000000000000001"
    let key = tokenKey(high(uint64), address).get
    let parsed = parseKey(key).get
    check parsed.chainId == high(uint64)
    check parsed.address == normalizeAddress(address).get
    check tokenKey(1, NativeAddress).get == "1-" & NativeAddress
    for bad in ["0x1", "", "0xgggggggggggggggggggggggggggggggggggggggg",
                "1", "1-" & NativeAddress & "-tail"]:
      check parseKey(bad).isErr
    check normalizeAddress("abcdef0000000000000000000000000000000001").get ==
      "0xabcdef0000000000000000000000000000000001"

  test "custom validation is intentionally stricter than list validation":
    var t = Token(chainId: 1, address: NativeAddress, symbol: "ETH", decimals: 18)
    check validateCustom(t, [1'u64]).isOk
    check validateCustom(t, [10'u64]).error.code == UnsupportedChain
    check validateCustom(t, []).isOk
    t.symbol = ""
    check validateCustom(t, []).error.detail == "EmptySymbol"
    t.symbol = "X"
    t.decimals = 19
    check validateCustom(t, []).error.detail == "DecimalsTooLarge"
    t.decimals = 18
    t.address = "bad"
    check validateCustom(t, []).error.detail == "BadAddress"
