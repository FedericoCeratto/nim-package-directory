
import unittest
import tables

import package_directory

suite "test pkgs":
  test "search":
    load_packages()
    let ct = search_packages("high level game, little math")
    assert ct.len == 31
    assert ct.largest[0] == "linagl", $ct.largest

