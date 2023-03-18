#
# Nim package directory
# GitHub interface
#

import std/[algorithm, asyncdispatch, httpclient, json, strutils, tables, times]
import jester, statsd_client
import util, persist

type
  Pkg* = JsonNode
  Pkgs* = TableRef[string, Pkg]

const
  github_caching_time* = 600

let conf* = load_conf()
let stats* = newStatdClient(prefix = "nim_package_directory")
let github_token_headers = newHttpHeaders({
  "Authorization": "token $#" % conf.github_token})

# volatile caches
var volatile_cache_github_trending_last_update_time = 0
var volatile_cache_github_trending: seq[JsonNode] = @[]

proc fetch_from_github(url: string): Future[string] {.async.} =
  ## Fetch content from GitHub asychronously
  log_debug "fetching ", url
  try:
    let ac = newAsyncHttpClient()
    ac.headers = github_token_headers
    return await ac.getContent(url)
  except:
    log_debug "failed to fetch content ", url
    log_debug getCurrentExceptionMsg()
    return ""

proc fetch_json*(url: string): Future[JsonNode] {.async.} =
  ## Fetch JSON from GitHub asynchronously
  let response = await fetch_from_github(url)
  return response.parseJson()

proc fetch_nimble_packages*(): Future[string] {.async.} =
  ## Fetch the packages.json file from GitHub
  let url = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  return await fetch_from_github(url)

# TODO: return strings, not newJStrings

proc fetch_github_readme*(owner, repo_name: string): Future[JsonNode] {.async.} =
  ## Fetch README.* from GitHub
  let url = "https://api.github.com/repos/$#/$#/readme" % [owner, repo_name]
  log_debug "fetching ", url
  try:
    let ac = newAsyncHttpClient()
    ac.headers = github_token_headers
    ac.headers["Accept"] = "application/vnd.github.v3.html" # necessary
    let readme = await ac.getContent(url)
    return newJString readme
  except:
    log_debug "failed to fetch content ", url
    log_debug getCurrentExceptionMsg()
    return newJString ""

proc fetch_github_doc_pages*(owner, repo_name: string): Future[JsonNode] {.async.} =
  ## Fetch documentation pages from GitHub
  let url = "https://$#.github.io/$#/index.html" % [owner.toLowerAscii, repo_name]
  log_debug "checking ", url
  let resp = await newAsyncHttpClient().get(url)
  if resp.status.startswith("200"):
    return newJString url
  else:
    log_debug "doc not found at ", url
    return newJString ""

proc fetch_github_versions*(pkg: Pkg, owner, repo_name: string) {.async.} =
  ## Fetch versions from GH from releases and tags
  ## Set github_versions, github_latest_version, github_latest_version_url
  let github_tags_url = "https://api.github.com/repos/$#/$#/tags" % [owner, repo_name]
  log_debug "fetching GitHub tags ", github_tags_url
  var version_names = newJArray()
  try:
    let ac = newAsyncHttpClient()
    ac.headers = github_token_headers
    let rtags = await ac.getContent(github_tags_url)
    let tags = parseJson(rtags)
    for t in tags:
      let name = t["name"].str.strip(trailing = false, chars = {'v'})
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

  let github_api_releases_url = "https://api.github.com/repos/$#/$#/releases" % [owner, repo_name]
  log_debug "fetching GH releases ", github_api_releases_url
  var releases: JsonNode
  try:
    releases = await fetch_json(github_api_releases_url)
  except:
    log_debug getCurrentExceptionMsg()
    releases = newJArray()

  if releases.len > 0:
    let (latest_version, meta) = extract_latest_version(releases)
    doAssert meta != nil
    pkg["github_latest_version"] = newJString latest_version
    pkg["github_latest_versions_str"] = extract_latest_versions_str(releases)
    pkg["github_latest_version_url"] = newJString meta["tarball_url"].str
    pkg["github_latest_version_time"] = newJString meta["published_at"].str

  else:
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
        "https://github.com/$#/$#/archive/v$#.tar.gz" % [owner, repo_name, latest]
      )

    pkg["github_latest_version_time"] = newJString ""

proc fetch_trending_packages*(request: Request, pkgs: Pkgs): Future[seq[Pkg]] {.async.} =
  ## Fetches trending repositories written in Nim from GitHub, and filters packages.json down to those
  if volatile_cache_github_trending_last_update_time +
      github_caching_time > epochTime().int:
    return volatile_cache_github_trending

  let date = utc(getTime() - 14.days).format("yyyy-MM-dd")
  let url = "https://api.github.com/search/repositories?q=language:nim+pushed:>$#&per_page=$#sort=$#&page=$#" % [date, "20", "updated", "1"]
  log_info "searching GH repos: '$#'" % url
  let query_res = await fetch_json(url)

  let github_trending_pkgs: seq[JsonNode] =
    query_res["items"].elems
    .sortedByIt(it["updated_at"].str).reversed()

  # Filter the package list to trending packages + add GitHub info
  var trending_pkgs: seq[Pkg] = @[]
  for p in github_trending_pkgs:
    # Many packages prefix their GitHub name with `nim-`: remove these
    # (there may be false positives, but considerably fewer than otherwise)
    let package_name: string =
      if p["name"].str.len > 4 and p["name"].str[0..3] == "nim-":
        p["name"].str[4..^1].normalize()
      else:
        p["name"].str.normalize()

    # FIXME: checking names is not completely reliable, check urls instead
    if pkgs.hasKey(package_name):
      var current_pkg = pkgs[package_name]
      # Add GitHub stargazer count
      current_pkg.add("stargazers_count", p["stargazers_count"])
      # Add last updated time (pushed_at is more accurate than updated_at)
      current_pkg.add("pushed_at", p["pushed_at"])
      # Add GitHub author
      current_pkg.add("owner", p["owner"])

      trending_pkgs.add(current_pkg)
    else:
      log_debug "package " & package_name & " not found"

  trending_pkgs = trending_pkgs.sortedByIt(it["pushed_at"].str).reversed()

  volatile_cache_github_trending = trending_pkgs
  volatile_cache_github_trending_last_update_time = epochTime().int

  return trending_pkgs
