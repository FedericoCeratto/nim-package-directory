#
# Nim package directory
# GitHub interface
#

import httpclient,
  json,
  strutils,
  times

const
  github_readme_tpl = "https://api.github.com/repos/$#/readme"
  github_latest_version_tpl = "https://api.github.com/repos/$#/releases/latest"
  github_caching_time = 600

  github_token = "FIXME"

  nim_commit_url = "https://api.github.com/repos/nim-lang/Nim/git/refs/heads/devel"
  nimble_commit_url = "https://api.github.com/repos/nim-lang/Nimble/git/refs/heads/master"
  pkgs_commit_url = "https://api.github.com/repos/nim-lang/packages/git/refs/heads/master"



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
