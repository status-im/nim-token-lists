{.push raises: [], gcsafe.}

import ./[common, standard, status]
export common

type
  ParsedContent* = object
    ## A list parsed from a borrowed body, with the metadata it was fetched under.
    meta*: ListContent
    source*: ParsedSource
    bodyLen*: int

when defined(tklCountParses):
  # Test-only probe: list documents decoded by loads and refreshes.
  var parsedContents* {.threadvar.}: int

proc parseListBody*(
    store: var TokenStore, body: openArray[char], format: ListFormat,
    sourceId: string, limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## Parses into `store`; a failed parse may leave unreferenced rows there.
  when defined(tklCountParses):
    inc parsedContents
  if body.len == 0:
    return err(tklError(InvalidContent, "EmptyListContent", sourceId))
  case format
  of StandardFormat: decodeStandardSource(store, body, sourceId, limits)
  of StatusFormat: decodeStatusSource(store, body, sourceId, limits)
  of RegistryFormat:
    err(tklError(UnsupportedSchema, "RegistryIsNotTokenList", sourceId))

proc parseListBody*(
    body: openArray[char], format: ListFormat, sourceId: string,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  ownStore(parseListBody(target, body, format, sourceId, limits))
