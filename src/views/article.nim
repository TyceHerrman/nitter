# SPDX-License-Identifier: AGPL-3.0-only
import tables, bitops, times
import strutils except escape
import strformat
import std/unicode except strip
import karax/[karaxdsl, vdom]
from xmltree import escape

import renderutils, tweet
import ".."/[types, utils, formatters]

proc linkifyEscaped(raw: string): string {.inline.} =
  ## Article text passes through this on its way to `verbatim`. HTML-escape
  ## first so literal `<`, `>`, `&` in article bodies render as text (and so
  ## upstream content can't inject markup or script tags). Only after the
  ## escape do we run hashtag/mention linking, which emits `<a>` tags that
  ## are intentional and already safe.
  escape(raw).replaceHashtagsAndMentions

proc renderAuthor(user: User): VNode =
  buildHtml(tdiv(class="article-author")):
    a(href=("/" & user.username), class="article-author-link"):
      genImg(getUserPic(user, "_bigger"))
      tdiv(class="article-author-names"):
        tdiv(class="article-author-fullname"):
          strong: text user.fullname
          verifiedIcon(user)
        span(class="article-author-username"):
          text "@" & user.username

proc renderArticleMedia(entity: ArticleEntity; article: Article): VNode =
  result = span.newVNode()
  result.setAttr("class", "article-media")
  for id in entity.mediaIds:
    let media = article.media.getOrDefault(id)
    if media.url.len == 0:
      continue
    case media.mediaType
    of ArticleMediaType.image:
      let node = buildHtml(img(src=getSmallPic(media.url), alt=""))
      result.add node
    of ArticleMediaType.gif:
      let node = buildHtml(video(src=getVidUrl(media.url), controls="", autoplay="", loop=""))
      result.add node
    of ArticleMediaType.unknown:
      discard

proc renderArticleParagraph(articleParagraph: ArticleParagraph;
                            article: Article;
                            tweets: Table[string, Tweet];
                            prefs: Prefs; path: string): VNode =
  # Atomic blocks wrap a single entity — media or embedded tweet. LINK and
  # TWEMOJI are never atomic; they occur inline in text blocks.
  if articleParagraph.baseType == ArticleType.atomic:
    if articleParagraph.entityRanges.len == 0:
      return tdiv.newVNode()
    let er = articleParagraph.entityRanges[0]
    if not article.entities.hasKey(er.key):
      return tdiv.newVNode()
    let entity = article.entities[er.key]
    case entity.entityType
    of ArticleEntityType.media:
      return renderArticleMedia(entity, article)
    of ArticleEntityType.tweet:
      let tweet = tweets.getOrDefault(entity.tweetId, nil)
      if tweet == nil or not tweet.available:
        result = buildHtml(tdiv(class="article-tweet-missing")):
          text "Embedded tweet unavailable"
        return
      return renderTweet(tweet, prefs, path, mainTweet=true)
    else:
      return tdiv.newVNode()

  # Text block — header, list item, or plain paragraph. Walk the text at
  # offset granularity so inline styles and entities are honored without
  # collapsing to paragraph-wide styling.
  case articleParagraph.baseType
  of ArticleType.headerOne:       result = h1.newVNode()
  of ArticleType.headerTwo:       result = h2.newVNode()
  of ArticleType.headerThree:     result = h3.newVNode()
  of ArticleType.orderedListItem: result = li.newVNode()
  of ArticleType.unorderedListItem: result = li.newVNode()
  of ArticleType.atomic:          result = tdiv.newVNode()  # unreachable
  else:                           result = p.newVNode()

  let text = articleParagraph.text
  let textLen = text.runeLen

  proc styleAt(i: int): int =
    for sr in articleParagraph.inlineStyleRanges:
      if sr.offset <= i and sr.offset + sr.length > i:
        case sr.style
        of ArticleStyle.bold:          result.setBit(0)
        of ArticleStyle.italic:        result.setBit(1)
        of ArticleStyle.strikethrough: result.setBit(2)
        of ArticleStyle.unknown:       discard

  proc flushStyled(target: VNode; startRune, runeCount, style: int) =
    if runeCount <= 0: return
    let content = linkifyEscaped(text.runeSubStr(startRune, runeCount))
    if style == 0:
      target.add verbatim(content)
    else:
      var styleStr = ""
      if style.testBit(0): styleStr.add "font-weight:bold;"
      if style.testBit(1): styleStr.add "font-style:italic;"
      if style.testBit(2): styleStr.add "text-decoration:line-through;"
      let container = span.newVNode()
      container.setAttr("style", styleStr)
      container.add verbatim(content)
      target.add container

  proc flushPlainText(target: VNode; startRune, runeCount: int) =
    if runeCount <= 0: return
    if articleParagraph.inlineStyleRanges.len == 0:
      target.add verbatim(linkifyEscaped(text.runeSubStr(startRune, runeCount)))
      return
    let stopRune = startRune + runeCount
    var lastStyle = styleAt(startRune)
    var lastStart = startRune
    var i = startRune + 1
    while i < stopRune:
      let curStyle = styleAt(i)
      if curStyle != lastStyle:
        flushStyled(target, lastStart, i - lastStart, lastStyle)
        lastStart = i
        lastStyle = curStyle
      i.inc
    if lastStart < stopRune:
      flushStyled(target, lastStart, stopRune - lastStart, lastStyle)

  # Emit entity ranges in order, flushing plain text in the gaps.
  var last = 0
  for er in articleParagraph.entityRanges:
    if er.offset > last:
      flushPlainText(result, last, er.offset - last)

    if article.entities.hasKey(er.key):
      let entity = article.entities[er.key]
      case entity.entityType
      of ArticleEntityType.link:
        let label = text.runeSubStr(er.offset, er.length)
        let link = buildHtml(a(href=entity.url.localizeTwitterArticleUrl)):
          text label
        result.add link
      of ArticleEntityType.twemoji:
        let emoji = buildHtml(img(class="twemoji", src=getSmallPic(entity.twemoji), alt=""))
        result.add emoji
      else:
        # media/tweet inside a text block would be unexpected — fall back to
        # rendering the raw text slice so nothing silently disappears
        flushPlainText(result, er.offset, er.length)
    last = er.offset + er.length

  if last < textLen:
    flushPlainText(result, last, textLen - last)

proc renderArticle*(article: Article; tweets: Table[string, Tweet];
                    prefs: Prefs; path: string): VNode =
  let cover =
    if article.coverImage.len > 0: getSmallPic(article.coverImage)
    else: ""

  # Group consecutive list items of the same type into a single ol/ul.
  let main = buildHtml(article):
    h1(class="article-title"): text article.title
    renderAuthor(article.user)
    if article.time.year > 1:
      span(class="article-time"):
        text article.time.format("MMM d', 'yyyy")

  var listType = ArticleType.unknown
  var list: VNode = nil

  proc flushList() =
    if list != nil:
      main.add list
      list = nil
      listType = ArticleType.unknown

  for paragraph in article.paragraphs:
    let node = renderArticleParagraph(paragraph, article, tweets, prefs, path)
    let currentType = paragraph.baseType
    if currentType in {ArticleType.orderedListItem, ArticleType.unorderedListItem}:
      if currentType != listType:
        flushList()
        list =
          if currentType == ArticleType.orderedListItem: ol.newVNode()
          else: ul.newVNode()
        listType = currentType
      list.add node
    else:
      flushList()
      main.add node

  flushList()

  buildHtml(tdiv(class="article-page")):
    tdiv(class="article-panel"):
      if cover.len > 0:
        img(class="article-cover", src=cover, alt="")
      main
