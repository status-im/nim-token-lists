## Copy and retention contracts, measured with a counting allocator. Bodies are
## runtime strings: literals are shared and would hide copies.
import std/[os, strutils, unittest]
import ../memory/counting
import ../../tokenlists/core/validators
import ../../tokenlists/core/parsers/standard

const Padding = 1 shl 20

proc fixture(name: string): string =
  readFile(currentSourcePath.parentDir / ".." / ".." / "fixtures" / "embedded" / name)

proc padded(body: string): string =
  ## Same document with inner whitespace: equal parse results, larger input.
  doAssert body[0] == '{'
  "{" & ' '.repeat(Padding) & body[1 .. ^1]

suite "body copies":
  test "decoding reads the input in place":
    let body = fixture("uniswap.json")
    let large = padded(body)
    let plain = measure:
      discard decodeStandardSource(body, "uniswap").get
    let grown = measure:
      discard decodeStandardSource(large, "uniswap").get
    check grown.churn - plain.churn < Padding div 8

  test "validation copies no more than the decoded metadata":
    let body = fixture("uniswap.json")
    let named = body.replace("\"name\": \"Uniswap Labs Default\"",
      "\"name\":\"" & 'n'.repeat(Padding div 4) & "\"")
    doAssert named.len > body.len
    let plain = measure:
      check validateDocument(body, StandardFormat, "uniswap").isOk
    let grown = measure:
      check validateDocument(named, StandardFormat, "uniswap").isOk
    # Decoding the name itself grows a string (~4.5x); a document copy adds ~8x.
    check grown.churn - plain.churn < 2 * Padding
