import unittest
import vine

suite "vine":
  test "hello returns expected greeting":
    check hello() == "hello from vine"

  test "version present":
    check projectVersion == "0.0.1"
