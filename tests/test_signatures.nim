
import json
import os
import unittest
import signatures

import sequtils

let
  # Temporary test keys
  # gpg --batch -quick-random --passphrase '' --quick-gen-key 'Nim Test'
  key1 = getEnv("K1")
  key2 = getEnv("K2")
  key3 = getEnv("K3")

doAssert key1.len == 18
doAssert key2.len == 18
doAssert key3.len == 18

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

let sig = generate_gpg_signature(j, key1)
#let sig2 = generate_gpg_signature(j, key2)

suite "gpg":

  test "verify":
    echo verify_gpg_signature(j, sig)

  test "verify allowed":
    discard verify_gpg_signature_is_allowed(j, sig, @[key1])

  test "verify not allowed":
    expect Exception:
      discard verify_gpg_signature_is_allowed(j, sig, @["0x6F31BC44F51QQQQQ"])

  test "verify fails on incorrect signature":
    #FIXME
    if false:
      var j2 = %* {"name": "Foo", "books": ["Robot Dreams"]}
      echo verify_gpg_signature(j2, sig)
      expect Exception:
        echo verify_gpg_signature(j2, sig)

  test "embed_gpg_signature twice":
    let n = copy(j)
    n.embed_gpg_signature(key1)
    assert n["signatures"].len == 1
    n.embed_gpg_signature(key2)
    assert n["signatures"].len == 2

  test "verify_enough_allowed_gpg_signatures":
    let n = copy(j)
    n.embed_gpg_signature(key1)
    n.verify_enough_allowed_gpg_signatures(@[key1], 1)
    expect Exception:
      n.verify_enough_allowed_gpg_signatures(@[key1], 2)
      n.verify_enough_allowed_gpg_signatures(@[key2], 1)
    n.embed_gpg_signature(key2)
    n.verify_enough_allowed_gpg_signatures(@[key1], 1)
    n.verify_enough_allowed_gpg_signatures(@[key2], 1)
    n.verify_enough_allowed_gpg_signatures(@[key1, key2], 2)
    expect Exception:
      n.verify_enough_allowed_gpg_signatures(@[key1, key2], 3)

suite "dload":
#  test "retr":
#    let url = "https://raw.githubusercontent.com/nim-lang/packages/master/.travis.yml"
#
#    download_file(url, "/tmp/pj", check_modified_time=false)
#    download_file(url, "/tmp/pj")

  test "full dev package install":
    if false:
      let rfn = "/tmp/roster.json"
      echo download_file(
        "https://raw.githubusercontent.com/nim-lang/packages/master/.travis.yml"
        , rfn)
      let roster = load_and_verify_roster("roster.json") # local copy

      echo download_file(
        "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json",
        "/tmp/packages.json")

  test "the whole story":
    let
      core_key = key1
      trusted_key = key2
      owner_key = key3
    # Create a roster, signed by a core dev
    block create_roster:
      let roster = %* {
        "signatures": newJArray(),
        "trusted_keys": [trusted_key.newJString, ]
      }
      roster.embed_gpg_signature(core_key)
      writeFile("/tmp/sigtest/remote_roster.json", $roster)

    block create_packages_json:
      let pkgs = parseJson("""
[
  {
    "name": "argument_parser",
    "url": "https://github.com/Xe/argument_parser/",
    "method": "git",
    "tags": [
      "library",
      "commandline",
      "arguments",
      "switches",
      "parsing"
    ],
    "description": "Provides a complex commandline parser",
    "license": "MIT",
    "web": "https://github.com/Xe/argument_parser"
  },
] """)
      # sign the first entry using the owner key
      pkgs[0]["owner_keys"] = newJArray()
      pkgs[0]["owner_keys"].add owner_key.newJString
      pkgs[0].embed_gpg_signature(owner_key)
      # sign the whole file
      #pkgs.embed_gpg_signature(trusted_key)
      writeFile("/tmp/sigtest/packages.json", $pkgs)

    # a local HTTP server should serve the roster
    # Download the roster
    block download_and_verify_roster:
      assert download_file("http://127.0.0.1:8000/remote_roster.json",
        "/tmp/sigtest/roster.json")
      let roster = load_and_verify_roster(
        fname="/tmp/sigtest/roster.json",
        accepted_keys = @[core_key],
        required_sigs_num=1
      )

    block download_packages_json:
      assert download_file("http://127.0.0.1:8000/packages.json",
        "/tmp/sigtest/packages.json")

    block verify_package_metadata:
      let pkgs = "/tmp/sigtest/packages.json".readFile.parseJson()
      let pkg = pkgs[0]
      #FIXME pkg.verify_package_metadata()

    #TODO git fetch and check git tag signature




