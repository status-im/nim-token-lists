import ../../tokenlists/core/[jsoncodec, validators]

type
  Record = object
    name: string
    values: seq[string]
    required: int

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
GC_fullCollect()
