{.push raises: [], gcsafe.}

## Compact JSON written straight into a caller's buffer. A sink without a
## buffer only measures, so output can be sized exactly before it is written.

type JsonSink* = object
  data: ptr UncheckedArray[char]
  capacity: int
  len*: int
    ## Bytes written, or that would be written when measuring.

const HexDigits = "0123456789abcdef"

func measuring*(): JsonSink = JsonSink()

func writing*(data: ptr UncheckedArray[char], capacity: int): JsonSink =
  ## Writes at most `capacity` bytes; overrunning is a defect.
  JsonSink(data: data, capacity: capacity)

proc add*(sink: var JsonSink, ch: char) {.inline.} =
  if not sink.data.isNil:
    doAssert sink.len < sink.capacity
    sink.data[sink.len] = ch
  inc sink.len

proc add*(sink: var JsonSink, text: openArray[char]) {.inline.} =
  if not sink.data.isNil and text.len > 0:
    doAssert sink.len + text.len <= sink.capacity
    copyMem(addr sink.data[sink.len], unsafeAddr text[0], text.len)
  sink.len += text.len

proc reserve*(sink: var JsonSink, count: int): ptr UncheckedArray[char] =
  ## Room for `count` bytes the caller fills, or nil when measuring.
  if not sink.data.isNil:
    doAssert sink.len + count <= sink.capacity
    result = cast[ptr UncheckedArray[char]](addr sink.data[sink.len])
  sink.len += count

proc addUint*(sink: var JsonSink, value: uint64) =
  var digits: array[20, char]
  var rest = value
  var count = 0
  while true:
    digits[digits.high - count] = char(ord('0') + int(rest mod 10))
    inc count
    rest = rest div 10
    if rest == 0:
      break
  sink.add digits.toOpenArray(digits.len - count, digits.high)

proc addInt*(sink: var JsonSink, value: int64) =
  if value < 0:
    sink.add '-'
    sink.addUint(not uint64(value) + 1)
  else:
    sink.addUint(uint64(value))

proc addEscaped*(sink: var JsonSink, text: openArray[char]) =
  ## String content as json_serialization writes it. Bytes 0x0f and 0x1f are
  ## written in full, where its writer indexes past its hex table.
  var run = 0
  for index, ch in text:
    if ch >= ' ' and ch != '"' and ch != '\\':
      continue
    sink.add text.toOpenArray(run, index - 1)
    run = index + 1
    case ch
    of '\b': sink.add "\\b"
    of '\t': sink.add "\\t"
    of '\n': sink.add "\\n"
    of '\f': sink.add "\\f"
    of '\r': sink.add "\\r"
    of '"': sink.add "\\\""
    of '\\': sink.add "\\\\"
    else:
      sink.add "\\u00"
      sink.add HexDigits[ord(ch) shr 4]
      sink.add HexDigits[ord(ch) and 15]
  sink.add text.toOpenArray(run, text.high)

proc addString*(sink: var JsonSink, text: openArray[char]) =
  sink.add '"'
  sink.addEscaped(text)
  sink.add '"'

