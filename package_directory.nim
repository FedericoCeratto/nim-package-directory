#
# Nimble package directory
#
# Copyright 2016 Federico Ceratto <federico.ceratto@gmail.com>
# Released under GPLv3 License, see LICENSE file
#

import asyncdispatch,
 deques,
 httpclient,
 httpcore,
 json,
 os,
 osproc,
 parseopt,
 sequtils,
 streams,
 strutils,
 tables,
 times

from algorithm import sort, sorted, sortedByIt, reversed
from marshal import store, load
from posix import onSignal, SIGINT, SIGTERM, getpid
from times import epochTime

#from nimblepkg import getTagsListRemote, getVersionList
import jester,
  morelogging,
  sdnotify,
  statsd_client,
  zmq

import github,
  signatures,
  email,
  friendly_timeinterval,
  persist


const
  template_path = "./templates"
  build_timeout_seconds = 120
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_tags_tpl = "https://api.github.com/repos/$#/tags"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_doc_index_tpl = "https://$#.github.io/$#/index.html"
  github_repository_search_tpl = "https://api.github.com/search/repositories?q=language:nim+pushed:>$#&per_page=$#sort=$#&page=$#"
  github_readme_header = "Accept:application/vnd.github.v3.html\c\L"
  github_caching_time = 600
  github_packages_json_raw_url= "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  github_packages_json_polling_time_s = 10 * 60
  git_bin_path = "/usr/bin/git"
  sdnotify_ping_time_s = 1
  nim_bin_path = "/usr/bin/nim"
  nimble_bin_path = "/usr/bin/nimble"
  task_pubsub_port = 5583
  build_expiry_time = (15 * 60).Time
  cache_fn = ".cache.json"

  xml_no_cache_headers = {
    "Cache-Control": "no-cache, no-store, must-revalidate, max-age=0, proxy-revalidate, no-transform",
    "Expires": "0",
    "Pragma": "no-cache",
    "Content-Type": "image/svg+xml"
  }



# init

let conf = load_conf()
let github_token = "Authorization: token $#\c\L" % conf.github_token
let stats = newStatdClient(prefix="nim_package_directory")
let zmqsock = listen("tcp://*:" & $task_pubsub_port, mode=PUB)

when defined(systemd):
  let log = newJournaldLogger()
else:
  let log = newAsyncFileLogger()


proc log_debug(args: varargs[string, `$`]) =
  log.debug(args.join(" "))

proc log_info(args: varargs[string, `$`]) =
  log.info(args.join(" "))

proc log_req(request: Request) =
  ## Log request data
  var path = ""
  for c in request.path:
    if len(path) > 300:
      path.add "..."
      break
    let o = c.ord
    if o < 32 or o > 126:
      path.add o.toHex()
    else:
      path.add c

  log_info "serving $# $# $#" % [request.ip, $request.reqMeth, path]

log_debug conf

type
  ProcessError = object of Exception
  Pkg* = JsonNode
  Pkgs* = TableRef[string, Pkg]
  strSeq = seq[string]
  PkgName = distinct string
  BuildStatus {.pure.} = enum OK, Failed, Timeout, Running
  DocBuildOutItem = object
    success_flag: bool
    filename, desc, output: string
  DocBuildOut = seq[DocBuildOutItem]
  PkgDocMetadata = object of RootObj
    fnames: strSeq
    idx_fnames: strSeq
    building: bool
    build_time: Time
    expire_time: Time
    last_commitish: string
    build_status: BuildStatus
    build_output: string
    doc_build_status: BuildStatus
    doc_build_output: DocBuildOut
    version: string

  RssItem = object
    title, desc, url, guid, pubDate: string
  BuildHistoryItem = tuple
    name: string
    build_time: Time
    build_status: BuildStatus
    doc_build_status: BuildStatus
  JsonDocPkgItem = object
    code, desc, itype, filepath: string
    line, col: int
  JsonDocPkgItems = seq[JsonDocPkgItem]

# the pkg name is normalized
var pkgs: Pkgs = newTable[string, Pkg]()
type PkgsDocFilesTable = Table[string, PkgDocMetadata]
# package name -> PkgDocMetadata
# initialized by scan_pkgs_dir
var pkgs_doc_files = newTable[string, PkgDocMetadata]()

# tag -> package name
# initialized/updated by load_packages
var packages_by_tag = newTable[string, seq[string]]()
# word -> package name
# word -> package name
# initialized/updated by load_packages
var packages_by_description_word = newTable[string, seq[string]]()

# package access statistics
# initialized by scan_pkgs_dir
var jsondoc_items = newTable[string, JsonDocPkgItems]()

# package access statistics
# volatile
var most_queried_packages = initCountTable[string]()

# build history
# volatile
const build_history_size = 100
var build_history = initDeque[BuildHistoryItem]()

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
  let f = newFileStream(cache_fn, fmWrite)
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

proc uniescape(inp: string): string =
  result = ""
  for c in inp:
    let o = c.ord
    if o < 32 or o > 126:
      let q = "\\u00" & o.toHex()[^2..^1]
      result.add q
    else:
      result.add c

proc save_pkg_metadata(j: PkgDocMetadata, fn: string) =
  ## Save package metadata
  log_debug "Saving to $#" % fn
  var k = PkgDocMetadata()
  deepCopy[PkgDocMetadata](k, j)
  let f = newFileStream(fn, fmWrite)
  k.build_output = uniescape(j.build_output)
  if j.version.endswith("\0"):
    k.version = k.version.strip
  f.store(k)
  f.close()

proc load_metadata(fn: string): PkgDocMetadata =
  ## load package metadata
  log_debug "Loading $#" % fn
  load(newFileStream(fn, fmRead), result)

proc scan_pkgs_dir(pkgs_root: string) =
  ## scan all packages dirs, populate jsondoc_items and pkgs_doc_files
  let pattern = pkgs_root / "*" / "nimpkgdir.json"
  # e.g /var/lib/nim_package_directory/cache/*/nimpkgdir.json
  log_info "scanning pattern '" & pattern & "'"
  for x in walkPattern(pattern):
    try:
      let pm: PkgDocMetadata = load_metadata(x)
    except:
      # ignore metadata
      log_info "Load error: " & getCurrentExceptionMsg()
  log_info "----"
  discard

# volatile caches

var volatile_cache_github_trending_last_update_time = 0
var volatile_cache_github_trending: seq[JsonNode] = @[]


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
  build_success_badge = slurp "templates/success.svg"
  build_fail_badge = slurp "templates/fail.svg"
  build_running_badge = slurp "templates/build_running.svg"
  doc_success_badge = slurp "templates/doc_success.svg"
  doc_fail_badge = slurp "templates/doc_fail.svg"
  doc_running_badge = slurp "templates/doc_running.svg"
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
        continue  # ignore short words
      let word = orig_word.toLowerAscii
      if not packages_by_description_word.hasKey(word):
        packages_by_description_word[word] = @[]
      packages_by_description_word[word].add pdata["name"].str

  log_info "Loaded ", $pkgs.len, " packages"

  #log_debug "writing $#" % conf.packages_list_fname
  #conf.packages_list_fname.writeFile(conf.packages_list_fname.readFile)


proc cleanupWhitespace(s: string): string

proc save_packages() =
  ## Save packages.json
  var new_pkgs = newJArray()
  for pname in toSeq(pkgs.keys()).sorted(system.cmp):
    new_pkgs.add pkgs[pname]

  conf.packages_list_fname.writeFile(new_pkgs.pretty.cleanupWhitespace)

proc search_packages*(query: string): CountTable[string] =
  ## Search packages by name, tag and keyword
  let query = query.strip.toLowerAscii.split({' ', ','})
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
    if packages_by_description_word.has_key(item.toLowerAscii):
      for pn in packages_by_description_word[item.toLowerAscii]:
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
  let url = github_doc_index_tpl % [owner.toLowerAscii, repo_name]
  log_debug "Checking ", url
  if get(url).status.startsWith("200"):
    pkg["doc"] = newJString url

proc fetch_github_packages_json(): string =
  ## Fetch packages.json from GitHub
  log_debug "fetching ", github_packages_json_raw_url
  getContent(github_packages_json_raw_url)

proc append(build_history: var Deque[BuildHistoryItem], name: string,
    build_time: Time, build_status, doc_build_status: BuildStatus) =
  ## Add BuildHistoryItem to build history
  if build_history.len == build_history_size:
    discard build_history.popLast
  let i: BuildHistoryItem = (name, build_time, build_status, doc_build_status)
  build_history.addFirst(i)

proc `+`(t1, t2: Time): Time {.borrow.}

type RunOutput = tuple[exit_code: int, elapsed: float, output: string]

proc run_process(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: varargs[string, `$`]): (bool, string) {.discardable.} =
  ## Run command with timeout
  # TODO: async

  log_debug "running: <" & bin_path & " " & join(args, " ") & "> in " & work_dir

  var p = startProcess(
    bin_path, args=args,
    workingDir=work_dir,
    options={poStdErrToStdOut}
  )
  let exit_val = p.waitForExit(timeout=timeout * 1000)
  let stdout_str = p.outputStream().readAll()

  if log_output or (exit_val != 0):
    if stdout_str.len > 0:
      log_debug "Stdout: ---\n$#---" % stdout_str

  if exit_val == 0:
    log_debug "$# successful" % desc
  else:
    log.error "run_process: $# failed, exit value: $#" % [desc, $exit_val]
  return ((exit_val == 0), stdout_str)

proc run_process2(bin_path, desc, work_dir: string,
    timeout: int, log_output: bool,
    args: seq[string]): Future[RunOutput] {.async.} =
  ## Run command asyncronously with timeout
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
  var sleep_time_ms = 50
  while true:
    let elapsed = epochTime() - t0
    if elapsed > timeout.float:
      log_debug "timed out!"
      p.kill()
      exit_code = -2
      break

    exit_code = p.peekExitCode()
    case exit_code:
    of -1:
      # -1: still running, wait
      # log_debug "waiting command thread $#..." % $pid
      await sleepAsync sleep_time_ms
      if sleep_time_ms < 1000:
        sleep_time_ms *= 2

    of 0:
      discard p.waitForExit()
      break

    else:
      discard p.waitForExit()
      break

  let elapsed = epochTime() - t0

  var output = ""
  let new_output = p.outputStream().readAll()
  output.add new_output

  for line in new_output.splitLines():
    log_debug "[$#] $#> $#" % [$pid, $exit_code, line]

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
    var latest_version_name = latest_version["name"].str.strip
    if latest_version_name.startsWith("v"):
      latest_version_name = latest_version_name.strip(trailing=false, chars={'v'})
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
      pkg["github_latest_version"] = newJString latest.strip
      pkg["github_latest_version_url"] = newJString(
        "https://github.com/$#/archive/v$#.tar.gz" % [owner_repo_name, latest]
      )

    pkg["github_latest_version_time"] = newJString ""

proc fetch_github_repository_stats(sorting="updated", pagenum=1, limit=200, initial_date: TimeInfo): seq[JsonNode] =
  ## Fetch projects on GitHub
  let date = initial_date.format("yyyy-MM-dd")
  let q = github_repository_search_tpl % [date, $limit, sorting, $pagenum]
  log_info "Searching GH repos: '$#'" % q
  let query_res = getContent(q, extraHeaders=github_token).parseJson
  if sorting == "updated":
    return query_res["items"].elems.sortedByIt(it["updated_at"].str).reversed()
  return query_res["items"].elems

proc github_trending_packages(request: Request, pkgs: Pkgs): seq[JsonNode] =
  ## Trending GitHub packages
  # TODO: Dom: merge this into the procedure above ^

  if volatile_cache_github_trending_last_update_time +
      github_caching_time > epochTime().int:
    return volatile_cache_github_trending

  result = @[]
  let pkgs_list = fetch_github_repository_stats(
    sorting="updated", pagenum=1, limit=20,
    initial_date=utc(getTime() - 14.days)
  )
  var website_to_name = initTable[string, string]()
  for it in pkgs.values:
    if it.hasKey("web"):
      website_to_name[it["web"].str] = it["name"].str

  for p in pkgs_list:
    try:
      # 2017-07-21T12:48:35Z
      let t = p["pushed_at"].str.parse("yyyy-MM-ddTHH:mm:ss")
      let d = toFriendlyInterval(t.toTime, getTime(), approx=2)
      p["update_age"] = newJString d
    except:
      p["update_age"] = newJString ""

    let url = p["html_url"].str
    if website_to_name.hasKey url:
      # The package is known to Nimble - set the "official" package name
      p["name"].str = website_to_name[url]
      result.add p

  volatile_cache_github_trending = result
  volatile_cache_github_trending_last_update_time = epochTime().int




# proc fetch_using_git(pname, url: string): bool =
#   let repo_dir =  conf.tmp_nimble_root_dir / pname
#   if not repo_dir.existsDir():
#     log_debug "checking out $#" % url
#     run_process_old(git_bin_path, "git clone", conf.tmp_nimble_root_dir, 60, false,
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
  ## Run nimble install for a package using a dedicated directory
  let tmp_dir = conf.tmp_nimble_root_dir / pname
  log_debug "Starting nimble install $# --verbose --nimbleDir=$# -y" % [pname, tmp_dir]
  let po = await run_process2(
      nimble_bin_path,
      "nimble",
      ".",
      build_timeout_seconds,
      true,
      @["install", $pname, "--verbose", "--nimbleDir=$#" % tmp_dir, "-y", "--debug"],
    )

  let build_status: BuildStatus =
    if po.exit_code == 0:
      BuildStatus.OK
    elif po.exit_code == -2:
      BuildStatus.Timeout
    else:
      BuildStatus.Failed

  log_debug "Setting status ", build_status

  pkgs_doc_files[pname].build_status = build_status
  if build_status == BuildStatus.Timeout:
    pkgs_doc_files[pname].build_output = "** Install test timed out after " & $build_timeout_seconds & " seconds **\n\n" & po.output
  else:
    pkgs_doc_files[pname].build_output = po.output

  pkgs_doc_files[pname].build_time = getTime()
  pkgs_doc_files[pname].expire_time = getTime() + build_expiry_time

# proc fetch_pkg_using_nimble(pname: string): bool =
#   let pkg_install_dir = conf.tmp_nimble_root_dir / pname
#
#   var outp = run_process_old(nimble_bin_path, "nimble update",
#     conf.tmp_nimble_root_dir, 10, true,
#     "update", " --nimbleDir=" & conf.tmp_nimble_root_dir)
#   assert outp.contains("Done")
#
#   #if not conf.tmp_nimble_root_dir.existsDir():
#   outp = ""
#   if true:
#     # First install
#     log_debug conf.tmp_nimble_root_dir, " is not existing"
#     outp = run_process_old(nimble_bin_path, "nimble install", conf.tmp_nimble_root_dir,
#       60, true,
#       "install", pname, " --nimbleDir=./nyan", "-y")
#     log_debug "Install successful"
#
#   else:
#     # Update pkg
#     #outp = run_process_old(nimble_bin_path, "nimble install", "/", 60, true,
#     #  "install", pname, " --nimbleDir=" & conf.tmp_nimble_root_dir, "-y")
#     #  FIXME
#     log_debug "Update successful"
#
#   pkgs_doc_files[pname].build_output = outp
#   return true

proc package_parent_dir(pname: string): string =
  ## Generate pkg parent dir
  # Full path example:
  # /var/lib/nim_package_dir/nimgame2
  conf.tmp_nimble_root_dir / pname

proc locate_pkg_root_dir(pname: string): string =
  ## Locate installed pkg root dir
  # Full path example:
  # /dev/shm/nim_package_dir/nimgame2/pkgs/nimgame2-0.1.0
  let pkgs_dir = conf.tmp_nimble_root_dir / pname / "pkgs"
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

proc build_docs(pname: string) {.async.} =
  ## Build docs
  let pkg_root_dir = locate_pkg_root_dir(pname)
  log_debug "Walking ", pkg_root_dir
  #for fname in pkg_root_dir.walkDirRec(filter={pcFile}): # Bug in walkDirRec
  var all_output: DocBuildOut = @[]
  var generated_doc_fnames: seq[string] = @[]
  var generated_idx_fnames: seq[string] = @[]

  var input_fnames: seq[string] = @[]
  for fname in pkg_root_dir.walkDirRec():
    if fname.endswith(".nim"):
      input_fnames.add fname

  for fname in input_fnames:
    log_debug "running nim doc for $#" % fname

    # TODO: enable --docSeeSrcUrl:<url>

    let desc = "nim doc --index:on $#" % fname
    let run_dir = fname.splitPath.head
    let po = await run_process2(
      nim_bin_path,
      desc,
      run_dir,
      10,
      true,
      @["doc", "--index:on", fname],
    )
    let success = (po.exit_code == 0)
    all_output.add DocBuildOutItem(
      success_flag:success,
      filename:fname,
      desc:desc,
      output:po.output
    )
    if success:
      # trim away <pkg_root_dir> and ".nim"
      let basename = fname[pkg_root_dir.len..^5]
      generated_doc_fnames.add basename & ".html"
      log_debug "adding ", basename & ".html"

      for kind, path in walkDir(pkg_root_dir, relative=true):
        if path.endswith(".idx"):
          #generated_idx_fnames.add basename & ".idx"
          #idx_filenames.add path
          log_debug "adding ", pkg_root_dir & " > " & path
          #let chunks = path.split('-', maxsplit=1)
          #if chunks[0].normalize() == pname:
          #  result = pkgs_dir / path

  pkgs_doc_files[pname].doc_build_output = all_output
  pkgs_doc_files[pname].fnames = generated_doc_fnames
  pkgs_doc_files[pname].idx_fnames = generated_idx_fnames
  pkgs_doc_files[pname].doc_build_status =
    if (input_fnames.len == generated_doc_fnames.len): BuildStatus.OK
    else: BuildStatus.Failed

include "templates/jsondoc_items.tmpl"
proc generate_jsondoc(pname: string) {.async.} =
  ## Generate jsondoc items
  let pkg_root_dir = locate_pkg_root_dir(pname)
  log_debug "Walking ", pkg_root_dir

  var input_fnames: seq[string] = @[]
  for fname in pkg_root_dir.walkDirRec():
    if fname.endswith(".nim"):
      input_fnames.add fname

  for fname in input_fnames:
    let desc = "nim jsondoc $#" % fname
    log_debug "running " & desc
    let run_dir = fname.splitPath.head
    let po = await run_process2(
      nim_bin_path,
      desc,
      run_dir,
      10,
      true,
      @["jsondoc", fname],
    )
    let success = (po.exit_code == 0)
    if success:
      # replace ".nim" with ".json"
      let json_fn = fname[0..^5] & ".json"
      try:
        let j = parseJson(readFile(json_fn))
        for chunk in j:
          let item_name = chunk["name"].getStr()
          let item = JsonDocPkgItem(
            itype:chunk["type"].getStr(),
            desc:chunk{"description"}.getStr(),
            code:chunk["code"].getStr(),
            filepath:fname[pkg_root_dir.len..^1],
            line:chunk["line"].getInt(),
            col:chunk["col"].getInt(),
          )
          if not jsondoc_items.hasKey(item_name):
            jsondoc_items[item_name] = @[]
          jsondoc_items[item_name].add(item)
          log_debug jsondoc_items[item_name]

      except:
        log_debug "failed to read and parse " & json_fn & " : " & getCurrentExceptionMsg()


proc fetch_and_build_pkg_if_needed(pname: string, force_rebuild=false) {.async.} =
  ## Fetch package and build docs
  ## Modifies pkgs_doc_files

  # PkgDocMetadata state machine: nothing -> building:true <-> building:false
  if pkgs_doc_files.hasKey(pname):
    # A build has been already done or is currently running.

    # Wait on any existing pkg building task to finish
    let t0 = epochTime()
    var sleep_time_ms = 50
    while pkgs_doc_files[pname].building == true:
      let elapsed = epochTime() - t0
      if elapsed > build_timeout_seconds:
        log_debug "timed out!"
        stats.incr("build_timed_out")
        break
      log_debug "waiting already running build for $# $#s..." % [pname, $int(elapsed)]
      await sleepAsync sleep_time_ms
      if sleep_time_ms < 1000:
        sleep_time_ms *= 2

    if not force_rebuild and pkgs_doc_files[pname].expire_time > getTime():
      # No need to rebuild yet
      return

  else:
    # The package has never been built before: start first build
    let pm = PkgDocMetadata(
      build_time: getTime(),
      expire_time: getTime() + build_expiry_time,
      fnames: @[],
      idx_fnames: @[],
      building: true,
      build_status: BuildStatus.Running,
      doc_build_status: BuildStatus.Running,
    )
    pkgs_doc_files[pname] = pm

  # Fetch or update pkg
  let url = pkgs[pname]["url"].str

  pkgs_doc_files[pname].building = true # lock
  zmqsock.send("build:start " & pname)
  try:
    let t0 = epochTime()
    await fetch_and_build_pkg_using_nimble_old(pname)
    let elapsed = epochTime() - t0
    stats.gauge("build_time", elapsed)
  except:
    pkgs_doc_files[pname].building = false # unlock
    raise

  if pkgs_doc_files[pname].build_status != BuildStatus.OK:
    pkgs_doc_files[pname].building = false # unlock
    log_debug "fetch_and_build_pkg_if_needed failed - skipping doc generation"
    stats.incr("build_failed")
    build_history.append(
      pname,
      pkgs_doc_files[pname].build_time,
      pkgs_doc_files[pname].build_status,
      pkgs_doc_files[pname].doc_build_status
    )
    save_pkg_metadata(pkgs_doc_files[pname], package_parent_dir(pname) & "/nimpkgdir.json")
    return  # install failed

  stats.incr("build_succeded")

  try:
    let t1 = epochTime()
    await build_docs(pname)  # this can raise
    let elapsed = epochTime() - t1
    stats.gauge("doc_build_time", elapsed)
  finally:
    pkgs_doc_files[pname].building = false # unlock

  build_history.append(
    pname,
    pkgs_doc_files[pname].build_time,
    pkgs_doc_files[pname].build_status,
    pkgs_doc_files[pname].doc_build_status
  )

  if pkgs[pname].hasKey("github_latest_version"):
    pkgs_doc_files[pname].version = pkgs[pname]["github_latest_version"].str.strip
  else:
    log_debug "FIXME github_latest_version"
    pkgs_doc_files[pname].version = "?"

  try:
    let t2 = epochTime()
    await generate_jsondoc(pname)  # this can raise
    let elapsed = epochTime() - t2
    stats.gauge("jsondoc_build_time", elapsed)
  except:
    log.error("jsondoc failed for " & pname)

  let fn = package_parent_dir(pname) & "/nimpkgdir.json"
  save_pkg_metadata(pkgs_doc_files[pname], fn)
  try:
    let pm: PkgDocMetadata = load_metadata(fn)
  except:
    log.error("JSON: created broken file: " & fn)

proc translate_term_colors*(outp: string): string =
  ## Translate terminal colors
  const sequences = @[
    ("[36m[2m", "<span>"),
    ("[32m[1m", """<span class="success">"""),
    ("[33m[1m", """<span class="red">"""),
    ("[31m[1m", """<span class="red">"""),
    ("[36m[1m", """<span class="blue">"""),
    ("[0m[31m[0m", "</span>"),
    ("[0m[32m[0m", "</span>"),
    ("[0m[33m[0m", "</span>"),
    ("[0m[36m[0m", "</span>"),
    ("[0m[0m", "</span>"),
    ("[2m", "<span>"),
    ("[36m", "<span>"),
    ("[33m", """<span class="blue">"""),
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

  get "/about.html":
    include "templates/about.tmpl"
    resp base_page(request, generate_about_page())

  get "/":
    log_req request
    stats.incr("views")
    try:
      var top_pkgs: seq[Pkg] = @[]
      for pname in top_keys(most_queried_packages, 5):
        if pkgs.hasKey(pname):
          top_pkgs.add pkgs[pname]

      log_debug "pkgs history len: $#" % $cache.pkgs_history.len
      # List 5 newest packages
      var new_pkgs: seq[Pkg] = @[]
      for n in 1..min(cache.pkgs_history.len, 5):
          let pname = cache.pkgs_history[^n].name.normalize()
          if pkgs.hasKey(pname):
            new_pkgs.add pkgs[pname]
          else:
            log_debug "$# not found in package list" % pname

      let github_trending = github_trending_packages(request, pkgs)

      let home = generate_home_page(top_pkgs, new_pkgs,
                                    github_trending)
      resp base_page(request, home)
    except:
      log.error getCurrentExceptionMsg()
      halt Http400

  get "/search":
    log_req request
    stats.incr("views")
    let found_pkg_names = search_packages(@"query")

    var pkgs_list: seq[Pkg] = @[]
    for pn in found_pkg_names.keys():
      pkgs_list.add pkgs[pn]

    stats.gauge("search_found_pkgs", pkgs_list.len)
    let body = generate_search_box(@"query") &
               generate_pkg_list_page(pkgs_list)
    resp base_page(request, body)

  get "/build_history.html":
    include "templates/build_history.tmpl"
    log_req request
    resp base_page(request, generate_build_history_page(build_history))

  get "/pkg/@pkg_name/?":
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

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
    save_packages()
    log_info if pkg_already_exists: "Updated existing package $#" % name
      else: "Added new package $#" % name
    resp base_page(request, "OK")

  get "/packages.json":
    ## Serve the packages list file
    log_req request
    stats.incr("views")
    resp conf.packages_list_fname.readFile

  get "/docs/@pkg_name/?":
    ## Serve hosted docs for a package: summary page
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "<p>Package not found</p>")

    most_queried_packages.inc pname
    let pkg = pkgs[pname]

    # Check out pkg and build docs. Modifies pkgs_doc_files
    await fetch_and_build_pkg_if_needed(pname)

    # Show files summary
    resp base_page(request,
      generate_doc_files_list_page(pname, pkgs_doc_files[pname])
    )

  get "/docs/@pkg_name/idx_summary.json":
    ## Serve hosted docs for a package: IDX summary
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "<p>Package not found</p>")

    let pkg = pkgs[pname]

    # Check out pkg and build docs. Modifies pkgs_doc_files
    #await fetch_and_build_pkg_if_needed(pname)

    let pkg_root_dir =
      try:
        locate_pkg_root_dir(pname)
      except:
        halt Http400
        ""

    var idx_filenames: strSeq = @[]
    for kind, path in walkDir(pkg_root_dir, relative=true):
      if path.endswith(".idx"):
        idx_filenames.add path
        #let chunks = path.split('-', maxsplit=1)
        #if chunks[0].normalize() == pname:
        #  result = pkgs_dir / path

    # Show files summary
    let s = %* {"version": 1, "idx_filenames": idx_filenames}
    resp $s

  #get "/docs/@pkg_name_and_doc_path":
  get "/docs/@pkg_name/@a?/?@b?/?@c?/?@d?":
    ## Serve hosted docs and idx files for a package
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "<p>Package not found</p>")

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

    if not (doc_path.endswith(".html") or doc_path.endswith(".idx")):
      log_debug "Refusing to serve doc path $# $#" % [pname, doc_path]
      halt Http400

    log_debug "Attempting to serve doc path $# $#" % [pname, doc_path]

    # Example: /docs/nimgame2/nimgame2/audio.html
    # ..serves:
    # /dev/shm/nim_package_dir/nimgame2/pkgs/nimgame2-0.1.0/nimgame2/audio.html

    let fn = pkg_root_dir / doc_path
    if not existsFile(fn):
      log_info "serving $# - not found" % fn
      resp base_page(request, """
        <p>Sorry, that file does not exists.
        <a href="/pkg/$#">Go back to $#</a>
        </p>
        """ % [pname, pname])

    # Serve doc or idx file
    if doc_path.endswith(".idx"):
      resp readFile(fn)
    else:
      let head = """<h4>Doc files for <a href="/pkg/$#">$#</a></h4>""" % [pname, pname]
      let page = head & fn.readFile()
      resp base_page(request, page)

  get "/loader":
    log_req request
    stats.incr("views")
    resp base_page(request,
      generate_loader_page()
    )

  get "/packages.xml":
    ## New and updated packages feed
    log_req request
    stats.incr("views_rss")
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
    log_req request
    stats.incr("views")
    resp base_page(request, """
    <br/>
    <p>Runtime: $#</p>
    <p>Queried packages count: $#</p>
    """ % [$cpuTime(), $len(most_queried_packages)])

  # CI Routing

  get "/ci":
    ## CI summary
    log_req request
    stats.incr("views")
    #@bottle.view('index')
    #refresh_build_num()
    discard

  get "/ci/install_report":
    log_req request
    stats.incr("views")
    discard

  get "/ci/badges/@pkg_name/version.svg":
    ## Version badge. Set HTTP headers to control caching.
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    await fetch_and_build_pkg_if_needed(pname)
    try:
      let md = pkgs_doc_files[pname]
      let version =
        if md.version.endswith("\0"):
          md.version[0..^2]
        else:
          md.version
      if version == nil:
        log_debug "Version is nil"
      let badge =
        if version == nil:
          version_badge_tpl % ["none", "none"]
        else:
          version_badge_tpl % [version, version]
      resp(Http200, xml_no_cache_headers, badge)
    except:
      log_debug getCurrentExceptionMsg()
      let badge = version_badge_tpl % ["none", "none"]
      resp(Http200, xml_no_cache_headers, badge)

  get "/ci/badges/@pkg_name/nimdevel/status.svg":
    ## Status badge
    ## Set HTTP headers to control caching.
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname

    # This might start a build here and populate pkgs_doc_files[pname]
    # or fail before setting pkgs_doc_files or not run at all
    await fetch_and_build_pkg_if_needed(pname)
    # The Running badge should only appear if there are bugs
    # in fetch_and_build_pkg_if_needed

    if not pkgs_doc_files.hasKey(pname):
        log_info "missing pname, this is a bug"
        halt Http400

    let md = pkgs_doc_files[pname]

    let badge =
      case md.build_status
      of BuildStatus.OK:
        build_success_badge
      of BuildStatus.Failed:
        build_fail_badge
      of BuildStatus.Timeout:
        build_fail_badge
      of BuildStatus.Running:
        build_running_badge
    resp(Http200, xml_no_cache_headers, badge)

  get "/ci/badges/@pkg_name/nimdevel/docstatus.svg":
    ## Doc build status badge
    ## Set HTTP headers to control caching.
    log_req request
    stats.incr("views")
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname

    await fetch_and_build_pkg_if_needed(pname)

    if not pkgs_doc_files.hasKey(pname):
        log_info "missing pname, this is a bug"
        halt Http400

    let md = pkgs_doc_files[pname]

    # The Running badge should only appear if there the
    # nimble install failed
    let badge =
      case md.doc_build_status
      of BuildStatus.OK:
        doc_success_badge
      of BuildStatus.Failed:
        doc_fail_badge
      of BuildStatus.Timeout:
        doc_fail_badge
      of BuildStatus.Running:
        doc_running_badge
    resp(Http200, xml_no_cache_headers, badge)

  get "/ci/badges/@pkg_name/nimdevel/output.html":
    ## Build output
    log_req request
    stats.incr("views")
    log_info "$#" % $request.ip
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    await fetch_and_build_pkg_if_needed(pname)
    try:
      let outp = pkgs_doc_files[pname].build_output
      let build_output = translate_term_colors(outp)
      resp base_page(request, generate_build_output_page(
        pname,
        build_output,
        pkgs_doc_files[pname].build_time,
        pkgs_doc_files[pname].expire_time,
      ))
    except KeyError:
      halt Http400

  get "/ci/badges/@pkg_name/nimdevel/doc_build_output.html":
    ## Doc build output
    log_req request
    stats.incr("views")
    log_info "$#" % $request.ip
    let pname = normalize(@"pkg_name")
    if not pkgs.hasKey(pname):
      resp base_page(request, "Package not found")

    most_queried_packages.inc pname
    await fetch_and_build_pkg_if_needed(pname)
    try:
      var doc_build_html = ""
      for o in pkgs_doc_files[pname].doc_build_output:
        if o.success_flag:
          doc_build_html.add """<div class="doc_build_success">"""
        else:
          doc_build_html.add """<div class="doc_build_fail">"""
        doc_build_html.add "<p>$#</p>" % o.filename
        doc_build_html.add "<p>$#</p>" % o.desc
        let t = translate_term_colors(o.output)
        doc_build_html.add "<p>$#</p>" % t
        doc_build_html.add "</div>"

      resp base_page(request, generate_build_output_page(
        pname,
        doc_build_html,
        pkgs_doc_files[pname].build_time,
        pkgs_doc_files[pname].expire_time,
      ))
    except KeyError:
      halt Http400

  get "/ci/status/@pkg_name":
    ## Package build status in a simple JSON
    log_req request
    let pname = normalize(@"pkg_name")
    let status =
      if pkgs_doc_files.hasKey(pname):
        if pkgs_doc_files[pname].building:
          "building"
        else:
          "done"
      else:
        "unknown"
    let s = %* {"status": status}
    resp $s

  post "/ci/rebuild/@pkg_name":
    ## Force new build
    log_req request
    let pname = normalize(@"pkg_name")
    asyncCheck fetch_and_build_pkg_if_needed(pname, force_rebuild=true)
    resp "ok"

  get "/robots.txt":
    ## Serve robots.txt to throttle bots
    resp "User-agent: *\nCrawl-delay: 300\n"

  get "/searchitem":
    ## Search for jsondoc item
    log_req request
    stats.incr("views")
    let query = @"query"
    let jdi =
      if jsondoc_items.hasKey(query):
        jsondoc_items[query]
      else:
        @[]
    let body = generate_jsondoc_items_page(jdi)
    resp base_page(request, body)


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


proc run_github_packages_json_polling(poll_time_s: int) {.async.} =
  ## Poll GH for packages.json
  ## Overwrite packages.json local file!
  log_debug "starting GH packages.json polling"
  var first_run = true
  while true:
    if first_run:
      first_run = false
    else:
      await sleepAsync poll_time_s * 1000
    log_debug "Polling GitHub packages.json"
    try:
      let new_pkg_raw = fetch_github_packages_json()
      if new_pkg_raw == conf.packages_list_fname.readFile:
        log_debug "No changes"
        stats.gauge("packages_all_known", pkgs.len)
        stats.gauge("packages_history", cache.pkgs_history.len)
        continue

      for pdata in new_pkg_raw.parseJson:
        if pdata.hasKey("name"):
          let pname = pdata["name"].str.normalize()
          if not pkgs.hasKey(pname):
            cache.pkgs_history.add PkgHistoryItem(name:pname, first_seen_time:getTime())
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
  #save_packages()
  zmqsock.close()
  quit()

proc main() =
  #setup_seccomp()
  log_info "starting"
  conf.tmp_nimble_root_dir.createDir()
  load_packages()
  cache = load_cache()
  scan_pkgs_dir(conf.tmp_nimble_root_dir)
  #asyncCheck start_nim_commit_polling(github_nim_commit_polling_time)
  asyncCheck run_systemd_sdnotify_pinger(sdnotify_ping_time_s)
  asyncCheck run_github_packages_json_polling(github_packages_json_polling_time_s)

  log_info "starting loop"
  runForever()

when isMainModule:
  main()
