#
# Nimble package directory
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#

from algorithm import sortedByIt
from algorithm import sort, sorted
from times import epochTime
import asyncdispatch
import httpclient
import httpcore
import json
import logging
import os
import osproc
import parseopt
import sequtils
import strutils
import streams
import tables

import jester

import signatures


const
  template_path = "./templates"
  timeout = 60
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_doc_index_tpl = "https://$#.github.io/$#/index.html"
  github_readme_header = "Accept:application/vnd.github.v3.html\c\L"
  github_caching_time = 600

# init

let conf = parseFile("conf.json")
let github_token = "Authorization: token $#\c\L" % conf["github_token"].str
let packages_list_fname = conf["packages_list_fname"].str
var port = if conf.has_key("port"): conf["port"].getNum.Port else: 5000.Port

# parse CLI opts

for kind, key, val in getopt():
  case kind
  of cmdShortOption:
    case key
    of "p": port = val.parseInt.Port
  else: discard


let fl = newFileLogger(conf["log_fname"].str, fmtStr = "$datetime $levelname ")
fl.addHandler

proc log_debug(args: varargs[string, `$`]) =
  debug args
  fl.file.flushFile()

proc log_info(args: varargs[string, `$`]) =
  info args
  fl.file.flushFile()

type
  Pkg* = JsonNode
  strSeq = seq[string]

# the pkg name is normalized
var pkgs = newTable[string, Pkg]()
var pkgs_doc_files = newTable[string, strSeq]()

# tag -> package names
var packages_by_tag = newTable[string, seq[string]]()
var packages_by_description_word = newTable[string, seq[string]]()

include "templates/base.tmpl"
include "templates/home.tmpl"
include "templates/pkg.tmpl"
include "templates/pkg_list.tmpl"
include "templates/doc_files_list.tmpl"
include "templates/loader.tmpl"

proc load_packages*() =
  ## Load packages.json
  ## Rebuild packages_by_tag, packages_by_description_word
  log_debug "loading $#" % packages_list_fname
  pkgs.clear()
  let pkg_list = packages_list_fname.readFile.parseJson
  for pdata in pkg_list:
    if not pdata.hasKey("name"):
      continue
    # Normalize pkg name
    pdata["name"].str = pdata["name"].str.normalize()
    if pdata["name"].str in pkgs:
      warn "Duplicate pkg name $#" % pdata["name"].str
      continue

    pkgs.add (pdata["name"].str, pdata)

    for tag in pdata["tags"]:
      if not packages_by_tag.hasKey(tag.str):
        packages_by_tag[tag.str] = @[]
      packages_by_tag[tag.str].add pdata["name"].str

    # collect packages matching a word in their descriptions
    let orig_words = pdata["description"].str.split({' ', ','})
    for orig_word in orig_words:
      if orig_word.len < 3:
        continue  # ignore short words
      let word = orig_word.toLower
      if not packages_by_description_word.hasKey(word):
        packages_by_description_word[word] = @[]
      packages_by_description_word[word].add pdata["name"].str


  log_info "Loaded ", $pkgs.len, " packages"


proc cleanupWhitespace(s: string): string

proc save_packages() =
  ## Save packages.json
  var new_pkgs = newJArray()
  for pname in toSeq(pkgs.keys()).sorted(system.cmp):
    new_pkgs.add pkgs[pname]

  packages_list_fname.writeFile(new_pkgs.pretty.cleanupWhitespace)

proc search_packages*(query: string): CountTable[string] =
  ## Search packages by name, tag and keyword
  let query = query.split({' ', ','})
  var found_pkg_names = initCountTable[string]()
  for item in query:

    # matching by pkg name, weighted for full or partial match
    for pn in pkgs.keys():
      if item.normalize() == pn:
        found_pkg_names.inc(pn, val=5)
      elif pn.contains(item.normalize()):
        found_pkg_names.inc(pn, val=3)

    if packages_by_tag.has_key(item):
      for pn in packages_by_tag[item]:
        # matching by tags is weighted more than by word
        found_pkg_names.inc(pn, val=3)

    # matching by description, weighted 1
    if packages_by_description_word.has_key(item.toLower):
      for pn in packages_by_description_word[item.toLower]:
        found_pkg_names.inc(pn, val=1)

  # sort packages by best match
  found_pkg_names.sort()
  return found_pkg_names

proc fetch_github_readme(pkg: Pkg, owner_repo_name: string) =
  ## Fetch README.* from GitHub
  log_debug "fetching ", github_readme_tpl % owner_repo_name
  try:
    let readme = getContent(github_readme_tpl % owner_repo_name,
    extraHeaders=github_readme_header & github_token)
    pkg["github_readme"] = newJString readme
  except:
    log_debug getCurrentExceptionMsg()
    pkg["github_readme"] = newJString ""

proc fetch_github_version_data(pkg: Pkg, owner_repo_name: string) =
  ## Fetch version data from GitHub
  log_debug "fetching ", github_latest_version_tpl % owner_repo_name
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

# https://federicoceratto.github.io/nim-libsodium/docs/0.1.0/sodium.html

proc fetch_github_doc_pages(pkg: Pkg, owner, repo_name: string) =
  ## Fetch documentation pages from GitHub
  let url = github_doc_index_tpl % [owner.toLower, repo_name]
  log_debug "Checking ", url
  if get(url).status.startsWith("200"):
    pkg["doc"] = newJString url


# Jester settings

settings:
    port = port

# routes

routes:

  get "/":
    resp base_page(generate_home_page())

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
        let repo_name = url.split('/')[4]
        let owner_repo_name = "$#/$#" % url.split('/')[3..4]
        pkg["github_owner"] = newJString owner
        pkg.fetch_github_readme(owner_repo_name)
        pkg.fetch_github_version_data(owner_repo_name)
        pkg.fetch_github_doc_pages(owner, repo_name)

    resp base_page(generate_pkg_page(pkg))

  post "/update_package":
    ## Create or update a package description
    const required_fields = @["name", "url", "method", "tags", "description",
      "license", "web", "signatures", "authorized_keys"]
    var pkg_data: JsonNode
    try:
      pkg_data = parseJson(request.body)
    except:
      log_info "Unable to parse JSON payload"
      resp Http400, "Unable to parse JSON payload"

    for field in required_fields:
      if not pkg_data.hasKey(field):
        log_info "Missing required field $#" % field
        resp Http400, "Missing required field $#" % field

    let signature = pkg_data["signatures"][0].str

    try:
      let pkg_data_copy = pkg_data.copy()
      pkg_data_copy.delete("signatures")
      let key_id = verify_gpg_signature(pkg_data_copy, signature)
      log_info "received key", key_id
    except:
      log_info "Invalid signature"
      resp Http400, "Invalid signature"

    let name = pkg_data["name"].str

    # TODO: locking?
    load_packages()

    # the package exists with identical name
    let pkg_already_exists = pkgs.hasKey(name)

    if not pkg_already_exists:
      # scan for naming collisions
      let norm_name = name.normalize()
      for existing_pn in pkgs.keys():
        if norm_name == existing_pn.normalize():
          info "Another package named $# already exists" % existing_pn
          resp Http400, "Another package named $# already exists" % existing_pn

    if pkg_already_exists:
      try:
        let old_keys = pkgs[name]["authorized_keys"].getElems.mapIt(it.str)
        let pkg_data_copy = pkg_data.copy()
        pkg_data_copy.delete("signatures")
        let key_id = verify_gpg_signature_is_allowed(pkg_data_copy, signature, old_keys)
        log_info "$# updating package $#" % [key_id, name]
      except:
        log_info "Key not accepted"
        resp Http400, "Key not accepted"

    pkgs[name] = pkg_data
    save_packages()
    log_info if pkg_already_exists: "Updated existing package $#" % name
      else: "Added new package $#" % name
    resp "OK"

  get "/packages.json":
    ## Serve the packages list file
    resp packages_list_fname.readFile

  get "/docs/@pkg_name/?@doc_path?":
    ## Serve hosted docs for a package
    const
      tmp_doc_dir = "/tmp/doc"
      git_bin_path = "/usr/bin/git"
      nim_bin_path = "/usr/bin/nim"
    let pname = @"pkg_name"
    let doc_path = @"doc_path"
    if not pkgs.hasKey(pname):
      resp "<html><body>Pkg not found</body></html>"
    let pkg = pkgs[pname]
    let url = pkg["url"].str
    let wd = tmp_doc_dir / pname
    if not wd.existsDir():
      # Check out pkg
      var doc_fnames: seq[string] = @[]
      tmp_doc_dir.createDir()
      log_debug "checking out $#" % url
      var p = startProcess(
        git_bin_path,  args=["clone", url, pname],
        workingDir=tmp_doc_dir
      )
      if p.waitForExit(timeout=60000) == 0:
        log_debug "OK"
      else:
        error "Stdout: $#" % p.outputStream().readAll()
        error "Stderr: $#" % p.errorStream().readAll()

      for fname in wd.walkDirRec(filter={pcFile}):
        if not fname.endswith(".nim"):
          continue
        log_debug "running nim doc for $#" % fname
        p = startProcess(
          nim_bin_path,
          args=["doc", fname],
          workingDir=wd
        )
        if p.waitForExit(timeout=60000) == 0:
          log_debug "OK"
          log_debug "Stdout: $#" % p.outputStream().readAll()
          log_debug "Stderr: $#" % p.errorStream().readAll()
        else:
          error "Stdout: $#" % p.outputStream().readAll()
          error "Stderr: $#" % p.errorStream().readAll()
        doc_fnames.add fname[wd.len..^1][1..^4] & "html"

      # doc gen done
      pkgs_doc_files[pname] = doc_fnames

    if not pkgs_doc_files.hasKey(pname):
      resp "meow :3"

    if doc_path == "":
      resp base_page(
        generate_doc_files_list_page(pname, pkgs_doc_files[pname])
      )

    let fn = tmp_doc_dir / pname / doc_path
    if existsFile(fn):
      log_debug "serving $#" % fn
      resp base_page(fn.readFile())
    else:
      log_info "serving $# - not found" % fn
      halt


  get "/loader":
    resp base_page(
      generate_loader_page()
    )


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
  log_info "starting"
  load_packages()
  runForever()

when isMainModule:
  main()
