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
  echo "          fetching $#" % url
  return httpclient.getContent(url)


suite "functional tests":

  test "index":
    var page = get url
    check page.contains "Recently"

  test "search / show pkg list":
    # users search pkg
    var page = get(url & "/search?query=framework")
    check page.contains "Chromium Embedded Framework"
    page = get(url & "/search?query=framework")
    check page.contains "Chromium Embedded Framework"

  test "show jester pkg":
    # users look at pkg metadata
    #   look at pkg github readme
    var page = get(url & "/pkg/jester")
    check page.contains "Jester provides a DSL"
    page = get(url & "/pkg/jester")
    check page.contains "Jester provides a DSL"
    # Check string from the GH readme
    check page.contains "Routes will be executed in the order"

  test "fetch packages.json":
    var page = get url & "/packages.json"
    let pkgs_1 = page.parseJson()
    check pkgs_1.len > 100

  test "show hosted doc file list":
    var page = get url & "/docs/jester"
    check page.contains "jester.html"
    page = get url & "/docs/jester"
    check page.contains "jester.html"

  test "show hosted doc file":
    var page = get url & "/docs/jester/jester.html"
    # From jester's docgen
    check page.contains "IP address of the requesting client"
    page = get url & "/docs/jester/jester.html"
    check page.contains "IP address of the requesting client"

  test "new packages RSS":
    var page = get url & "/packages.xml"
    check page.contains """<?xml version="1.0" encoding="UTF-8" ?>"""
    check page.contains """<rss version="2.0">"""

  test "jester status.svg":
    var page = get url & "/ci/badges/jester/nimdevel/status.svg"
    check page.contains ">OK<"

  test "jsondoc":
    var page = get url & "/searchitem?query=newSettings"
    check page.contains "324"
    check page.contains "getCurrentDir"
    check page.contains "1 entries found"
    check page.contains "jester.nim"

    page = get url & "/searchitem?query=nothingToBeFoundHere"
    check page.contains "0 entries found"

  # test "/ci/install_report":
  #   discard

  # test "/ci/badges/@pkg_name/version.svg":
  #   ## Version badge
  #   discard





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
