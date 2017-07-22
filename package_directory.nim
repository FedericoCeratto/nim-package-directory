#
# Nimble package directory
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#

import asyncdispatch,
 httpclient,
 httpcore,
 json,
 logging,
 os,
 osproc,
 parseopt,
 sequtils,
 streams,
 strutils,
 tables,
 times

from algorithm import sort, sorted, sortedByIt
from marshal import store, load
from posix import onSignal, SIGINT, SIGTERM, getpid
from times import epochTime

#from nimblepkg import getTagsListRemote, getVersionList
import jester,
  sdnotify

import github,
  signatures,
  email,
  persist


const
  template_path = "./templates"
  build_timeout_seconds = 20
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_tags_tpl = "https://api.github.com/repos/$#/tags"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_doc_index_tpl = "https://$#.github.io/$#/index.html"
  github_readme_header = "Accept:application/vnd.github.v3.html\c\L"
  github_caching_time = 600
  github_packages_json_raw_url= "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  github_packages_json_polling_time_s = 10 * 60
  git_bin_path = "/usr/bin/git"
  sdnotify_ping_time_s = 15
  nim_bin_path = "/usr/bin/nim"
  nimble_bin_path = "/usr/bin/nimble"
  tmp_nimble_root_dir = "/dev/shm/nim_package_dir"
  build_expiry_time = 300.Time # 5 mins
  cache_fn = ".cache.json"

# init

let conf = load_conf()
let github_token = "Authorization: token $#\c\L" % conf.github_token

# parse CLI opts

#for kind, key, val in getopt():
#  case kind
#  of cmdShortOption:
#    case key
#    of "p": conf.port = val.parseInt.Port
#  else: discard

let fl = newFileLogger(conf.log_fname, fmtStr = "$datetime $levelname ")
fl.addHandler

proc log_debug(args: varargs[string, `$`]) =
  debug args
  fl.file.flushFile()

proc log_info(args: varargs[string, `$`]) =
  info args
  fl.file.flushFile()

proc log(request: Request) =
  ## Log request data
  #log_info "serving $# $# $#" % [request.ip, $request.reqMeth, request.path]
  discard

log_debug conf

type
  ProcessError = object of Exception
  Pkg* = JsonNode
  strSeq = seq[string]
  PkgName = distinct string
  PkgBuildStatus {.pure.} = enum OK, Failed, Timeout
  PkgDocMetadata = ref object of RootObj
    fnames: strSeq
    building: bool
    build_time: Time
    expire_time: Time
    last_commitish: string
    build_output: string
    build_status: PkgBuildStatus
    version: string

  RssItem = object
    title, desc, url, guid, pubDate: string

# the pkg name is normalized
var pkgs = newTable[string, Pkg]()
var pkgs_doc_files = newTable[string, PkgDocMetadata]()

# tag -> package name
var packages_by_tag = newTable[string, seq[string]]()
# word -> package name
var packages_by_description_word = newTable[string, seq[string]]()

# package access statistics
var most_queried_packages = initCountTable[string]()


# disk-persisted cache

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
  store(newFileStream(cache_fn, fmWrite), cache)

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
    # init cache
    #result.pkgs = newTable[string, Pkg]()
    result.pkgs_history = @[]
    result.save()
    log_debug "new cache created"



# HTML templates

include "templates/base.tmpl"
include "templates/home.tmpl"
include "templates/pkg.tmpl"
include "templates/pkg_list.tmpl"
include "templates/doc_files_list.tmpl"
include "templates/loader.tmpl"
include "templates/rss.tmpl"
include "templates/build_output.tmpl"

const
  success_badge = slurp "templates/success.svg"
  fail_badge = slurp "templates/fail.svg"
  version_badge_tpl = slurp template_path / "version-template-blue.svg"

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
  log_debug "loading $#" % conf.packages_list_fname
  pkgs.clear()
  let pkg_list = conf.packages_list_fname.parseFile
  for pdata in pkg_list:
    if not pdata.hasKey("name"):
      continue
    if not pdata.hasKey("tags"):
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

  log_debug "writing $#" % conf.packages_list_fname
  conf.packages_list_fname.writeFile(conf.packages_list_fname.readFile)


proc cleanupWhitespace(s: string): string

proc save_packages() =
  ## Save packages.json
  var new_pkgs = newJArray()
  for pname in toSeq(pkgs.keys()).sorted(system.cmp):
    new_pkgs.add pkgs[pname]

  conf.packages_list_fname.writeFile(new_pkgs.pretty.cleanupWhitespace)

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

proc fetch_github_readme*(pkg: Pkg, owner_repo_name: string) =
  ## Fetch README.* from GitHub
  log_debug "fetching GH readme ", github_readme_tpl % owner_repo_name
  try:
    let readme = getContent(github_readme_tpl % owner_repo_name,
    extraHeaders=github_readme_header & github_token)
    pkg["github_readme"] = newJString readme
  except:
    log_debug "failed to fetch GH readme"
    log_debug getCurrentExceptionMsg()
    pkg["github_readme"] = newJString ""

proc fetch_github_doc_pages(pkg: Pkg, owner, repo_name: string) =
  ## Fetch documentation pages from GitHub
  let url = github_doc_index_tpl % [owner.toLower, repo_name]
  log_debug "Checking ", url
  if get(url).status.startsWith("200"):
    pkg["doc"] = newJString url

proc fetch_github_packages_json(): string =
  ## Fetch packages.json from GitHub
  log_debug "fetching ", github_packages_json_raw_url
  return getContent(github_packages_json_raw_url)

proc `+`(t1, t2: Time): Time {.borrow.}

type RunOutput = tuple[exit_code: int, elapsed: float, output: string]

proc run_process(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: varargs[string, `$`]): string {.discardable.} =
  ## Run command with timeout
  # TODO: async

  log_debug "running: <" & bin_path & " " & join(args, " ") & "> in " & work_dir

  var p = startProcess(
    bin_path, args=args,
    workingDir=work_dir
  )
  if p.waitForExit(timeout=timeout * 1000) == 0:
    log_debug "$# successful" % desc
    let stdout_str = p.outputStream().readAll()
    if log_output:
      if stdout_str.len > 0:
        log_debug "Stdout: ---\n$#---" % stdout_str
      let stderr_str = p.errorStream().readAll()
      if stderr_str.len > 0:
        log_debug "Stderr: ---\n$#---" % stderr_str
    return stdout_str

  error "$# failed" % desc
  error "Stdout: ---\n$#---" % p.outputStream().readAll()
  error "Stderr: ---\n$#---" % p.errorStream().readAll()
  raise newException(ProcessError, "$# failed" % desc)

proc run_process2(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: seq[string]): Future[RunOutput] {.async.} =
  ## Run command with timeout
  let
    t0 = epochTime()
    p = startProcess(
      bin_path,
      args=args,
      workingDir=work_dir,
      options={poStdErrToStdOut}
    )
    pid = p.processID()

  var exit_code = 0
  var output = ""
  while true:
    let elapsed = epochTime() - t0
    if elapsed > timeout.float:
      log_debug "timed out!"
      p.kill()
      exit_code = -2
      break

    let new_output = p.outputStream().readAll()
    output.add new_output
    for line in new_output.splitLines():
      log_debug "$#>>> $#" % [$pid, line]

    exit_code = p.peekExitCode()
    case exit_code:
    of -1:
      # -1: still running, wait
      log_debug "waiting $#..." % $pid
      await sleepAsync 300

    of 0:
      discard p.waitForExit()
      break

    else:
      discard p.waitForExit()
      break

  let elapsed = epochTime() - t0
  return (exit_code, elapsed, output)


proc fetch_github_versions(pkg: Pkg, owner_repo_name: string) =
  ## Fetch versions from GH from releases and tags
  ## Set github_versions, github_latest_version, github_latest_version_url
  log_debug "fetching GH tags ", github_tags_tpl % owner_repo_name
  var version_names = newJArray()
  try:
    let tags = getContent(github_tags_tpl % owner_repo_name,
    extraHeaders=github_token).parseJson
    for t in tags:
      var name = t["name"].str
      if name.startsWith("v"):
        name = name[1..^0]
      if name.len > 0:
        version_names.add newJString name
  except:
    log_info getCurrentExceptionMsg()
    pkg["github_versions"] = version_names
    pkg["github_latest_version"] = newJString "none"
    pkg["github_latest_version_url"] = newJString ""
    return

  pkg["github_versions"] = version_names
  log_debug "fetched $# GH versions" % $len(version_names)

  log_debug "fetching GH latest vers ", github_latest_version_tpl % owner_repo_name
  try:
    let latest_version = getContent(github_latest_version_tpl % owner_repo_name,
      extraHeaders=github_token).parseJson
    var latest_version_name = latest_version["name"].str
    if latest_version_name.startsWith("v"):
      latest_version_name = latest_version_name[1..^0]
    pkg["github_latest_version"] = newJString latest_version_name
    pkg["github_latest_version_url"] = newJString latest_version["tarball_url"].str
    pkg["github_latest_version_time"] = newJString latest_version["published_at"].str
  except:
    log_debug getCurrentExceptionMsg()
    log_debug "No releases - falling back to tags"
    var latest = "0"
    for v in version_names:
      if v.str > latest:
        latest = v.str

    if latest == "0":
      pkg["github_latest_version"] = newJString "none"
      pkg["github_latest_version_url"] = newJString ""
    else:
      pkg["github_latest_version"] = newJString latest
      pkg["github_latest_version_url"] = newJString(
        "https://github.com/$#/archive/v$#.tar.gz" % [owner_repo_name, latest]
      )

    pkg["github_latest_version_time"] = newJString ""


# proc fetch_using_git(pname, url: string): bool =
#   let repo_dir =  tmp_nimble_root_dir / pname
#   if not repo_dir.existsDir():
#     log_debug "checking out $#" % url
#     run_process_old(git_bin_path, "git clone", tmp_nimble_root_dir, 60, false,
#     "clone", url, pname)
#   else:
#     log_debug "git pull-ing $#" % url
#     run_process_old(git_bin_path, "git pull", repo_dir, 60, false,
#     "pull")
# 
#   let commitish = run_process_old(git_bin_path, "git rev-parse", repo_dir,
#   1, false,
#   "rev-parse", "--verify", "HEAD")
# 
#   if commitish == pkgs_doc_files[pname].last_commitish:
#     pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time
#     #pkgs_doc_files[pname].building = false # unlock
#     log_debug "no changes to repo"
#     return false
# 
#   return true


proc fetch_and_build_pkg_using_nimble_old(pname: string) {.async.} =
  ##
  let tmp_dir = tmp_nimble_root_dir / pname
  log_debug "Starting nimble install $# --nimbleDir=$# -y" % [pname, tmp_dir]
  let po = await run_process2(
      nimble_bin_path,
      "nimble",
      ".",
      build_timeout_seconds,
      true,
      @["install", $pname, "--nimbleDir=$#" % tmp_dir, "-y", "--debug"],
    )

  let build_status: PkgBuildStatus =
    if po.exit_code == 0:
      PkgBuildStatus.OK
    elif po.exit_code == -2:
      PkgBuildStatus.Timeout
    else:
      PkgBuildStatus.Failed

  log_debug "Setting status ", build_status

  pkgs_doc_files[pname].build_output = po.output
  pkgs_doc_files[pname].build_status = build_status
  pkgs_doc_files[pname].build_time = getTime()
  pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time

# proc fetch_pkg_using_nimble(pname: string): bool =
#   let pkg_install_dir = tmp_nimble_root_dir / pname
# 
#   var outp = run_process_old(nimble_bin_path, "nimble update",
#     tmp_nimble_root_dir, 10, true,
#     "update", " --nimbleDir=" & tmp_nimble_root_dir)
#   assert outp.contains("Done")
# 
#   #if not tmp_nimble_root_dir.existsDir():
#   outp = ""
#   if true:
#     # First install
#     log_debug tmp_nimble_root_dir, " is not existing"
#     outp = run_process_old(nimble_bin_path, "nimble install", tmp_nimble_root_dir,
#       60, true,
#       "install", pname, " --nimbleDir=./nyan", "-y")
#     log_debug "Install successful"
# 
#   else:
#     # Update pkg
#     #outp = run_process_old(nimble_bin_path, "nimble install", "/", 60, true,
#     #  "install", pname, " --nimbleDir=" & tmp_nimble_root_dir, "-y")
#     #  FIXME
#     log_debug "Update successful"
# 
#   pkgs_doc_files[pname].build_output = outp
#   return true

proc locate_pkg_root_dir(pname: string): string =
  ## Locate installed pkg root dir
  # Full path example:
  # /dev/shm/nim_package_dir/nimgame2/pkgs/nimgame2-0.1.0
  let pkgs_dir = tmp_nimble_root_dir / pname / "pkgs"
  log_debug "scanning dir $#" % pkgs_dir
  for kind, path in walkDir(pkgs_dir, relative=true):
    log_debug "scanning $#" % path
    # FIXME: better heuristic
    if path.contains('-'):
      let chunks = path.split('-', maxsplit=1)
      if chunks[0].normalize() == pname:
        result = pkgs_dir / path
        log_debug "Found pkg root: ", result
        return

  raise newException(Exception, "Root dir for $# not found" % pname)

proc build_docs(pname: string): strSeq =
  ## Build docs
  result = @[]
  let pkg_root_dir = locate_pkg_root_dir(pname)
  log_debug "Walking ", pkg_root_dir
  #for fname in pkg_root_dir.walkDirRec(filter={pcFile}): # Bug in walkDirRec
  for fname in pkg_root_dir.walkDirRec():
    #log_debug "Walking ", fname
    if not fname.endswith(".nim"):
      continue
    log_debug "running nim doc for $#" % fname
    run_process(nim_bin_path, "nim doc", pkg_root_dir, 60, true,
      "doc", fname)
    result.add fname[pkg_root_dir.len..^1][1..^4] & "html"
    log_debug "adding ", fname[pkg_root_dir.len..^1][1..^4] & "html"

proc fetch_and_build_pkg_if_needed(pname: string) {.async.} =
  ## Fetch package and build docs
  ## Modifies pkgs_doc_files

  # PkgDocMetadata state machine: nothing -> building:true <-> building:false
  if pkgs_doc_files.hasKey(pname):

    if pkgs_doc_files[pname].expire_time > getTime():
      # No need to rebuild yet
      return

    # Wait on any existing pkg building task to finish
    let t0 = epochTime()
    while pkgs_doc_files[pname].building == true:
      let elapsed = epochTime() - t0
      if elapsed > build_timeout_seconds:
        log_debug "timed out!"
        break
      log_debug "waiting already running build for $# $#s..." % [pname, $int(elapsed)]
      await sleepAsync 500

    if pkgs_doc_files[pname].expire_time > getTime():
      # No need to rebuild yet
      return

  else:
    # The package has never been built before: start first build
    let pm = PkgDocMetadata(
      build_time: getTime(),
      expire_time: getTime() + build_expiry_time,
      fnames: @[],
      building: true,
      )
    pkgs_doc_files[pname] = pm


  # Fetch or update pkg
  let url = pkgs[pname]["url"].str

  #if fetch_using_git(pname, url) == false:
  #if fetch_pkg_using_nimble(pname) == false:

  pkgs_doc_files[pname].building = true # lock
  await fetch_and_build_pkg_using_nimble_old(pname)
  pkgs_doc_files[pname].building = false # unlock

  if pkgs_doc_files[pname].build_status != PkgBuildStatus.OK:
    log_debug "fetch_and_build_pkg_if_needed failed - skipping doc generation"
    return

  let fnames = build_docs(pname)
  log_debug "Generated $# html files" % $fnames.len
  pkgs_doc_files[pname].fnames = fnames

  #pkgs_doc_files[pname].last_commitish = commitish
  if pkgs[pname].hasKey("github_latest_version"):
    pkgs_doc_files[pname].version = pkgs[pname]["github_latest_version"].str
  else:
    log_debug "FIXME github_latest_version"
    pkgs_doc_files[pname].version = "unknown"

proc translate_term_colors*(outp: string): string =
  ## Translate terminal colors
  const sequences = @[
    ("[36m[2m", "<span>"),
    ("[32m[1m", """<span class="success">"""),
    ("[33m[1m", """<span class="red">"""),
    ("[36m[1m", """<span class="blue">"""),
    ("[0m[32m[0m", "</span>"),
    ("[0m[33m[0m", "</span>"),
    ("[0m[36m[0m", "</span>"),
    ("[2m", "<span>"),
    ("[36m", "<span>"),
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

routes:

  get "/":
    log request
    try:
      let top_pkg_names = top_keys(most_queried_packages, 5)
      log_debug "pkgs history len: $#" % $cache.pkgs_history.len
      var new_pkg_names: seq[string] = @[]
      for item in cache.pkgs_history:
        new_pkg_names.add item.name
        if new_pkg_names.len > 5:
          break

      resp base_page(generate_home_page(top_pkg_names, new_pkg_names))
    except:
      error getCurrentExceptionMsg()
      halt Http400

  get "/search":
    log request
    let found_pkg_names = search_packages(@"query")

    var pkgs_list: seq[Pkg] = @[]
    for pn in found_pkg_names.keys():
      pkgs_list.add pkgs[pn]

    resp base_page(generate_pkg_list_page(pkgs_list))

  get "/pkg/@pkg_name/?":
    log request
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page "Package not found"

    most_queried_packages.inc pname
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
        var owner_repo_name = "$#/$#" % url.split('/')[3..4]
        if owner_repo_name.endswith(".git"):
          owner_repo_name = owner_repo_name[0..^5]
        pkg["github_owner"] = newJString owner
        pkg.fetch_github_readme(owner_repo_name)
        pkg.fetch_github_versions(owner_repo_name)
        pkg.fetch_github_doc_pages(owner, repo_name)

    resp base_page(generate_pkg_page(pkg))

  post "/update_package":
    ## Create or update a package description
    log request
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
          info "Another package named $# already exists" % existing_pn
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
    save_packages()
    log_info if pkg_already_exists: "Updated existing package $#" % name
      else: "Added new package $#" % name
    resp base_page("OK")

  get "/packages.json":
    ## Serve the packages list file
    log request
    resp conf.packages_list_fname.readFile

  get "/docs/@pkg_name/?":
    ## Serve hosted docs for a package: summary page
    log request
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page("<p>Package not found</p>")

    most_queried_packages.inc pname
    let pkg = pkgs[pname]

    # Check out pkg and build docs. Modifies pkgs_doc_files
    await fetch_and_build_pkg_if_needed(pname)

    # Show files summary
    resp base_page(
      generate_doc_files_list_page(pname, pkgs_doc_files[pname])
    )

  #get "/docs/@pkg_name_and_doc_path":
  get "/docs/@pkg_name/@a?/?@b?/?@c?/?@d?":
    ## Serve hosted docs for a package
    log request
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page("<p>Package not found</p>")

    most_queried_packages.inc pname
    let pkg = pkgs[pname]

    # Check out pkg and build docs. Modifies pkgs_doc_files
    await fetch_and_build_pkg_if_needed(pname)

    let pkg_root_dir =
      try:
        locate_pkg_root_dir(pname)
      except:
        halt Http400
        ""

    # Horrible hack
    let messy_path = @"a" / @"b" / @"c" / @"d"
    let doc_path = strip(messy_path, true, true, {'/'})

    if not doc_path.endswith(".html"):
      log_debug "Refusing to serve doc path $# $#" % [pname, doc_path]
      halt Http400

    log_debug "Attempting to serve doc path $# $#" % [pname, doc_path]

    # Example:
    # https://nimpkgdir.firelet.net/docs/nimgame2/nimgame2/audio.html
    # From:
    # /dev/shm/nim_package_dir/nimgame2/pkgs/nimgame2-0.1.0/nimgame2/audio.html

    let fn = pkg_root_dir / doc_path
    if not existsFile(fn):
      log_info "serving $# - not found" % fn
      resp base_page """
        <p>Sorry, that file does not exists.
        <a href="/pkg/$#">Go back to $#</a>
        </p>
        """ % [pname, pname]

    # Serve doc file
    let head = """<h4>Doc files for <a href="/pkg/$#">$#</a></h4>""" % [pname, pname]
    let page = head & fn.readFile()
    resp base_page(page)

  get "/loader":
    log request
    resp base_page(
      generate_loader_page()
    )

  get "/packages.xml":
    ## New and updated packages feed
    log request
    let baseurl = conf.public_baseurl
    let url = baseurl / "packages.xml"

    var rss_items: seq[RssItem] = @[]
    for item in cache.pkgs_history:
      let pn = item.name.normalize()
      if not pkgs.hasKey(pn):
        log_debug "skipping $#" % pn
        continue

      let pkg = pkgs[pn]
      let item_url = baseurl / "pkg" / pn
      let i = RssItem(
        title: pn,
        desc: pkg["description"].str,
        url: item_url,
        guid: item_url,
        pubdate: $item.first_seen_time
      )
      rss_items.add i

    let r = generate_rss_feed(
      title="Nim packages",
      desc="New and updated Nim packages",
      url=url,
      build_date="",
      pub_date="",
      ttl=3600,
      rss_items
    )
    resp(r, contentType="application/rss+xml")

  get "/stats":
    log request
    resp base_page """
    <br/>
    <p>Runtime: $#</p>
    <p>Queried packages count: $#</p>
    """ % [$cpuTime(), $len(most_queried_packages)]

  # CI Routing

  get "/ci":
    ## CI summary
    log request
    #@bottle.view('index')
    #refresh_build_num()
    discard

  get "/ci/install_report":
    log request
    discard

  get "/ci/badges/@pkg_name/version.svg":
    ## Version badge
    log request
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page "Package not found"

    most_queried_packages.inc pname
    await fetch_and_build_pkg_if_needed(pname)
    try:
      let md = pkgs_doc_files[pname]
      let version = md.version
      if version == nil:
        log_debug "Version is nil"
      let badge =
        if version == nil:
          version_badge_tpl % ["none", "none"]
        else:
          version_badge_tpl % [version, version]
      resp(badge, contentType = "image/svg+xml")
    except:
      log_debug getCurrentExceptionMsg()
      let badge = version_badge_tpl % ["none", "none"]
      resp(badge, contentType = "image/svg+xml")

  get "/ci/badges/@pkg_name/nimdevel/status.svg":
    ## Status badge
    log request
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page "Package not found"

    most_queried_packages.inc pname
    await fetch_and_build_pkg_if_needed(pname)
    let md =
      try:
        pkgs_doc_files[pname]
      except KeyError:
        halt Http400
        nil
    let badge =
      case md.build_status
      of PkgBuildStatus.OK:
        success_badge
      of PkgBuildStatus.Failed:
        fail_badge
      of PkgBuildStatus.Timeout:
        fail_badge
    resp(badge, contentType = "image/svg+xml")

  get "/ci/badges/@pkg_name/nimdevel/output.html":
    ## Build output
    log request
    log_info "$#" % $request.ip
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page "Package not found"

    most_queried_packages.inc pname
    await fetch_and_build_pkg_if_needed(pname)
    try:
      let outp = pkgs_doc_files[pname].build_output
      let build_output = translate_term_colors(outp)
      resp base_page(generate_build_output_page(
        pname,
        build_output,
        pkgs_doc_files[pname].build_time,
        pkgs_doc_files[pname].expire_time,
      ))
    except KeyError:
      halt Http400

  get "/robots.txt":
    ## Serve robots.txt to throttle bots
    resp "User-agent: *\nCrawl-delay: 300\n"


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



#def refresh_nim_version(basepath):
#    """Refresh Nim version from the last successful build
#    """
#    global last_successful_nim_version
#    try:
#        r = requests.get(basepath + 'release_tarball_name')
#        v = r.text.strip().split('/')[-1]
#        assert v.startswith('nim-')
#        last_successful_nim_version = v[4:-7]
#    except Exception as e:
#        print(e)
#        pass
#
#
#
#def start_build_if_needed():
#    rebuild_nim, run_install_test, reason = \
#        repo_monitor.check(rebuild_nim=False, run_install_test=False)
#    if reason:
#        start_build(rebuild_nim=rebuild_nim, reason=reason,
#                    run_install_test=run_install_test)
#        return True
#    return False
#
#
#def timed_start_build_if_needed():
#    Timer(REBUILD_CHECK_TIME, timed_start_build_if_needed).start()
#    start_build_if_needed()
#
#def send_status_email_if_needed():
#    pass
#
#def timed_send_status_email_if_needed():
#    Timer(REBUILD_CHECK_TIME, timed_start_build_if_needed).start()
#    send_status_email_if_needed()




#status_fn = os.path.expanduser("~/.nimci_cronjob.json")
#def load_status():
#    try:
#        with open(status_fn) as f:
#            return json.load(f)
#    except IOError:
#        return dict(nim_commit=None, nimble_commit=None, pkgs_commit=None)
#
#def save_status(st):
#    with open(status_fn, 'w') as f:
#        json.dump(st, f)



#
#def check(rebuild_nim=False, run_install_test=False):
#    changed_components = []
#    if not rebuild_nim:
#        status = load_status()
#        # rebuild Nim only if needed
#        last_nim_commit = fetch_last_commit(nim_commit_url)
#        last_nimble_commit = fetch_last_commit(nimble_commit_url)
#        if status['nim_commit'] != last_nim_commit:
#            changed_components.append('Nim')
#
#        if status['nimble_commit'] != last_nimble_commit:
#            changed_components.append('Nimble')
#
#        if changed_components:
#            rebuild_nim = True
#            status['nim_commit'] = last_nim_commit
#            status['nimble_commit'] = last_nimble_commit
#            save_status(status)
#
#    packages_changed = False
#    last_pkgs_commit = fetch_last_commit(pkgs_commit_url)
#    if status['pkgs_commit'] != last_pkgs_commit:
#        packages_changed = True
#        changed_components.append('Packages list')
#        status['pkgs_commit'] = last_pkgs_commit
#        save_status(status)
#
#    run_install_test = run_install_test or rebuild_nim or packages_changed
#
#    reason = "change in %s" % ', '.join(changed_components) \
#        if changed_components else None
#    return rebuild_nim, run_install_test, reason
#


proc start_nim_commit_polling(poll_time: TimeInterval) {.async.} =
  while true:
    await sleepAsync(poll_time.milliseconds)
    #FIXME asyncCheck

proc run_systemd_sdnotify_pinger(ping_time_s: int) {.async.} =
  ## Ping systemd watchdog using sd_notify
  const msg = "NOTIFY_SOCKET env var not found - disabling watchdog pinger"
  if not existsEnv("NOTIFY_SOCKET"):
    log_info msg
    echo msg
    return

  let sd = newSDNotify()
  sd.notify_ready()
  sd.notify_main_pid(getpid())
  while true:
    sd.ping_watchdog()
    await sleepAsync ping_time_s * 1000


proc run_github_packages_json_polling(poll_time_s: int) {.async.} =
  ## Poll GH for packages.json
  ## Overwrite packages.json local file!
  log_debug "starting GH packages.json polling"
  while true:
    await sleepAsync poll_time_s * 1000
    log_debug "Polling GitHub packages.json"
    try:
      let new_pkg_raw = fetch_github_packages_json()
      if new_pkg_raw == conf.packages_list_fname.readFile:
        log_debug "No changes"
        continue

      for pdata in new_pkg_raw.parseJson:
        if pdata.hasKey("name"):
          let pname = pdata["name"].str.normalize()
          if not pkgs.hasKey(pname):
            cache.pkgs_history.add PkgHistoryItem(name:pname, first_seen_time:getTime())
            log_debug "New pkg added on GH: $#" % pname

      cache.save()
      log_debug "writing $#" % conf.packages_list_fname
      conf.packages_list_fname.writeFile(new_pkg_raw)
      load_packages()

      for item in cache.pkgs_history:
        let pname = item.name.normalize()
        if not pkgs.hasKey(pname):
          log_debug "$# is gone" % pname

    except:
      error getCurrentExceptionMsg()





onSignal(SIGINT, SIGTERM):
  ## Exit signal handler
  info "Exiting"
  cache.save()
  #save_packages()
  quit()

proc main() =
  #setup_seccomp()
  log_info "starting"
  tmp_nimble_root_dir.createDir()
  load_packages()
  cache = load_cache()
  #asyncCheck start_nim_commit_polling(github_nim_commit_polling_time)
  asyncCheck run_systemd_sdnotify_pinger(sdnotify_ping_time_s)
  asyncCheck run_github_packages_json_polling(github_packages_json_polling_time_s)

  log_info "starting loop"
  runForever()

when isMainModule:
  main()
