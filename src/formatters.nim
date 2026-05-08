# SPDX-License-Identifier: AGPL-3.0-only
import strutils, strformat, times, uri, tables, xmltree, htmlparser, htmlgen, math
import std/[enumerate, re]
import types, utils, query

const
  cards = "cards.twitter.com/cards"
  tco = "https://t.co"
  twitter = parseUri("https://x.com")

let
  twRegex = re"(?<=(?<!\S)https:\/\/|(?<=\s))(www\.|mobile\.)?twitter\.com"
  twLinkRegex = re"""<a href="https:\/\/twitter.com([^"]+)">twitter\.com(\S+)</a>"""
  xRegex = re"(?<=(?<!\S)https:\/\/|(?<=\s))(www\.|mobile\.)?x\.com"
  xLinkRegex = re"""<a href="https:\/\/x.com([^"]+)">x\.com(\S+)</a>"""

  twitterInternalUrlRegex = re"""https?://(?:www\.|mobile\.|m\.)?(?:twitter|x)\.com/[A-Za-z0-9_]{1,15}/(?:article|status)/[0-9]+(?:[?#][^"'<>\s]*)?"""

  hashtagRegex = re"\B#(\w*[A-Za-z]\w*)\b"
  mentionRegex = re"\B@(\w{1,15})\b"

  ytRegex = re(r"([A-z.]+\.)?youtu(be\.com|\.be)", {reStudy, reIgnoreCase})

  rdRegex = re"(?<![.b])((www|np|new|amp|old)\.)?reddit.com"
  rdShortRegex = re"(?<![.b])redd\.it\/"
  # Videos cannot be supported uniformly between Teddit and Libreddit,
  # so v.redd.it links will not be replaced.
  # Images aren't supported due to errors from Teddit when the image
  # wasn't first displayed via a post on the Teddit instance.

  wwwRegex = re"https?://(www[0-9]?\.)?"
  m3u8Regex = re"""url="(.+.m3u8)""""
  userPicRegex = re"_(normal|bigger|mini|200x200|400x400)(\.[A-z]+)$"
  extRegex = re"(\.[A-z]+)$"
  illegalXmlRegex = re"(*UTF8)[^\x09\x0A\x0D\x20-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]"

proc getUrlPrefix*(cfg: Config): string =
  if cfg.useHttps: https & cfg.hostname
  else: "http://" & cfg.hostname

proc shorten*(text: string; length=28): string =
  result = text
  if result.len > length:
    result = result[0 ..< length] & "…"

proc shortLink*(text: string; length=28): string =
  result = text.replace(wwwRegex, "").shorten(length)
    
proc stripHtml*(text: string; shorten=false): string =
  var html = parseHtml(text)
  for el in html.findAll("a"):
    let link = el.attr("href")
    if "http" in link:
      if el.len == 0: continue
      el[0].text =
        if shorten: link.shortLink
        else: link
  html.innerText()

proc sanitizeXml*(text: string): string =
  text.replace(illegalXmlRegex, "")

proc isTwitterHost(host: string): bool =
  let host = host.toLowerAscii
  host in [
    "x.com", "www.x.com", "mobile.x.com", "m.x.com",
    "twitter.com", "www.twitter.com", "mobile.twitter.com", "m.twitter.com"
  ]

proc localizeTwitterArticleUrl*(url: string): string =
  result = url
  let lowerUrl = url.toLowerAscii
  if "x.com" notin lowerUrl and "twitter.com" notin lowerUrl:
    return

  let parsed = parseUri(url)
  if parsed.scheme notin ["http", "https"] or
     not parsed.hostname.isTwitterHost:
    return

  let parts = parsed.path.strip(chars={'/'}).split('/')
  if parts.len != 3:
    return

  let
    username = parts[0]
    kind = parts[1]
    id = parts[2]

  if username.len == 0 or username.toLowerAscii == "i" or
     kind notin ["article", "status"] or id.len == 0:
    return

  for c in id:
    if not c.isDigit:
      return

  result = &"/{username}/{kind}/{id}"
  if parsed.query.len > 0:
    result &= "?" & parsed.query
  if parsed.anchor.len > 0:
    result &= "#" & parsed.anchor

proc localizeTwitterArticleLinks*(body: string): string =
  result = body
  for url in body.findAll(twitterInternalUrlRegex):
    let local = localizeTwitterArticleUrl(url)
    if local != url:
      result = result.replace(url, local)

proc replaceHashtagsAndMentions*(body: string): string =
  result = body
  result = result.replacef(hashtagRegex, """<a href="/search?q=%23$1">#$1</a>""")
  result = result.replacef(mentionRegex, """<a href="/$1">@$1</a>""")

proc replaceUrls*(body: string; prefs: Prefs; absolute=""): string =
  result = body.localizeTwitterArticleLinks

  if prefs.replaceYouTube.len > 0 and "youtu" in result:
    let youtubeHost = strip(prefs.replaceYouTube, chars={'/'})
    result = result.replace(ytRegex, youtubeHost)

  if prefs.replaceTwitter.len > 0:
    let twitterHost = strip(prefs.replaceTwitter, chars={'/'})
    if tco in result:
      result = result.replace(tco, https & twitterHost & "/t.co")
    if "x.com" in result:
      result = result.replace(xRegex, twitterHost)
      result = result.replacef(xLinkRegex, a(
        twitterHost & "$2", href = https & twitterHost & "$1"))
    if "twitter.com" in result:
      result = result.replace(cards, twitterHost & "/cards")
      result = result.replace(twRegex, twitterHost)
      result = result.replacef(twLinkRegex, a(
        twitterHost & "$2", href = https & twitterHost & "$1"))

  if prefs.replaceReddit.len > 0 and ("reddit.com" in result or "redd.it" in result):
    let redditHost = strip(prefs.replaceReddit, chars={'/'})
    result = result.replace(rdShortRegex, redditHost & "/comments/")
    result = result.replace(rdRegex, redditHost)
    if redditHost in result and "/gallery/" in result:
      result = result.replace("/gallery/", "/comments/")

  if absolute.len > 0 and "href" in result:
    result = result.replace("href=\"/", &"href=\"{absolute}/")

proc getM3u8Url*(content: string): string =
  var matches: array[1, string]
  if re.find(content, m3u8Regex, matches) != -1:
    result = matches[0]

proc proxifyVideo*(manifest: string; proxy: bool; manifestUrl = ""): string =
  let (baseUrl, basePath) =
    if manifestUrl.len > 0:
      let
        u = parseUri(manifestUrl)
        origin = u.scheme & "://" & u.hostname
        idx = manifestUrl.rfind('/')
        dirPath = if idx > 8: manifestUrl[0 .. idx] else: ""
      (origin, dirPath)
    else:
      ("https://video.twimg.com", "")
  var replacements: seq[(string, string)]
  for line in manifest.splitLines:
    let url =
      if line.startsWith("#EXT-X-MAP:URI"): line[16 .. ^2]
      elif line.startsWith("#EXT-X-MEDIA") and "URI=" in line:
        line[line.find("URI=") + 5 .. -1 + line.find("\"", start= 5 + line.find("URI="))]
      else: line
    let resolved =
      if url.startsWith('/'): baseUrl & url
      elif basePath.len > 0 and url.len > 0 and not url.startsWith('#') and
           not url.startsWith("http") and ('.' in url): basePath & url
      else: ""
    if resolved.len > 0:
      replacements.add (url, if proxy: resolved.getVidUrl else: resolved)
  return manifest.multiReplace(replacements)

proc getUserPic*(userPic: string; style=""): string =
  userPic.replacef(userPicRegex, "$2").replacef(extRegex, style & "$1")

proc getUserPic*(user: User; style=""): string =
  getUserPic(user.userPic, style)

proc getVideoEmbed*(cfg: Config; id: int64): string =
  &"{getUrlPrefix(cfg)}/i/videos/{id}"

proc pageTitle*(user: User): string =
  &"{user.fullname} (@{user.username})"

proc pageTitle*(tweet: Tweet): string =
  &"{pageTitle(tweet.user)}: \"{stripHtml(tweet.text)}\""

proc pageDesc*(user: User): string =
  if user.bio.len > 0:
    stripHtml(user.bio)
  else:
    "The latest tweets from " & user.fullname

proc getJoinDate*(user: User): string =
  user.joinDate.format("'Joined' MMMM YYYY")

proc getJoinDateFull*(user: User): string =
  user.joinDate.format("h:mm tt - d MMM YYYY")

proc getTime*(tweet: Tweet): string =
  tweet.time.format("MMM d', 'YYYY' · 'h:mm tt' UTC'")

proc getRfc822Time*(tweet: Tweet): string =
  tweet.time.format("ddd', 'dd MMM yyyy HH:mm:ss 'GMT'")

proc getShortTime*(tweet: Tweet): string =
  let now = now()
  let since = now - tweet.time

  if now.year != tweet.time.year:
    result = tweet.time.format("d MMM yyyy")
  elif since.inDays >= 1:
    result = tweet.time.format("MMM d")
  elif since.inHours >= 1:
    result = $since.inHours & "h"
  elif since.inMinutes >= 1:
    result = $since.inMinutes & "m"
  elif since.inSeconds > 1:
    result = $since.inSeconds & "s"
  else:
    result = "now"

proc getDuration*(ms: int): string =
  let
    sec = int(round(ms / 1000))
    min = floorDiv(sec, 60)
    hour = floorDiv(min, 60)
  if hour > 0:
    &"{hour}:{min mod 60:02}:{sec mod 60:02}"
  else:
    &"{min mod 60}:{sec mod 60:02}"

proc getDuration*(video: Video): string =
  getDuration(video.durationMs)

proc getLink*(id: int64; username="i"; focus=true): string =
  var username = username
  if username.len == 0:
    username = "i"
  result = &"/{username}/status/{id}"
  if focus: result &= "#m"

proc getLink*(tweet: Tweet; focus=true): string =
  if tweet.id == 0: return
  var username = tweet.user.username
  return getLink(tweet.id, username, focus)

proc getTwitterLink*(path: string; params: Table[string, string]): string =
  var
    username = params.getOrDefault("name")
    query = initQuery(params, username)
    path = path

  if "," in username:
    query.fromUser = username.split(",")
    path = "/search"

  if "/search" notin path and query.fromUser.len < 2:
    return $(twitter / path)

  let p = {
    "f": if query.kind == users: "user" else: "live",
    "q": genQueryParam(query),
    "src": "typed_query"
  }

  result = $(twitter / path ? p)
  if username.len > 0:
    result = result.replace("/" & username, "")

proc getLocation*(u: User | Tweet): (string, string) =
  if "://" in u.location: return (u.location, "")
  let loc = u.location.split(":")
  let url = if loc.len > 1: "/search?f=tweets&q=place:" & loc[1] else: ""
  (loc[0], url)

proc getSuspended*(username: string): string =
  &"User \"{username}\" has been suspended"

proc titleize*(str: string): string =
  const
    lowercase = {'a'..'z'}
    delims = {' ', '('}

  result = str
  for i, c in enumerate(str):
    if c in lowercase and (i == 0 or str[i - 1] in delims):
      result[i] = c.toUpperAscii
