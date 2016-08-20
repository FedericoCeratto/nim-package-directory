import unittest
import json

import signatures

let j = %* {
    "books": @["Robot Dreams"],
    "name": "Isaac",
    "authorized_keys": @["1234"],
    "description": "blah",
    "license": "GPLv3",
    "method": "git",
    "name": "testfoo",
    "tags": @["foo", "bar"],
    "url": "https://uu",
    "web": "https://abc",
}
let sig = generate_gpg_signature(j, "o")

suite "gpg":

  test "verify":
    echo verify_gpg_signature(j, sig)

  test "verify allowed":
    discard verify_gpg_signature_is_allowed(j, sig, @["0x6F31BC44F5177DAA"])

  test "verify not allowed":
    expect Exception:
      discard verify_gpg_signature_is_allowed(j, sig, @["0x6F31BC44F51QQQQQ"])

  test "verify fails on incorrect signature":
    var j2 = %* {"name": "Foo", "books": ["Robot Dreams"]}
    expect Exception:
      echo verify_gpg_signature(j2, sig)

