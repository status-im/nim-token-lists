{.push raises: [], gcsafe.}

import json_serialization/types
import ./errors
export errors, types

type
  TokenIdentity* = object
    chainId*: uint64
    address*: string

  Token* = object
    chainId*: uint64
    address*: string
    crossChainId*: string
    decimals*: uint8
    name*: string
    symbol*: string
    logoUri*: string
    custom*: bool

  Version* = object
    major*: int64
    minor*: int64
    patch*: int64

  TokenList* = object
    id*: string
    name*: string
    timestamp*: string
    fetchedTimestamp*: string
    source*: string
    version*: Version
    tags*: JsonString
    logoUri*: string
    keywords*: seq[string]
    tokens*: seq[Token]

  RowDiagnostic* = object
    error*: TklError
    row*: int
    chainId*: uint64

  ParsedList* = object
    list*: TokenList
    diagnostics*: seq[RowDiagnostic]

  ListFormat* = enum
    StandardFormat, StatusFormat, RegistryFormat

  ListSource* = object
    id*: string
    sourceUrl*: string
    schema*: string

  Registry* = object
    timestamp*: string
    version*: Version
    tokenLists*: seq[ListSource]

  ParseLimits* = object
    maxBytes*: int
    maxDepth*: int
    maxArrayItems*: int
    maxObjectMembers*: int
    maxStringBytes*: int

  PriorityPolicy* = enum
    StatusPriority, CustomFirstPriority

  CataloguePolicy* = object
    priority*: PriorityPolicy
    skippedKeys*: seq[string]
    nativeAliases*: seq[TokenIdentity]
    nativeTokens*: seq[Token]

  ListContent* = object
    id*: string
    format*: ListFormat
    body*: string
    source*: string
    fetchedTimestamp*: string
    etag*: string
    fetchedAt*: int64
    failure*: TklError

  CatalogueConfig* = object
    chains*: seq[uint64]
    mainListId*: string
    registryId*: string
    registryUrl*: string
    embeddedRegistry*: string
    initialLists*: seq[ListContent]
    policy*: CataloguePolicy

  Page*[T] = object
    revision*: uint64
    total*: int
    items*: seq[T]

const
  NativeAddress* = "0x0000000000000000000000000000000000000000"
  DefaultParseLimits* = ParseLimits(
    maxBytes: 16 * 1024 * 1024,
    maxDepth: 64,
    maxArrayItems: 100_000,
    maxObjectMembers: 4096,
    maxStringBytes: 1024 * 1024,
  )
