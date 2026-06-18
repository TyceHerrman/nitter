# PR Draft: Support Public X Article Routes

Target: `zedeus:nitter` `master`
Head: `TyceHerrman:nitter` `feat/support-articles`

## Title

Support public X Article routes

## Body

### Summary

This adds support for public X Articles while keeping Notes and private Article routes unsupported.

Supported public Article URL shapes:

- `/<user>/article/<id>`
- `/<user>/status/<id>`

The `/status/<id>` route now detects Article-shaped tweets from the normal tweet response before falling back to an Article body fetch. Normal tweet conversations continue to render normally and do not perform Article body lookups.

### What changed

- Added an Article route for `/<user>/article/<id>`.
- Updated `/status/<id>` rendering so status-shaped Articles render as Article pages, while normal tweets still render as conversations.
- Switched Article body fetching to the current X web flow using `TweetResultByRestId` with Article rich-content field toggles.
- Added Article parsing, rendering, styling, and embedded-tweet fanout support.
- Localized public X/Twitter Article links inside rendered content for both supported public shapes.
- Kept `/i/article/:id` and `/i/notes/:id` on the unsupported-feature path.
- Added fail-loud Selenium coverage for public Article fixtures, normal tweet regression behavior, link localization, and unsupported private paths.

### Operational note

This does not add Article caching. Status pages use tweet-gated Article detection, so normal tweet pages do not perform Article body lookups. Status-shaped Article pages and direct Article pages may still repeat Article body fetches; caching successful Article bodies can be a follow-up if repeat Article traffic proves it necessary.

### Test plan

- `nimble build -Y`
- `poetry run pytest -q test_article.py::test_public_article_url_localizer_accepts_supported_shapes`
- `poetry run pytest -q --browser=chrome --headless test_article.py`

I also smoke-tested a standard local runtime with valid sessions:

- `/trq212/article/2033949937936085378` renders an Article page
- `/trq212/status/2033949937936085378` renders an Article page
- `/jack/status/20` renders a normal tweet conversation
- `/bcherny/status/2033950823248429176` renders a normal conversation and localizes its Article link to `/trq212/status/2033949937936085378#m`
- `/i/article/:id` and `/i/notes/:id` render the unsupported-feature page
