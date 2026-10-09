## Store size guards, reached with small limits (test_store_limits.nims).
import std/unittest
import ../../tokenlists/core/store

suite "store size guards":
  test "record indices stay below the snapshot's extra-store bit":
    var store = initTokenStore()
    for index in 0 ..< MaxRecords:
      discard store.addToken(1, "", uint64(index), "", "", "", "")
    expect AssertionDefect:
      discard store.addToken(1, "", 999, "", "", "", "")

  test "text offsets stay within 32 bits":
    var store = initTokenStore()
    discard store.intern("0123456789")
    expect AssertionDefect:
      discard store.intern("abcdefghijklmnopqrstuvwxyz")
