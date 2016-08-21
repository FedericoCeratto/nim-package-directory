#
# Nimble package directory
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#

from algorithm import sortedByIt
from times import epochTime
import asyncdispatch
import httpclient
import httpcore
import json
import logging
import os
import sequtils
import strutils
import tables

import jester

import signatures


const
  template_path = "./templates"
  timeout = 60
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_readme_header = "Accept:application/vnd.github.v3.html\c\L"
  github_caching_time = 600

# init

let conf = parseFile("conf.json")
let github_token = "Authorization: token $#\c\L" % conf["github_token"].str
let packages_list_fname = conf["packages_list_fname"].str

newConsoleLogger().addHandler
newRollingFileLogger(conf["log_fname"].str, fmtStr = verboseFmtStr).addHandler

type
  Pkg* = JsonNode

var pkgs = newTable[string, Pkg]()

# tag -> package names
var packages_by_tag = newTable[string, seq[string]]()
var packages_by_description_word = newTable[string, seq[string]]()

include "templates/base.tmpl"
include "templates/pkg.tmpl"
include "templates/pkg_list.tmpl"

# proc setup_seccomp() =
#   ## Setup seccomp sandbox
#   const syscalls = """accept,access,arch_prctl,bind,brk,close,connect,epoll_create,epoll_ctl,epoll_wait,execve,fcntl,fstat,futex,getcwd,getrlimit,getuid,ioctl,listen,lseek,mmap,mprotect,munmap,open,poll,read,readlink,recvfrom,rt_sigaction,rt_sigprocmask,sendto,set_robust_list,setsockopt,set_tid_address,socket,stat,uname,write"""
#   let ctx = seccomp_ctx()
#   for sc in syscalls.split(','):
#     ctx.add_rule(Allow, sc)
#   ctx.load()

proc load_packages*() =
  ## Load packages.json
  ## Rebuild packages_by_tag, packages_by_description_word
  debug "loading $#" % packages_list_fname
  pkgs.clear()
  let pkg_list = packages_list_fname.readFile.parseJson
  for pdata in pkg_list:
    if pdata.hasKey("name"):
      pkgs.add (pdata["name"].str, pdata)

      for tag in pdata["tags"]:
        if not packages_by_tag.hasKey(tag.str):
          packages_by_tag[tag.str] = @[]
        packages_by_tag[tag.str].add pdata["name"].str

      # collect packages matching a word in their descriptions
      let orig_words = pdata["description"].str.split({' ', ','}) & pdata["name"].str
      for orig_word in orig_words:
        if orig_word.len < 3:
          continue  # ignore short words
        let word = orig_word.toLower
        if not packages_by_description_word.hasKey(word):
          packages_by_description_word[word] = @[]
        packages_by_description_word[word].add pdata["name"].str


  echo "Loaded ", $pkgs.len, " packages"

from algorithm import sort, sorted

proc cleanupWhitespace(s: string): string

proc save_packages() =
  ## Save packages.json
  var new_pkgs = newJArray()
  for pname in toSeq(pkgs.keys()).sorted(system.cmp):
    new_pkgs.add pkgs[pname]

  packages_list_fname.writeFile(new_pkgs.pretty.cleanupWhitespace)

proc search_packages*(query: string): CountTable[string] =
  ## Search packages by tag and keyword
  let query = query.split({' ', ','})
  #TODO lowercase match
  var found_pkg_names = initCountTable[string]()
  for item in query:
    if packages_by_tag.has_key(item):
      for pn in packages_by_tag[item]:
        # matching by tags is weighted more
        found_pkg_names.inc(pn, val=3)

    if packages_by_description_word.has_key(item.toLower):
      for pn in packages_by_description_word[item.toLower]:
        found_pkg_names.inc(pn)


  # sort packages by best match
  found_pkg_names.sort()
  return found_pkg_names


# routes

routes:

  get "/":
    resp base_page("<h5>Welcome to the Nim package directory.</h5><p>Work in progress.</p>")

  get "/search":
    let found_pkg_names = search_packages(@"query")

    var pkgs_list: seq[Pkg] = @[]
    for pn in found_pkg_names.keys():
      pkgs_list.add pkgs[pn]

    resp base_page(generate_pkg_list_page(pkgs_list))


  get "/pkg/@pkg_name/?":
    let pname = @"pkg_name"
    if not pkgs.has_key(pname):
      resp base_page "Package not found"

    let
      pkg = pkgs[pname]
      url = pkg["url"].str

    if url.startswith("https://github.com/") or url.startswith("http://github.com/"):
      if not pkg.has_key("github_last_update_time") or pkg["github_last_update_time"].num +
          github_caching_time < epochTime().int:
        # pkg is on GitHub and needs updating
        pkg["github_last_update_time"] = newJInt epochTime().int
        let owner = url.split('/')[3]
        let owner_repo_name = "$#/$#" % url.split('/')[3..4]
        pkg["github_owner"] = newJString owner

        echo "fetching ", github_readme_tpl % owner_repo_name
        try:
          let readme = getContent(github_readme_tpl % owner_repo_name,
            extraHeaders=github_readme_header & github_token)
          pkg["github_readme"] = newJString readme
        except:
          echo getCurrentExceptionMsg()
          pkg["github_readme"] = newJString ""

        echo "fetching ", github_latest_version_tpl % owner_repo_name
        try:
          let latest_version = getContent(github_latest_version_tpl % owner_repo_name,
            extraHeaders=github_token).parseJson
          pkg["github_latest_version"] = newJString latest_version["name"].str
          pkg["github_latest_version_url"] = newJString latest_version["tarball_url"].str
          pkg["github_latest_version_time"] = newJString latest_version["published_at"].str
        except:
          pkg["github_latest_version"] = newJString "none"
          pkg["github_latest_version_url"] = newJString ""
          pkg["github_latest_version_time"] = newJString ""

    resp base_page(generate_pkg_page(pkg))

  post "/update_package":
    ## Create or update a package description
    const required_fields = @["name", "url", "method", "tags", "description",
      "license", "web", "signature", "authorized_keys"]
    var pkg_data: JsonNode
    try:
      pkg_data = parseJson(request.body)
    except:
      info "Unable to parse JSON payload"
      resp Http400, "Unable to parse JSON payload"

    for field in required_fields:
      if not pkg_data.hasKey(field):
        info "Missing required field $#" % field
        resp Http400, "Missing required field $#" % field

    let signature = pkg_data["signature"].str
    pkg_data.delete("signature")

    try:
      let key_id = verify_gpg_signature(pkg_data, signature)
      info "received key", key_id
    except:
      info "Invalid signature"
      resp Http400, "Invalid signature"

    let name = pkg_data["name"].str

    # TODO: locking?
    load_packages()

    # the package exists with identical name
    let pkg_already_exists = pkgs.hasKey(name)

    if not pkg_already_exists:
      # scan for naming collisions
      let lower_name = name.to_lower()
      for existing_pn in pkgs.keys():
        if lower_name == existing_pn.to_lower():
          info "Another package named $# already exists" % existing_pn
          resp Http400, "Another package named $# already exists" % existing_pn

    if pkg_already_exists:
      try:
        let old_keys = pkgs[name]["authorized_keys"].getElems.mapIt(it.str)
        let key_id = verify_gpg_signature_is_allowed(pkg_data, signature, old_keys)
        info "$# updating package $#" % [key_id, name]
      except:
        info "Key not accepted"
        resp Http400, "Key not accepted"

    pkgs[name] = pkg_data
    save_packages()
    info if pkg_already_exists: "Updated pkg $#" % name
      else: "Added pkg $#" % name
    resp "OK"


proc cleanupWhitespace(s: string): string =
  ## Removes trailing whitespace and normalizes line endings to LF.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == ' ':
      var j = i+1
      while s[j] == ' ': inc j
      if s[j] == '\c':
        inc j
        if s[j] == '\L': inc j
        result.add '\L'
        i = j
      elif s[j] == '\L':
        result.add '\L'
        i = j+1
      else:
        result.add ' '
        inc i
    elif s[i] == '\c':
      inc i
      if s[i] == '\L': inc i
      result.add '\L'
    elif s[i] == '\L':
      result.add '\L'
      inc i
    else:
      result.add s[i]
      inc i
  if result[^1] != '\L':
    result.add '\L'


proc main() =
  #setup_seccomp()
  load_packages()
  runForever()

when isMainModule:
  main()
