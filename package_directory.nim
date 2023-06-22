#
# Nimble package directory
#
# Copyright 2016-2023 Federico Ceratto <federico.ceratto@gmail.com> and other contributors
# Released under GPLv3 License, see LICENSE file
#

import std/[
  asyncdispatch,
  deques,
  httpclient,
  httpcore,
  json,
  os,
  sequtils,
  sets,
  streams,
  strutils,
  tables,
  times,
  uri
]

from std/xmltree import escape
from std/algorithm import sort, sorted, sortedByIt, reversed
from std/marshal import store, load
from std/posix import onSignal, SIGINT, SIGTERM, getpid

#from nimblepkg import getTagsListRemote, getVersionList
import jester,
  morelogging,
  sdnotify,
  statsd_client

import github, util, signatures, persist

const
  nimble_packages_polling_time_s = 10 * 60
  sdnotify_ping_time_s = 10
  cache_fn = ".cache.json"


# init

type
  RssItem = object
    title, desc, pub_date: string
    url, guid: Uri

# the pkg name is normalized
var pkgs: Pkgs = newTable[string, Pkg]()

# tag -> package name
# initialized/updated by load_packages
var packages_by_tag = newTable[string, seq[string]]()

# word -> package name
# initialized/updated by load_packages
var packages_by_description_word = newTable[string, seq[string]]()

# package access statistics
# volatile
var most_queried_packages = initCountTable[string]()


type
  PkgHistoryItem = object
    name: string
    first_seen_time: Time

  Cache = object of RootObj
    # package creation/update history - new ones at bottom
    pkgs_history: seq[PkgHistoryItem]
    # pkgs list. Extra data from GH is embedded
    #pkgs: TableRef[string, Pkg]

var cache: Cache

proc save(cache: Cache) =
  let f = newFileStream(cache_fn, fmWrite)
  log_debug "writing " & absolutePath(cache_fn)
  f.store(cache)
  f.close()

proc load_cache(): Cache =
  ## Load cache from disk or create empty cache
  log_debug "loading cache at $#" % cache_fn
  try:
    # FIXME
    #result.pkgs = newTable[string, Pkg]()
    result.pkgs_history = @[]
    load(newFileStream(cache_fn, fmRead), result)
    log_debug "cache loaded"
  except:
    log_info "initializing new cache"
    #result.pkgs = newTable[string, Pkg]()
    result.pkgs_history = @[]
    result.save()
    log_debug "new cache created"



# HTML templates

include "templates/base.tmpl"
include "templates/home.tmpl"
include "templates/pkg.tmpl"
include "templates/pkg_list.tmpl"
include "templates/rss.tmpl"


proc search_packages*(query: string): CountTable[string] =
  ## Search packages by name, tag and keyword
  let query = query.strip.toLowerAscii.split({' ', ','})
  var found_pkg_names = initCountTable[string]()
  for item in query:

    # matching by pkg name, weighted for full or partial match
    for pn in pkgs.keys():
      if item.normalize() == pn:
        found_pkg_names.inc(pn, val = 5)
      elif pn.contains(item.normalize()):
        found_pkg_names.inc(pn, val = 3)

    if packages_by_tag.hasKey(item):
      for pn in packages_by_tag[item]:
        # matching by tags is weighted more than by word
        found_pkg_names.inc(pn, val = 3)

    # matching by description, weighted 1
    if packages_by_description_word.hasKey(item.toLowerAscii):
      for pn in packages_by_description_word[item.toLowerAscii]:
        found_pkg_names.inc(pn, val = 1)

  # sort packages by best match
  found_pkg_names.sort()
  return found_pkg_names


proc load_packages*() =
  ## Load packages.json
  ## Rebuild packages_by_tag, packages_by_description_word
  log_debug "loading $#" % conf.packages_list_fname
  pkgs.clear()
  if not conf.packages_list_fname.file_exists:
    log_info "packages list file not found. First run?"
    let new_pkg_raw = waitFor fetch_nimble_packages()
    log_info "writing $#" % absolutePath(conf.packages_list_fname)
    conf.packages_list_fname.writeFile(new_pkg_raw)

  let pkg_list = conf.packages_list_fname.parseFile
  for pdata in pkg_list:
    if not pdata.hasKey("name"):
      continue
    if not pdata.hasKey("tags"):
      continue
    # Normalize pkg name
    pdata["name"].str = pdata["name"].str.toLowerAscii()
    if pdata["name"].str in pkgs:
      log.warn "Duplicate pkg name $#" % pdata["name"].str
      continue

    pkgs[pdata["name"].str] = pdata

    for tag in pdata["tags"]:
      if not packages_by_tag.hasKey(tag.str):
        packages_by_tag[tag.str] = @[]
      packages_by_tag[tag.str].add pdata["name"].str

    # collect packages matching a word in their descriptions
    let orig_words = pdata["description"].str.split({' ', ','})
    for orig_word in orig_words:
      if orig_word.len < 3:
        continue # ignore short words
      let word = orig_word.toLowerAscii
      if not packages_by_description_word.hasKey(word):
        packages_by_description_word[word] = @[]
      packages_by_description_word[word].add pdata["name"].str

  log_info "Loaded ", $pkgs.len, " packages"

  # log_debug "writing $#" % conf.packages_list_fname
  # conf.packages_list_fname.writeFile(conf.packages_list_fname.readFile)


proc translate_term_colors*(outp: string): string =
  ## Translate terminal colors into HTML with CSS classes
  const sequences = @[
    ("[36m[2m", "<span>"),
    ("[32m[1m", """<span class="term-success">"""),
    ("[33m[1m", """<span class="term-red">"""),
    ("[31m[1m", """<span class="term-red">"""),
    ("[36m[1m", """<span class="term-blue">"""),
    ("[0m[31m[0m", "</span>"),
    ("[0m[32m[0m", "</span>"),
    ("[0m[33m[0m", "</span>"),
    ("[0m[36m[0m", "</span>"),
    ("[0m[0m", "</span>"),
    ("[2m", "<span>"),
    ("[36m", "<span>"),
    ("[33m", """<span class="term-blue">"""),
  ]
  result = outp
  for s in sequences:
    result = result.replace(s[0], s[1])

proc sorted*[T](t: CountTable[T]): CountTable[T] =
  ## Return sorted CountTable
  var tcopy = t
  tcopy.sort()
  tcopy

proc top_keys*[T](t: CountTable[T], n: int): seq[T] =
  ## Return CountTable most common keys
  result = @[]
  var tcopy = t
  tcopy.sort()
  for k in keys(tcopy):
    result.add k
    if result.len == n:
      return


# Jester settings

settings:
  port = conf.port

# routes

router mainRouter:

  get "/about.html":
    include "templates/about.tmpl"
    resp base_page(request, generate_about_page())

  get "/":
    log_req request
    stats.incr("views")

    # Grab the most queried packages
    var top_pkgs: seq[Pkg] = @[]
    for pname in top_keys(most_queried_packages, 5):
      if pkgs.hasKey(pname):
        top_pkgs.add pkgs[pname]

    # Grab the newest packages
    log_debug "pkgs history len: $#" % $cache.pkgs_history.len
    var new_pkgs: seq[Pkg] = @[]
    for n in 1..min(cache.pkgs_history.len, 10):
      let package_name: string =
        if cache.pkgs_history[^n].name.len > 4 and cache.pkgs_history[^n].name[
            0..3] == "nim-":
          cache.pkgs_history[^n].name[4..^1].normalize()
        else:
          cache.pkgs_history[^n].name.normalize()
      if pkgs.hasKey(package_name):
        new_pkgs.add pkgs[package_name]
      else:
        log_debug "$# not found in package list" % package_name

    # Grab trending packages, as measured by GitHub
    let trending_pkgs = await fetch_trending_packages(request, pkgs)

    resp base_page(request, generate_home_page(top_pkgs, new_pkgs,
        trending_pkgs))

  get "/search":
    log_req request
    stats.incr("views")

    var searched_pkgs: seq[Pkg] = @[]
    for name in search_packages(@"query").keys():
      searched_pkgs.add pkgs[name]
    stats.gauge("search_found_pkgs", searched_pkgs.len)

    let body = generate_search_box(@"query") & generate_pkg_list_page(searched_pkgs)
    resp base_page(request, body)

  get "/pkg/@pkg_name/?":
    log_req request
    stats.incr("views")
    let pname = toLowerAscii(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname

    let pkg = pkgs[pname]
    let url = pkg["url"].str
    if url.startswith("https://github.com/") or url.startswith("http://github.com/"):
      if not pkg.hasKey("github_last_update_time") or pkg["github_last_update_time"].num +
          github_caching_time < epochTime().int:
        # pkg is on GitHub and needs updating
        pkg["github_last_update_time"] = newJInt epochTime().int
        let owner = url.split('/')[3]
        let repo_name = url.split('/')[4]
        pkg["github_owner"] = newJString owner
        pkg["github_readme"] = await fetch_github_readme(owner, repo_name)
        pkg["doc"] = await fetch_github_doc_pages(owner, repo_name)
        await pkg.fetch_github_versions(owner, repo_name)

    resp base_page(request, generate_pkg_page(pkg))

  post "/update_package":
    ## Create or update a package description
    log_req request
    stats.incr("views")
    const required_fields = @["name", "url", "method", "tags", "description",
      "license", "web", "signatures", "authorized_keys"]
    var pkg_data: JsonNode
    try:
      pkg_data = parseJson(request.body)
    except:
      log_info "Unable to parse JSON payload"
      halt Http400, "Unable to parse JSON payload"

    for field in required_fields:
      if not pkg_data.hasKey(field):
        log_info "Missing required field $#" % field
        halt Http400, "Missing required field $#" % field

    let signature = pkg_data["signatures"][0].str

    try:
      let pkg_data_copy = pkg_data.copy()
      pkg_data_copy.delete("signatures")
      let key_id = verify_gpg_signature(pkg_data_copy, signature)
      log_info "received key", key_id
    except:
      log_info "Invalid signature"
      halt Http400, "Invalid signature"

    let name = pkg_data["name"].str

    # TODO: locking
    load_packages()

    # the package exists with identical name
    let pkg_already_exists = pkgs.hasKey(name)

    if not pkg_already_exists:
      # scan for naming collisions
      let norm_name = name.normalize()
      for existing_pn in pkgs.keys():
        if norm_name == existing_pn.normalize():
          log.info "Another package named $# already exists" % existing_pn
          halt Http400, "Another package named $# already exists" % existing_pn

    if pkg_already_exists:
      try:
        let old_keys = pkgs[name]["authorized_keys"].getElems.mapIt(it.str)
        let pkg_data_copy = pkg_data.copy()
        pkg_data_copy.delete("signatures")
        let key_id = verify_gpg_signature_is_allowed(pkg_data_copy, signature, old_keys)
        log_info "$# updating package $#" % [key_id, name]
      except:
        log_info "Key not accepted"
        halt Http400, "Key not accepted"

    pkgs[name] = pkg_data

    var new_pkgs = newJArray()
    for pname in toSeq(pkgs.keys()).sorted(system.cmp):
      new_pkgs.add pkgs[pname]
    conf.packages_list_fname.writeFile(new_pkgs.pretty.cleanup_whitespace)

    log_info if pkg_already_exists: "Updated existing package $#" % name
      else: "Added new package $#" % name
    resp base_page(request, "OK")

  get "/packages.json":
    ## Serve the packages list file
    log_req request
    stats.incr("views")
    resp conf.packages_list_fname.readFile

  get "/api/v1/package_count":
    ## Serve the package count
    log_req request
    stats.incr("views")
    resp $pkgs.len

  get "/packages.xml":
    ## New and updated packages feed
    log_req request
    stats.incr("views_rss")
    let baseurl = conf.public_baseurl.parseUri
    let url = baseurl / "packages.xml"

    var rss_items: seq[RssItem] = @[]
    for item in cache.pkgs_history:
      let pn = item.name.normalize()
      if not pkgs.hasKey(pn):
        #log_debug "skipping $#" % pn
        continue

      let pkg = pkgs[pn]
      let item_url = baseurl / "pkg" / pn
      let i = RssItem(
        title: pn,
        desc: xmltree.escape(pkg["description"].str),
        url: item_url,
        guid: item_url,
        pub_date: $item.first_seen_time.utc.format("ddd, dd MMM yyyy hh:mm:ss zz")
      )
      rss_items.add i

    let r = generate_rss_feed(
      title = "Nim packages",
      desc = "New and updated Nim packages",
      url = url,
      build_date = getTime().utc.format("ddd, dd MMM yyyy hh:mm:ss zz"),
      pub_date = getTime().utc.format("ddd, dd MMM yyyy hh:mm:ss zz"),
      ttl = 3600,
      rss_items
    )
    resp(r, contentType = "application/rss+xml")

  get "/stats":
    log_req request
    stats.incr("views")
    resp base_page(request, """
<div class="container" style="padding-top: 10rem;">
  <p class="text-center">Runtime: $#</p>
  <p class="text-center">Queried packages count: $#</p>
</div>
    """ % [$cpuTime(), $len(most_queried_packages)])

  get "/robots.txt":
    ## Serve robots.txt to throttle bots
    const robots = """
User-agent: DataForSeoBot
Disallow: /

User-agent: *
Disallow: /about.html
Disallow: /api
Disallow: /ci
Disallow: /docs
Disallow: /pkg
Disallow: /search
Disallow: /searchitem
Crawl-delay: 300
    """
    resp(robots, contentType = "text/plain")


proc run_systemd_sdnotify_pinger(ping_time_s: int) {.async.} =
  ## Ping systemd watchdog using sd_notify
  const msg = "NOTIFY_SOCKET env var not found - pinging to logfile"
  if not existsEnv("NOTIFY_SOCKET"):
    log_info msg
    echo msg
    while true:
      log_debug "*ping*"
      await sleepAsync ping_time_s * 1000
    # never break

  let sd = newSDNotify()
  sd.notify_ready()
  sd.notify_main_pid(getpid())
  while true:
    sd.ping_watchdog()
    await sleepAsync ping_time_s * 1000


proc poll_nimble_packages(poll_time_s: int) {.async.} =
  ## Poll GitHub for packages.json
  ## Overwrites the packages.json local file!
  log_debug "starting GH packages.json polling"
  var first_run = true
  while true:
    if first_run:
      first_run = false
    else:
      await sleepAsync poll_time_s * 1000
    log_debug "Polling GitHub packages.json"
    try:
      let new_pkg_raw = await fetch_nimble_packages()
      if new_pkg_raw == conf.packages_list_fname.readFile:
        log_debug "No changes"
        stats.gauge("packages_all_known", pkgs.len)
        stats.gauge("packages_history", cache.pkgs_history.len)
        continue

      for pdata in new_pkg_raw.parseJson:
        if pdata.hasKey("name"):
          let pname = pdata["name"].str.normalize()
          if not pkgs.hasKey(pname):
            cache.pkgs_history.add PkgHistoryItem(name: pname,
                first_seen_time: getTime())
            log_debug "New pkg added on GH: $#" % pname

      cache.save()
      log_debug "writing $#" % (getCurrentDir() / conf.packages_list_fname)
      conf.packages_list_fname.writeFile(new_pkg_raw)
      load_packages()

      for item in cache.pkgs_history:
        let pname = item.name.normalize()
        if not pkgs.hasKey(pname):
          log_debug "$# is gone" % pname

      stats.gauge("packages_all_known", pkgs.len)
      stats.gauge("packages_history", cache.pkgs_history.len)

    except:
      log.error getCurrentExceptionMsg()


onSignal(SIGINT, SIGTERM):
  ## Exit signal handler
  log.info "Exiting"
  cache.save()
  quit()


proc main() =
  #setup_seccomp()
  log_info "starting"
  conf.tmp_nimble_root_dir.createDir()
  load_packages()
  cache = load_cache()
  asyncCheck run_systemd_sdnotify_pinger(sdnotify_ping_time_s)
  asyncCheck poll_nimble_packages(nimble_packages_polling_time_s)

  log_info "starting server"
  var server = initJester(mainRouter)
  server.serve()

when isMainModule:
  main()
