import os
import shutil
import subprocess
from pathlib import Path

from base import BaseTestCase, Conversation


REPO_ROOT = Path(__file__).resolve().parents[1]


# =============================================================================
# MERGE BLOCKER: fixture selection is required before this PR can be merged.
#
# The happy-path tests below intentionally FAIL (not skip) when fixture lists
# are empty, because a silent skip lets CI pass while the core article rendering
# path is broken. If you are reading this because a test failed with "fixtures
# required but none configured" -- that is working as intended.
#
# Supported public Article URL shapes:
#   - /<user>/article/<id>
#   - /<user>/status/<id>
#
# For `articles`: pick at least one live Article fixture for each supported URL
# shape. Collectively exercise at least one media entity, one embedded tweet
# entity, and one header or list block. Record each fixture with a short note
# explaining what it covers so a future maintainer whose fixture has been
# deleted upstream knows what to replace.
#
# For `normal_status`: pick one known normal /<user>/status/<id> tweet that is
# not an Article. This proves Article detection does not hijack ordinary tweet
# conversations.
#
# For `article_link_fixtures`: pick one or more stable tweet/profile/card pages
# whose rendered content links to public Articles. Expected hrefs must be local,
# not x.com or twitter.com. The rendered fixture below covers the status-shaped
# public Article link; the formatter-localizer test separately locks both
# supported public Article URL shapes.
# =============================================================================

articles = [
    [
        'trq212/article/2033949937936085378',
        'Lessons from Building Claude Code',
        'trq212',
        'public article path, title, author, body, media, headers, lists',
    ],
    [
        'trq212/status/2033949937936085378',
        'Lessons from Building Claude Code',
        'trq212',
        'public status path that resolves to an Article',
    ],
]

normal_status = ('jack/status/20', 'just setting up my twttr')

article_link_fixtures = [
    [
        'bcherny/status/2033950823248429176',
        [
            '/trq212/status/2033949937936085378#m',
        ],
    ],
]

public_article_link_examples = [
    (
        'https://twitter.com/trq212/status/2033949937936085378',
        '/trq212/status/2033949937936085378',
    ),
    (
        'https://x.com/trq212/article/2033949937936085378',
        '/trq212/article/2033949937936085378',
    ),
]


def nim_string(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def nimble_package_paths():
    roots = []
    nimble_dir = os.environ.get('NIMBLE_DIR')
    if nimble_dir:
        roots.append(Path(nimble_dir))

    nim = shutil.which('nim')
    if nim:
        prefix = Path(nim).resolve().parents[1]
        roots.append(prefix / 'nimble')

    roots.append(Path.home() / '.nimble')

    paths = []
    seen = set()
    for root in roots:
        for packages in (root / 'pkgs2', root / 'pkgs'):
            if not packages.is_dir() or packages in seen:
                continue

            seen.add(packages)
            paths.append(packages)
            paths.extend(path for path in packages.iterdir() if path.is_dir())

    return paths


def test_public_article_url_localizer_accepts_supported_shapes(tmp_path):
    """The shared formatter helper localizes both public Article URL shapes."""
    cases = ',\n'.join(
        f'  (source: {nim_string(source)}, '
        f'expected: {nim_string(expected)})'
        for source, expected in public_article_link_examples
    )
    script = REPO_ROOT / 'tests' / f'article_link_localizer_{os.getpid()}.nim'
    nim_paths = [f'--path:{REPO_ROOT / "src"}']
    nim_paths.extend(f'--path:{path}' for path in nimble_package_paths())
    try:
        script.write_text(
            'import formatters\n\n'
            'let cases = [\n'
            f'{cases}\n'
            ']\n\n'
            'for item in cases:\n'
            '  let actual = localizeTwitterArticleUrl(item.source)\n'
            '  if actual != item.expected:\n'
            '    quit("expected " & item.expected & " for " & item.source &\n'
            '         ", got " & actual, 1)\n'
            '  echo actual\n'
        )

        proc = subprocess.run(
            [
                'nim', 'r', '--hints:off', '--verbosity:0',
                *nim_paths, str(script),
            ],
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    finally:
        script.unlink(missing_ok=True)

    expected = [expected for _source, expected in public_article_link_examples]
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert proc.stdout.splitlines() == expected


class ArticleTest(BaseTestCase):
    def test_fixtures_are_configured(self):
        """Guardrail: fail loudly when article fixtures are missing.

        A silent skip on missing fixtures lets CI pass while the rendering
        pipeline is broken, which is exactly the failure mode this test
        suite exists to prevent. If you hit this, populate the fixture
        lists at the top of this file — do not @skip or comment this out.
        """
        article_paths = [path for path, *_ in articles]
        expected_article_links = [
            href
            for _path, hrefs in article_link_fixtures
            for href in hrefs
        ]
        expected_localizer_links = [
            expected
            for _source, expected in public_article_link_examples
        ]

        self.assert_true(
            len(articles) >= 2,
            'tests/test_article.py requires at least two live Article '
            'fixtures: one /<user>/article/<id> and one '
            '/<user>/status/<id>. See the MERGE BLOCKER comment.'
        )
        self.assert_true(
            any('/article/' in path for path in article_paths),
            'tests/test_article.py requires a live public '
            '/<user>/article/<id> Article fixture.'
        )
        self.assert_true(
            any('/status/' in path for path in article_paths),
            'tests/test_article.py requires a live public '
            '/<user>/status/<id> Article fixture.'
        )
        self.assert_true(
            normal_status is not None,
            'tests/test_article.py requires one known normal '
            '/<user>/status/<id> non-Article fixture.'
        )
        self.assert_true(
            len(article_link_fixtures) > 0,
            'tests/test_article.py requires at least one '
            'article_link_fixtures entry for public-link localization.'
        )
        self.assert_true(
            any('/article/' in href for href in expected_localizer_links),
            'public_article_link_examples must expect at least one localized '
            '/<user>/article/<id> href.'
        )
        self.assert_true(
            any('/status/' in href for href in expected_article_links),
            'article_link_fixtures must expect at least one rendered localized '
            '/<user>/status/<id> href.'
        )

    def test_article_page_smoke(self):
        """Render each fixture article and sanity-check the key elements."""
        self.assert_true(
            len(articles) >= 2,
            'article fixtures are required — see MERGE BLOCKER comment'
        )
        for path, title_substr, author_handle, _covers in articles:
            self.open_nitter(path)
            self.assertIn('/' + path, self.get_current_url())
            self.assert_false(
                self.is_element_present('link[rel="canonical"]'),
                'Article pages should not emit a canonical link tag'
            )
            self.assert_element('.article-page')
            self.assert_element('.article-title')
            self.assert_text(title_substr, '.article-title')
            self.assert_text(f'@{author_handle}',
                             '.article-author-username')
            # Body must contain at least one rendered child inside <article>
            self.assert_element('.article-panel article *')

    def test_article_has_rich_entity(self):
        """At least one rich entity should render across the fixture set.

        We accept any of: image, embedded tweet, header, or list — the
        fixtures are picked to collectively cover these, so at least one
        selector should match on at least one fixture.
        """
        self.assert_true(
            len(articles) >= 2,
            'article fixtures are required — see MERGE BLOCKER comment'
        )
        rich_selectors = [
            '.article-panel article img',
            '.article-panel article .main-tweet',
            '.article-panel article h1',
            '.article-panel article h2',
            '.article-panel article h3',
            '.article-panel article ul li',
            '.article-panel article ol li',
        ]
        matched = False
        for path, *_ in articles:
            self.open_nitter(path)
            for sel in rich_selectors:
                if self.is_element_present(sel):
                    matched = True
                    break
            if matched:
                break
        self.assert_true(
            matched,
            'No rich entity (image, embedded tweet, header, or list) '
            'rendered on any fixture — check the fixture selection.'
        )

    def test_status_path_non_article_renders_conversation(self):
        """A normal status id should still render the tweet conversation."""
        self.assert_true(
            normal_status is not None,
            'normal_status fixture is required -- '
            'see MERGE BLOCKER comment'
        )
        path, expected_text = normal_status
        self.open_nitter(path)
        self.assert_element(Conversation.main)
        self.assert_false(
            self.is_element_present('.article-page'),
            'normal status rendered as an Article page'
        )
        self.assert_text(expected_text, Conversation.main)

    def test_public_article_links_rewrite_to_local(self):
        """Public X/Twitter Article links should render with local hrefs."""
        self.assert_true(
            len(article_link_fixtures) > 0,
            'article_link_fixtures fixture is required -- '
            'see MERGE BLOCKER comment'
        )

        for path, expected_hrefs in article_link_fixtures:
            self.open_nitter(path)
            anchors = self.find_elements('a')
            rendered_hrefs = [
                anchor.get_attribute('href') or ''
                for anchor in anchors
            ]
            for expected in expected_hrefs:
                matching = [href for href in rendered_hrefs
                            if href.endswith(expected)]
                self.assert_true(
                    len(matching) > 0,
                    f'expected local Article href {expected} was not rendered'
                )
                for href in matching:
                    self.assert_false(
                        'x.com' in href or 'twitter.com' in href,
                        f'Article href stayed external: {href}'
                    )

    def test_private_article_and_notes_routes_are_unsupported(self):
        """/i/article/:id and /i/notes/:id must hit unsupported feature."""
        for path in ('i/article/1234567890', 'i/notes/1234567890'):
            self.open_nitter(path)
            self.assert_text('Unsupported feature', '.overlay-panel h1')
            self.assert_false(
                self.is_element_present('.article-page'),
                f'{path} unexpectedly rendered an Article page'
            )
