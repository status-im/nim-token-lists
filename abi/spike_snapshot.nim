{.push raises: [], gcsafe.}

import std/[json, options, strutils, tables]

type
  Token* = object
    chainId*: uint64
    address*: string ## lowercase 0x-hex, 42 chars
    symbol*: string
    decimals*: uint8

  Snapshot* = object
    tokens*: seq[Token]
    byKey*: Table[string, int]

func tokenKey*(chainId: uint64, address: string): string =
  $chainId & "-" & address.toLowerAscii()

func normalizeKey*(key: string): string =
  key.toLowerAscii()

proc buildSnapshot*(tokens: sink seq[Token]): Snapshot =
  ## First occurrence of a key wins (SDK parity, Part A §3.1).
  result.byKey = initTable[string, int]()
  for t in tokens:
    let k = tokenKey(t.chainId, t.address)
    if k notin result.byKey:
      result.byKey[k] = result.tokens.len
      result.tokens.add t

func lookup*(s: Snapshot, key: string): Option[Token] =
  let idx = s.byKey.getOrDefault(normalizeKey(key), -1)
  if idx < 0: none(Token) else: some(s.tokens[idx])

proc parseTokens*(data: string): Option[seq[Token]] =
  try:
    let node = parseJson(data)
    if node.kind != JArray:
      return none(seq[Token])
    var parsed = newSeqOfCap[Token](node.len)
    for n in node:
      if n.kind != JObject:
        return none(seq[Token])
      let chain = n{"chainId"}.getBiggestInt(-1)
      let address = n{"address"}.getStr()
      let decimals = n{"decimals"}.getBiggestInt(-1)
      if chain < 0 or address.len != 42 or decimals < 0 or decimals > 255:
        return none(seq[Token])
      parsed.add Token(
        chainId: uint64(chain),
        address: address.toLowerAscii(),
        symbol: n{"symbol"}.getStr(),
        decimals: uint8(decimals),
      )
    some(parsed)
  except CatchableError:
    none(seq[Token])

func toJson*(t: Token): string =
  "{\"chainId\":" & $t.chainId & ",\"address\":" & escapeJson(t.address) &
    ",\"symbol\":" & escapeJson(t.symbol) & ",\"decimals\":" & $t.decimals & "}"

func allToJson*(s: Snapshot): string =
  result = "["
  for i, t in s.tokens:
    if i > 0: result.add ','
    result.add toJson(t)
  result.add ']'
