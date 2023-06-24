import std/[algorithm, json, strutils, sequtils, xmltree, uri]
import jester, morelogging

when defined(systemd):
  let log* = newJournaldLogger()
else:
  let log* = newStdoutLogger()

proc log_debug*(args: varargs[string, `$`]) =
  log.debug(args.join(" "))

proc log_info*(args: varargs[string, `$`]) =
  log.info(args.join(" "))

proc log_req*(request: Request) =
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

proc is_newer*(b, a: string): int =
  ## Based on Nimble implementation, compares versions a.b.c by simply
  ## comparing the integers :-/
  for (ai, bi) in zip(a.split('.'), b.split('.')):
    let aa = parseInt(ai)
    let bb = parseInt(bi)
    if bb > aa:
      return 1
    elif aa > bb:
      return -1

  return -1

proc extract_latest_version*(releases: JsonNode): (string, JsonNode) =
  ## Extracts the release metadata chunk from `releases` matching the latest release
  var latest_version = "-1.-1.-1"
  for r in releases:
    let version = r["tag_name"].str.strip().strip(trailing = false, chars = {'v'})
    if is_newer(version, latest_version) > 0:
      latest_version = version
      result = (version, r)
  log_debug "Picking latest version from GH tags: ", latest_version

proc extract_latest_versions_str*(releases: JsonNode): JsonNode =
  ## Extracts latest releases as JSON array
  result = newJArray()
  var vers: seq[string] = @[]
  for r in releases:
    let version = r["tag_name"].str.strip().strip(trailing = false, chars = {'v'})
    vers.add version
  let x = min(vers.len, 3)
  for v in vers.sorted(is_newer)[^x..^1]:
    result.add newJString(v)

proc uniescape*(inp: string): string =
  for c in inp:
    let o = c.ord
    if o < 32 or o > 126:
      let q = "\\u00" & o.toHex()[^2..^1]
      result.add q
    else:
      result.add c

# proc `+`(t1, t2: Time): Time {.borrow.}

proc strip_html*(html: string): string =
  # Assumes that any < > that is not part of HTML tags has been escaped
  # Everything that matches <.*> is removed, including invalid tags
  result = newStringOfCap(html.len)
  var inside_tag = false
  for c in html:
    if inside_tag == false:
      if c == '<':
        inside_tag = true
      else:
        result.add c
    elif c == '>':
      inside_tag = false

proc cleanup_whitespace*(s: string): string =
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

iterator findNode(html: var XmlNode, tag, attr: string): tuple[el: XmlNode, val: string] {.raises: [].} =
  for el in html.findAll(tag, caseInsensitive = true):
    if el.attrs.hasKey attr:
      let res = el.attrs.getOrDefault(attr, "") # to silent the compiler, ~attr~ exist.
      yield (el, res)

func rewrite_anchors*(html: var XmlNode, with_prefix: string) =
  ## to maintain the anchor to local headings
  for el, href in findNode(html, "a", "href"):
    if href[0] == '#' and el.attrs.getOrDefault("id", "") == with_prefix & href[1 .. ^1]:
      el.attrs["id"] = href[1 .. ^1]

func rewrite_relative_url*(html: var XmlNode, base_url_link, base_url_img: string = "") =
  ## Rewrite all the URLs in a gived readme's HTML by adding a base
  ## URL if it is missing, so it only affects the relative ones.
  ## Specifically search in ~a~ and ~img~ elements using specific
  ## base URLs. Also this maintains the anchor to local headings.
  let
    base_uri_a = parseUri base_url_link
    base_uri_img = parseUri base_url_img

  template rewriteTag(html: var XmlNode, tag, attr: string, base: Uri) =
    for el, res in findNode(html, tag, attr):
      if res[0] != '#':
        el.attrs[attr] = $combine(base, parseUri res) # ~combine~, as used
                                                      # here, ensures that the
                                                      # rewriting only occurs
                                                      # for relative URLs.
  html.rewriteTag("a", "href", base_uri_a)
  html.rewriteTag("img", "src", base_uri_img)
