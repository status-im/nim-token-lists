{.push raises: [], gcsafe.}

import std/strutils
import ./[types, errors]
export types, errors

func parseChainId*(text: string): Result[uint64, TklError] =
  if text.len == 0:
    return err(tklError(InvalidArgument, "EmptyChainId"))
  var value = 0'u64
  for ch in text:
    if ch notin {'0'..'9'}:
      return err(tklError(InvalidArgument, "BadChainId"))
    let digit = uint64(ord(ch) - ord('0'))
    if value > (high(uint64) - digit) div 10:
      return err(tklError(InvalidArgument, "ChainIdOverflow"))
    value = value * 10 + digit
  ok(value)

func normalizeAddress*(text: string): Result[string, TklError] =
  ## Match SDK IsHexAddress: optional any-case 0x prefix; exactly 20 bytes.
  let start =
    if text.len == 42 and text[0] == '0' and text[1] in {'x', 'X'}: 2
    else: 0
  if text.len - start != 40:
    return err(tklError(InvalidArgument, "BadAddress"))
  for i in start ..< text.len:
    if text[i] notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return err(tklError(InvalidArgument, "BadAddress"))
  ok("0x" & text[start ..< text.len].toLowerAscii())

func tokenKey*(chainId: uint64, address: string): Result[string, TklError] =
  let normalized = ?normalizeAddress(address)
  ok($chainId & "-" & normalized)

func parseKey*(text: string): Result[TokenIdentity, TklError] =
  let separator = text.find('-')
  if separator <= 0 or separator == text.high:
    return err(tklError(InvalidArgument, "BadKey"))
  let chainId = ?parseChainId(text[0 ..< separator])
  let address = ?normalizeAddress(text[separator + 1 ..< text.len])
  ok(TokenIdentity(chainId: chainId, address: address))

func isNative*(token: Token): bool =
  token.address == NativeAddress

func validateCustom*(
    token: Token, supportedChains: openArray[uint64]
): Result[void, TklError] =
  if supportedChains.len > 0 and token.chainId notin supportedChains:
    return err(tklError(UnsupportedChain, "UnsupportedChain"))
  if normalizeAddress(token.address).isErr:
    return err(tklError(ValidationFailed, "BadAddress"))
  if token.symbol.len == 0:
    return err(tklError(ValidationFailed, "EmptySymbol"))
  if token.decimals > 18:
    return err(tklError(ValidationFailed, "DecimalsTooLarge"))
  ok()
