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

import os
import osproc

putEnv("FUNCTEST", "1")

const url="http://localhost:5000"

proc get(url: string): string =
  echo "          fetching $#" % url
  return newHttpClient().getContent(url)

proc post(url: string): string =
  echo "          post to $#" % url
  return newHttpClient().postContent(url)


suite "functional tests":

  echo "starting pkgdir"
  let pkgdir_process =
    if getEnv("SHOWOUT") != "":
      startProcess("./package_directory", options={poEvalCommand, poParentStreams})
    else:
      startProcess("./package_directory", options={poEvalCommand})

  sleep 800
  doAssert pkgdir_process.running()

  test "index":
    var page = get url
    check page.contains "Recently"

  test "search / show pkg list":
    # users search pkg
    var page = get(url & "/search?query=framework")
    check page.contains "Chromium Embedded Framework"
    page = get(url & "/search?query=framework")
    check page.contains "Chromium Embedded Framework"

  test "build jester pkg":

    test "JSON status: unknown":
      check "unknown" in get(url & "/api/v1/status/jester")

    # users look at pkg metadata
    #   look at pkg github readme
    var page = get(url & "/pkg/jester")
    check page.contains "Jester provides a DSL"
    page = get(url & "/pkg/jester")
    check page.contains "Jester provides a DSL"
    # Check string from the GH readme
    check page.contains "Routes will be executed in the order"
    check page.contains "0.2.0"

    for cnt in 1..100:
      if "done" in newHttpClient().getContent(url & "/api/v1/status/jester"):
        break
      sleep 250
      if cnt == 100: quit(1)

    test "JSON status: done":
      let status = get(url & "/api/v1/status/jester").parseJSON()
      check status["status"].getStr() == "done"
      check status["build_time"].getStr().startsWith("201")

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

  test "jester version.svg":
    var page = get url & "/ci/badges/jester/version.svg"
    check page.contains "version"

  test "jsondoc":
    var page = get url & "/searchitem?query=newSettings"
    check page.contains "324"
    check page.contains "getCurrentDir"
    check page.contains "1 entries found"
    check page.contains "jester.nim"

    test "global symbol search - empty":
      var page = get url & "/searchitem?query=nothingToBeFoundHere"
      check page.contains "0 entries found"

    test "global symbol search - normalizeUri":
      # assumes jester has been built
      var page = get url & "/searchitem?query=normalizeUri"
      check page.contains "1 entries found"
      # TODO: fix page style and content

    test "global symbol search - API":
      var page = get url & "/api/v1/search_symbol?symbol=sendHeaders"
      check page.startsWith("[")
      check page.endswith("]")

    test "package symbol search - normalizeUri":
      # assumes jester has been built
      var page = post url & "/searchitem_pkg?pkg_name=jester&query=normalizeUri"
      check page.contains "1 entries found"

    test "package symbol search - sendHeaders":
      # assumes jester has been built
      var page = post url & "/searchitem_pkg?pkg_name=jester&query=sendHeaders"
      check page.contains "3 entries found"
      check page.contains "Filename: jester.nim"
      check page.contains "Type: skProc"
      check page.contains "https://github.com/dom96/jester/blob/master/jester.nim#L95"
      check page.contains "https://github.com/dom96/jester/blob/master/jester.nim#L108"
      check page.contains "https://github.com/dom96/jester/blob/master/jester.nim#L113"

  echo "stopping pkgdir"
  terminate pkgdir_process
  sleep 500
  while pkgdir_process.running():
    echo "Error: still running"
    kill pkgdir_process
    sleep 500


  #TODO: API

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
