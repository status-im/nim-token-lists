import ../../tokenlists/core/[jsoncodec, validators]

type
  Record = object
    name: string
    values: seq[string]
    required: int
  OptionalRecord = object
    keywords: Opt[seq[string]]
    nested: Opt[Record]

# Exercise errors after managed fields have already been populated. Sanitizers
# must see those fields released even when the reader never returns a value.
for body in [
    """{"name":"allocated string","values":["first","second"]}""",
    """{"name":"allocated string","values":["first","second"],"required":"bad"}"""]:
  doAssert decodeDocument(body, Record, requireFields = true).isErr

const registrySeed = staticRead("../fuzz/corpus/registry.json")
doAssert validateDocument(registrySeed, RegistryFormat).isOk
doAssert validateDocument(registrySeed, StandardFormat).isErr
doAssert validateDocument(registrySeed, StatusFormat).isErr

const invalidKeywords = staticRead("../fuzz/corpus/invalid-keywords.json")
for format in [StandardFormat, StatusFormat]:
  doAssert validateDocument(invalidKeywords, format).isErr
for body in [
    """{"keywords":["allocated",{}]}""",
    """{"nested":{"name":"allocated","values":["one"],"required":"bad"}}"""]:
  doAssert decodeDocument(body, OptionalRecord).isErr
doAssert decodeDocument("{}", OptionalRecord).get.keywords.isNone
doAssert decodeDocument("""{"keywords":null}""", OptionalRecord).get.keywords.isNone
doAssert decodeDocument("""{"keywords":[]}""", OptionalRecord).get.keywords.get.len == 0
doAssert decodeDocument("""{"keywords":["one"]}""", OptionalRecord).get.keywords.get == @["one"]
GC_fullCollect()
