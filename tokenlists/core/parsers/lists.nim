{.push raises: [], gcsafe.}

import ./stream
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
  if format == RegistryFormat:
    return err(tklError(UnsupportedSchema, "RegistryIsNotTokenList", sourceId))
  parseList(store, body, format, sourceId, limits)

proc fetchedListBody*(
    body: openArray[char], format: ListFormat, sourceId: string,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## Validates and parses a fetched body in one pass into its own store.
  doAssert format != RegistryFormat
  when defined(tklCountParses):
    inc parsedContents
  ownStore(parseList(target, body, format, sourceId, limits, validate = true))
