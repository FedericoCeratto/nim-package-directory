#
# Nimble package directory - functional test
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#
# WARNING: do not run functional tests on a live instance!

# Functional-test every aspect of the package directory
# except signing

import httpclient
import json
import strutils, unittest

from os import existsEnv

if not existsEnv("NIMPKGDIR_ENABLE_FUNCTEST"):
  echo "Set NIMPKGDIR_ENABLE_FUNCTEST to enable functional tests"
  quit(1)

const url="http://localhost:5000"

proc get(url: string): string =
  echo "Fetching $#" % url
  return getContent(url)


#var node = %* {
#  "authorized_keys": @["0x6F31BC44F5177DAA"],
#  "description": "blah",
#  "license": "GPLv3",
#  "method": "git",
#  "name": "testfoo",
#  "tags": @["foo", "bar"],
#  "url": "https://uu",
#  "web": "https://abc"
#}
#let sig = generate_gpg_signature(node, "")
#node["signature"] = newJString sig
#
#let body = node.pretty()


suite "functional tests":

  test "index":
    var page = get url
    assert page.contains "Recently"
    assert page.contains "A sinatra-like web"

  test "search / show pkg list":
    # users search pkg
    var page = get(url & "/search?query=framework")
    assert page.contains "Chromium Embedded Framework"
    page = get(url & "/search?query=framework")
    assert page.contains "Chromium Embedded Framework"

  test "show jester pkg":
    # users look at pkg metadata
    #   look at pkg github readme
    var page = get(url & "/pkg/jester")
    assert page.contains "Jester provides a DSL"
    page = get(url & "/pkg/jester")
    assert page.contains "Jester provides a DSL"
    # Check string from the GH readme
    assert page.contains "Routes will be executed in the order"

  test "fetch packages.json":
    var page = get url & "/packages.json"
    let pkgs_1 = page.parseJson()
    assert pkgs_1.len > 100

  test "show hosted doc file list":
    var page = get url & "/docs/jester"
    assert page.contains "jester.html"
    page = get url & "/docs/jester"
    assert page.contains "jester.html"

  test "show hosted doc file":
    var page = get url & "/docs/jester/jester.html"
    # From jester's docgen
    assert page.contains "IP address of the requesting client"
    page = get url & "/docs/jester/jester.html"
    assert page.contains "IP address of the requesting client"

  test "new packages RSS":
    var page = get url & "/packages.xml"
    assert page.contains """<?xml version="1.0" encoding="UTF-8" ?>"""
    assert page.contains """<rss version="2.0">"""


  get "/ci/install_report":
    discard

  get "/ci/badges/@pkg_name/version.svg":
    ## Version badge
    discard

  get "/ci/badges/@pkg_name/nim_version/status.svg":
    ## Status badge
    discard




  #look generated doc page
  #nimble-install pkg
  #  verify pkg_owner signature on pkg metadata
  #  verify pkg_ower signature on repo git tag
  #
  #new and updated pkgs RSS feed
  #hotlinking into badges
  #
  # pkg_owner upload new pkg metadata
  # pkg owner update pkg metadata
  # pkg owner look at install output
  # pkg owner look at nim doc output
