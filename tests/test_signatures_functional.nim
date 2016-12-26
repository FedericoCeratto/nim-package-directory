#
# Nimble package directory - functional tests
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#
# WARNING: do not run functional tests on a live instance!

import httpclient
import json
import os
import osproc
import strutils, unittest

import signatures

from micron import sign_and_publish

# The package directory is running here
const pkgdir_url = "http://localhost:5000"

let test_pkg_chunk = %*  {
    "name": "pkg_dir_testpkg",
    "tags": [
      "test",
      "library",
    ],
    "method": "git",
    "license": "MIT",
    "web": "https://github.com/FedericoCeratto/nim-package-directory",
    "url": "https://github.com/FedericoCeratto/nim-package-directory",
    "description": "Test package",
    "downloads": """https://github.com/DonnchaC/onionbalance/releases .*/onionbalance-([\d\.]+).tar.gz""",
  }

let
  # Temporary test keys. Generating temporary keys on each run is too time-consuming.
  # Generate them externally with:
  # gpg --batch -quick-random --passphrase '' --quick-gen-key 'Nim Test'
  key1 = getEnv("K1")
  key2 = getEnv("K2")
  key3 = getEnv("K3")

doAssert key1.len == 18
doAssert key2.len == 18
doAssert key3.len == 18

suite "Micron functional test":

  test "end to end test":
    ## Test Micron and the Package Directory

    const
      test_dir = "/tmp/pacdir_test"

    # create test pgk, publish it on directory
    var metadata = test_pkg_chunk.copy()
    metadata["authorized_keys"] = newJArray()
    metadata["authorized_keys"].add newJString key1
    metadata["authorized_keys"].add newJString key2
    echo "Publishing package metadata..."
    sign_and_publish(pkgdir_url, metadata, key1)

    #   update packages, scan for package,
    #   fetch pkg and check validity
    let output = execProcess "./micron list-downloads $# pkg_dir_testpkg" % pkgdir_url
    echo output

    # Update nimble pkg metadata, push the update to directory
    #   update packages, scan for package,
    #   fetch pkg and check validity

    # Update nimble pkg metadata, push the update to directory
    # using wrong key, check for failure

    # Hijack pkg on directory, nimble-update packages and check for warning

    # Fetch binary release, check buildbot signatures






#
#




discard """
  nimble_bin = expandTilde "~/.nimble/bin/nimble"

# Configure Nimble to fetch from localhost:5000
putEnv("HOME", test_dir)
createDir(test_dir / ".config/nimble")
writeFile(test_dir / ".config/nimble/nimble.ini", ""
[PackageList]
name = "Official"
url = "http://localhost:5000/packages.json"
"")

assert existsFile nimble_bin
echo execProcess(nimble_bin & " update")
"""
