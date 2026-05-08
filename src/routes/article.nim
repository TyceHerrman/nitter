# SPDX-License-Identifier: AGPL-3.0-only
import asyncdispatch, tables, sets, sequtils, strutils, sugar

import jester

import router_utils
import ".."/[types, api]
import ../views/general
import ../views/article as articleView

export articleView

proc renderArticleMain*(article: Article; request: Request; cfg: Config;
                        prefs: Prefs): Future[string] {.async.} =
  # Fan out concurrent single-tweet lookups for embedded tweets. Dedupe by
  # tweet id so the same embed doesn't fetch twice within one article.
  var tweetIds = initHashSet[string]()
  for entity in article.entities.values:
    if entity.entityType == ArticleEntityType.tweet and
       entity.tweetId.len > 0:
      tweetIds.incl entity.tweetId

  var tweets = initTable[string, Tweet]()
  if tweetIds.len > 0:
    let ids = toSeq(tweetIds)
    var futures: seq[Future[Tweet]]
    for id in ids:
      futures.add getGraphTweetResult(id)
    let results = await all(futures)
    for i, tweet in results:
      if tweet != nil and tweet.id != 0:
        tweets[ids[i]] = tweet

  let body = renderArticle(article, tweets, prefs, request.path)
  result = renderMain(body, request, cfg, prefs,
                      titleText=article.title, ogTitle=article.title)

proc createArticleRouter*(cfg: Config) =
  router articleRoute:
    get "/@name/article/@id/?":
      cond '.' notin @"name"
      cond @"name" != "i"

      let id = @"id"
      if id.len > 19 or id.any(c => not c.isDigit):
        resp Http404, showError("Invalid article ID", cfg)

      var article: Article
      try:
        article = await getGraphArticle(id)
      except:
        discard

      if article == nil or article.id.len == 0:
        resp Http404, showError("Article not found", cfg)

      let html = await renderArticleMain(article, request, cfg, requestPrefs())
      resp html
