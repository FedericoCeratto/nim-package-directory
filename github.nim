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
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_caching_time = 600

  github_token = "FIXME"

  nim_commit_url = "https://api.github.com/repos/nim-lang/Nim/git/refs/heads/devel"
  nimble_commit_url = "https://api.github.com/repos/nim-lang/Nimble/git/refs/heads/master"
  pkgs_commit_url = "https://api.github.com/repos/nim-lang/packages/git/refs/heads/master"


let conf* = load_conf()
let stats* = newStatdClient(prefix = "nim_package_directory")
let github_token_headers = newHttpHeaders({
  "Authorization": "token $#" % conf.github_token})

# volatile caches
var volatile_cache_github_trending_last_update_time = 0
var volatile_cache_github_trending: seq[JsonNode] = @[]

let gh_readme_client = newHttpClient()
gh_readme_client.headers["Accept"] = "application/vnd.github.v3.html" #FIXME Add token


proc update_readme_and_version_from_gh*(pkg: JsonNode, conf: JsonNode) =
  ## Update pkg version and readme from GitHub
  let url = pkg["url"].str
  pkg["github_last_update_time"] = newJInt epochTime().int
  let owner = url.split('/')[3]
  let owner_repo_name = "$#/$#" % url.split('/')[3..4]
  pkg["github_owner"] = newJString owner

  echo "fetching ", github_readme_tpl % owner_repo_name
  try:
    let readme = gh_readme_client.getContent(github_readme_tpl % owner_repo_name)
    pkg["github_readme"] = newJString readme
  except:
    echo getCurrentExceptionMsg()
    pkg["github_readme"] = newJString ""

  echo "fetching ", github_latest_version_tpl % owner_repo_name
  try:
    let cl = newHttpClient()
    cl.headers["Authorization"] = "token $#" % conf["github_token"].str
    let latest_version = cl.getContent(github_latest_version_tpl % owner_repo_name).parseJson
    pkg["github_latest_version"] = newJString latest_version["name"].str
    pkg["github_latest_version_url"] = newJString latest_version["tarball_url"].str
    pkg["github_latest_version_time"] = newJString latest_version["published_at"].str
  except:
    pkg["github_latest_version"] = newJString "none"
    pkg["github_latest_version_url"] = newJString ""
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

#
#def fetch_last_commit(url):
#    """Fetch from GitHub API
#    """
#    r = requests.get(url, auth=('FedericoCeratto', GH_TOKEN))
#    try:
#        return r.json()['object']['sha']
#    except:
#        print("Unable to parse output from %s" % url)
#        print(repr(r))
#
