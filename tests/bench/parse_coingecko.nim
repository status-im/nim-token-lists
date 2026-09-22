import std/[algorithm, monotimes, strformat, times]
import ../../tokenlists/core/parsers/standard

const
  body = staticRead("../../fixtures/embedded/coingecko_ethereum.json")
  iterations = 30

proc parseFixture(): int =
  let parsed = parseStandard(body, [1'u64], "coingecko_ethereum")
  doAssert parsed.isOk
  doAssert parsed.get.list.tokens.len == 4765
  doAssert parsed.get.diagnostics.len == 0
  parsed.get.list.tokens.len

# Input is loaded before timing. Include the complete parse and result cleanup,
# with uniqueness checks enabled, and consume the output on every iteration.
discard parseFixture()
var samples: seq[float64]
var totalTokens = 0
for iteration in 0 ..< iterations:
  let started = getMonoTime()
  totalTokens += parseFixture()
  samples.add float64((getMonoTime() - started).inNanoseconds) / 1_000_000
samples.sort()
let median = (samples[iterations div 2 - 1] + samples[iterations div 2]) / 2
echo &"CoinGecko Ethereum: {body.len} bytes, 4765 tokens, {iterations} parses"
echo &"parse ms: min={samples[0]:.3f}, median={median:.3f}, max={samples[^1]:.3f}"
echo &"Consumed tokens: {totalTokens}"
